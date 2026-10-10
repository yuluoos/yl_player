import Foundation

struct YlIsolatedAudioClockStatistics {
  var samples = 0
  var staleEvents = 0
  var rejectedObservations = 0
  var maximumReadSeconds: Double = 0
  var maximumAgeSeconds: Double = 0
}

/// The only native reader for the candidate presentation clock. A blocked read
/// owns no state lock; controls and video never join this queue.
final class YlIsolatedAudioClock {
  private let read: (UInt64) -> YlAudioClockObservation
  private let hostTimeUs: () -> Int64
  private let queue: DispatchQueue
  private let timer: DispatchSourceTimer
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var version: UInt64 = 0
  private var stopped = false
  private var permitted = false
  private var playing = false
  private var wakePending = false
  private var rate: Double = 1
  private var frozenPosition: Int64 = 0
  private var waitingSince: Int64 = 0
  private var slot: (sample: YlAudioClockSample, received: Int64)?
  private var ended: (position: Int64, host: Int64)?
  private var stale = false
  private var observed = YlIsolatedAudioClockStatistics()

  init(read: @escaping (UInt64) -> YlAudioClockObservation, hostTimeUs: @escaping () -> Int64,
       queue: DispatchQueue = DispatchQueue(label: "dev.ylplayer.audio-clock", qos: .userInitiated)) {
    self.read = read; self.hostTimeUs = hostTimeUs; self.queue = queue
    timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in self?.sample() }
    timer.resume()
  }

  func configure(generation: UInt64, positionUs: Int64, rate: Double, playing: Bool) {
    let now = hostTimeUs()
    let wake = lock.withLock { () -> Bool in
      guard !stopped else { return false }
      version &+= 1; self.generation = generation
      self.rate = rate; self.playing = playing; permitted = true
      frozenPosition = max(0, positionUs); waitingSince = now
      slot = nil; ended = nil; stale = false
      guard playing, !wakePending else { return false }
      wakePending = true; return true
    }
    if wake { queue.async { [weak self] in
      guard let self else { return }
      self.lock.withLock { self.wakePending = false }; self.sample()
    } }
  }

  func invalidate() {
    lock.withLock { version &+= 1; permitted = false; slot = nil; ended = nil }
  }

  private func sample() {
    let permit = lock.withLock { () -> (UInt64, UInt64)? in
      guard !stopped, permitted, playing else { return nil }
      return (generation, version)
    }
    guard let permit else { return }
    let started = ProcessInfo.processInfo.systemUptime
    let value = read(permit.0)
    let duration = ProcessInfo.processInfo.systemUptime - started
    let now = hostTimeUs()
    lock.withLock {
      observed.maximumReadSeconds = max(observed.maximumReadSeconds, duration)
      guard !stopped, permitted, generation == permit.0, version == permit.1 else {
        observed.rejectedObservations += 1; return
      }
      switch value {
      case let .running(sample), let .silence(sample):
        guard sample.generation == generation, sample.rate == rate,
              sample.position(atHostTimeUs: now) != nil else {
          observed.rejectedObservations += 1; return
        }
        slot = (sample, now); ended = nil; observed.samples += 1
      case let .ended(position, host):
        guard position >= 0, host >= 0 else { observed.rejectedObservations += 1; return }
        // Repeated EOF observations must not re-anchor and freeze the video tail.
        if ended == nil { ended = (position, host) }
        slot = nil; observed.samples += 1
      case .invalid:
        observed.rejectedObservations += 1
      case .paused, .waiting:
        break // Not EOF. A prior valid observation still has its original expiry.
      }
    }
  }

  func snapshot(atHostTimeUs now: Int64) -> YlPresentationClockSnapshot {
    lock.withLock {
      var valid = false
      if !stopped, permitted, playing, rate.isFinite, rate >= 0.25, rate <= 4 {
        if let ended {
          let position = Double(ended.position) + max(0, Double(now) - Double(ended.host)) * rate
          if position.isFinite, position >= 0, position < Double(Int64.max) {
            frozenPosition = Int64(position); valid = true
          }
        } else if let slot {
          let age = max(abs(Double(now) - Double(slot.sample.hostTimeUs)), max(0, Double(now) - Double(slot.received)))
          observed.maximumAgeSeconds = max(observed.maximumAgeSeconds, age / 1_000_000)
          if age <= 100_000, let position = slot.sample.position(atHostTimeUs: now) {
            frozenPosition = position; valid = true
          }
        }
        let expired = slot != nil || Double(now) - Double(waitingSince) > 100_000
        if !valid, expired, !stale { observed.staleEvents += 1; stale = true }
        if valid { stale = false }
      }
      return .init(positionUs: frozenPosition, hostTimeUs: now, rate: rate,
        playing: valid, waitingForClock: playing && !stopped && !valid)
    }
  }

  var statistics: YlIsolatedAudioClockStatistics { lock.withLock { observed } }
  func stop() {
    lock.withLock { stopped = true; version &+= 1; permitted = false; slot = nil; ended = nil }
    timer.cancel()
  }
  deinit { timer.cancel() }
}
