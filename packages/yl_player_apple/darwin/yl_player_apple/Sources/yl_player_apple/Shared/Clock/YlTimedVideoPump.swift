import Foundation

struct YlTimedVideoStatistics {
  var submitted = 0
  var rejected = 0
  var maxWorkerGapSeconds: TimeInterval = 0
  var diagnostics: [String: Any]?
  var pending = false
}

/// A single bounded worker; UI cadence and UI notifications are not on this path.
final class YlTimedVideoPump {
  private let scheduler: any YlPresentationScheduling
  private let endpoint: any YlTimedVideoEndpoint
  private let clockSnapshot: () -> YlPresentationClockSnapshot
  private let generation: UInt64
  private let queue: DispatchQueue
  private let timer: DispatchSourceTimer
  private let pollInterval: DispatchTimeInterval
  private let stateLock = NSLock()
  private var stopped = false
  private var wakePending = false
  private var observed = YlTimedVideoStatistics()
  // Only queue accesses these payload-owning members.
  private let window = YlTimedVideoWindow()
  private var held: YlFrameEnvelope?
  private var lastEndUs: Int64?
  private var lastTick: TimeInterval?
  private var timerRunning = true
  private let collectDiagnostics: Bool
  private var lastFinished: TimeInterval?
  private var phaseMaxima: [String: Double] = [:]
  private var slowTicks: [[String: Double]] = []
  private let onSubmitted: (() -> Void)?

  init(scheduler: any YlPresentationScheduling, endpoint: any YlTimedVideoEndpoint,
       clockSnapshot: @escaping () -> YlPresentationClockSnapshot, generation: UInt64,
       onSubmitted: (() -> Void)? = nil, collectDiagnostics: Bool = false,
       pollInterval: DispatchTimeInterval = .milliseconds(10),
       queue: DispatchQueue = DispatchQueue(label: "dev.ylplayer.timed-video", qos: .userInitiated)) {
    self.scheduler = scheduler; self.endpoint = endpoint
    self.clockSnapshot = clockSnapshot; self.generation = generation; self.queue = queue
    self.onSubmitted = onSubmitted
    self.collectDiagnostics = collectDiagnostics
    self.pollInterval = pollInterval
    window.reset(generation: generation)
    timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in self?.tick() }
    // Native callbacks only schedule a coalesced tick. Never call tick inline:
    // it synchronously enters the endpoint's own serial queue.
    endpoint.setReadyHandler { [weak self] in self?.synchronize() }
    timer.resume()
  }

  var statistics: YlTimedVideoStatistics { stateLock.withLock { observed } }
  var hasPendingPresentation: Bool { statistics.pending }
  var isStopped: Bool { stateLock.withLock { stopped } }

  func synchronize() {
    let enqueue = stateLock.withLock { () -> Bool in
      guard !stopped, !wakePending else { return false }
      wakePending = true; return true
    }
    guard enqueue else { return }
    queue.async { [weak self] in
      guard let self else { return }
      self.stateLock.withLock { self.wakePending = false }
      self.tick()
    }
  }

  private func tick() {
    guard !isStopped else { return }
    if endpoint.isRetired { stop {}; return }
    let started = collectDiagnostics ? ProcessInfo.processInfo.systemUptime : 0
    let snapshot = clockSnapshot()
    let now = ProcessInfo.processInfo.systemUptime
    var phases: [String: Double] = [:]
    if collectDiagnostics {
      phases["clockSeconds"] = now - started
      phases["idleSeconds"] = lastFinished.map { max(0, started - $0) } ?? 0
    }
    defer {
      if collectDiagnostics {
        let finished = ProcessInfo.processInfo.systemUptime
        phases["tickSeconds"] = finished - started
        if !snapshot.playing { phases["idleSeconds"] = 0 }
        for (key, value) in phases { phaseMaxima[key] = max(phaseMaxima[key] ?? 0, value) }
        if phases.values.contains(where: { $0 >= 0.04 }) {
          phases["uptime"] = started
          slowTicks.append(phases)
          if slowTicks.count > 32 { slowTicks.removeFirst() }
        }
        lastFinished = snapshot.playing ? finished : nil
        stateLock.withLock {
          var values = phaseMaxima.mapValues { $0 as Any }
          values["slowTicks"] = slowTicks
          observed.diagnostics = values
        }
      }
    }
    if snapshot.playing || snapshot.waitingForClock {
      if let lastTick { stateLock.withLock { observed.maxWorkerGapSeconds = max(observed.maxWorkerGapSeconds, now - lastTick) } }
      lastTick = now
      if !timerRunning {
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(1))
        timerRunning = true
      }
    } else {
      lastTick = nil // An intentional pause is not worker starvation.
      if timerRunning { timer.schedule(deadline: .distantFuture); timerRunning = false }
    }
    let updateStarted = collectDiagnostics ? ProcessInfo.processInfo.systemUptime : 0
    endpoint.update(snapshot, generation: generation)
    if collectDiagnostics { phases["updateSeconds"] = ProcessInfo.processInfo.systemUptime - updateStarted }
    window.advance(to: snapshot.positionUs)
    if let horizon = snapshot.submissionHorizonUs {
      // Bound work as well as retained samples. A malformed input cannot spin.
      for _ in 0..<3 {
        guard !isStopped, window.pendingFrames.count < 3 else { break }
        if held == nil {
          // Publish ownership before the scheduler releases it: EOF must never
          // observe both queues empty while a native enqueue is in flight.
          stateLock.withLock { observed.pending = true }
          let popStarted = collectDiagnostics ? ProcessInfo.processInfo.systemUptime : 0
          held = scheduler.nextFrame(upTo: horizon, generation: generation)
          if collectDiagnostics { phases["schedulerSeconds"] = max(phases["schedulerSeconds"] ?? 0, ProcessInfo.processInfo.systemUptime - popStarted) }
        }
        guard let frame = held else { break }
        // A rate reduction or clock rollback can move an already-held frame
        // outside the current lead. Keep the one bounded frame until due.
        if frame.generation == generation, frame.ptsUs > horizon { break }
        guard frame.generation == generation, window.canSubmit(ptsUs: frame.ptsUs, snapshot: snapshot) else {
          held = nil
          stateLock.withLock { observed.rejected += 1 }
          continue
        }
        let enqueueStarted = collectDiagnostics ? ProcessInfo.processInfo.systemUptime : 0
        let accepted = endpoint.enqueue(frame)
        if collectDiagnostics { phases["enqueueSeconds"] = max(phases["enqueueSeconds"] ?? 0, ProcessInfo.processInfo.systemUptime - enqueueStarted) }
        guard accepted else { break }
        frame.reservation?.endQueuedTiming()
        window.didSubmit(frame)
        let end = frame.ptsUs.addingReportingOverflow(max(1, frame.durationUs))
        lastEndUs = end.overflow ? .max : end.partialValue
        held = nil
        stateLock.withLock { observed.submitted += 1 }
        onSubmitted?()
      }
    }
    let pending = held != nil || !window.pendingFrames.isEmpty || lastEndUs.map { $0 > snapshot.positionUs } == true
    stateLock.withLock { observed.pending = pending }
  }

  func stop(completion: @escaping () -> Void) {
    stateLock.withLock { stopped = true }
    timer.cancel()
    // Revocation is immediate; native cleanup may finish after an admitted call.
    endpoint.retire(removingImage: true) { [self] in
      queue.async { [self] in
        held = nil; window.reset(generation: generation); lastEndUs = nil
        stateLock.withLock { observed.pending = false }
        completion()
      }
    }
  }

  deinit { timer.cancel() }
}
