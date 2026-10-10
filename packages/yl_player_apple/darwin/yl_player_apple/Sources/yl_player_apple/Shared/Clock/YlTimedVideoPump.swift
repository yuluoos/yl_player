import Foundation

struct YlTimedVideoStatistics {
  var submitted = 0
  var rejected = 0
  var maxWorkerGapSeconds: TimeInterval = 0
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
  private let onSubmitted: (() -> Void)?

  init(scheduler: any YlPresentationScheduling, endpoint: any YlTimedVideoEndpoint,
       clockSnapshot: @escaping () -> YlPresentationClockSnapshot, generation: UInt64,
       onSubmitted: (() -> Void)? = nil,
       queue: DispatchQueue = DispatchQueue(label: "dev.ylplayer.timed-video", qos: .userInitiated)) {
    self.scheduler = scheduler; self.endpoint = endpoint
    self.clockSnapshot = clockSnapshot; self.generation = generation; self.queue = queue
    self.onSubmitted = onSubmitted
    window.reset(generation: generation)
    timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in self?.tick() }
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
    let snapshot = clockSnapshot()
    let now = ProcessInfo.processInfo.systemUptime
    if snapshot.playing {
      if let lastTick { stateLock.withLock { observed.maxWorkerGapSeconds = max(observed.maxWorkerGapSeconds, now - lastTick) } }
      lastTick = now
      if !timerRunning {
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timerRunning = true
      }
    } else {
      lastTick = nil // An intentional pause is not worker starvation.
      if timerRunning { timer.schedule(deadline: .distantFuture); timerRunning = false }
    }
    endpoint.update(snapshot, generation: generation)
    window.advance(to: snapshot.positionUs)
    if let horizon = snapshot.submissionHorizonUs {
      // Bound work as well as retained samples. A malformed input cannot spin.
      for _ in 0..<3 {
        guard !isStopped, window.pendingFrames.count < 3 else { break }
        if held == nil {
          // Publish ownership before the scheduler releases it: EOF must never
          // observe both queues empty while a native enqueue is in flight.
          stateLock.withLock { observed.pending = true }
          held = scheduler.nextFrame(upTo: horizon, generation: generation)
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
        guard endpoint.enqueue(frame) else { break }
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
