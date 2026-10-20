import yl_player_media_core
import Foundation

struct YlFrameEnvelope {
  var reservation: YlManagedBufferLedger.Token? = nil
  let payload: AnyObject
  let ptsUs: Int64
  let durationUs: Int64
  let keyframe: Bool
  let generation: UInt64
}

enum YlFrameDropReason: String, CaseIterable {
  case lateArrival, durationLimit, enqueueTimeout, lateAfterCapacity, capacityEviction, catchUp
}

struct YlFrameDropEvent {
  let reason: YlFrameDropReason
  let count: Int
  let total: Int
  let uptime: TimeInterval
  let generation: UInt64
  let firstPTS: Int64
  let lastPTS: Int64
  let queueCount: Int
  let positionUs: Int64?
  let selectedPTS: Int64?
  let previousPositionUs: Int64?
  let previousTickUptime: TimeInterval?
  let enqueueWaitSeconds: TimeInterval
}

struct YlFrameDropDiagnostics {
  let total: Int
  let waitingEnqueues: Int
  let counts: [YlFrameDropReason: Int]
  let events: [YlFrameDropEvent]
}

final class YlFrameScheduler {
  private let lock = NSCondition()
  private let compatibility: YlAppleCompatibility
  private let maxFrames: Int
  private var frameLimit: Int
  private let enqueueWaitTimeout: TimeInterval
  private var frames = [YlFrameEnvelope]()
  private var activeGeneration: UInt64?
  private var lastPresentedPTS: Int64?
  private var lastSubmittedPTS: Int64?
  private var disposed = false
  private var droppedFrames = 0
  private let collectDropDiagnostics: Bool
  private var waitingEnqueues = 0
  private var dropCounts: [YlFrameDropReason: Int] = [:]
  private var dropEvents: [YlFrameDropEvent] = []
  private var previousTick: (uptime: TimeInterval, positionUs: Int64)?
  private var boundedPlan: YlBoundedBufferPlan?

  init(
    compatibility: YlAppleCompatibility = .current,
    maxFrames: Int = 3,
    enqueueWaitTimeout: TimeInterval = 0.25,
    collectDropDiagnostics: Bool = false
  ) {
    precondition(maxFrames > 0)
    precondition(enqueueWaitTimeout >= 0)
    self.compatibility = compatibility
    self.maxFrames = maxFrames
    self.frameLimit = maxFrames
    self.enqueueWaitTimeout = enqueueWaitTimeout
    self.collectDropDiagnostics = collectDropDiagnostics
  }

  func setRate(_ rate: Double) {
    guard rate.isFinite else { return }
    lock.lock()
    // Keep the same wall-clock decode lead at high playback rates.
    // Shrinking leaves queued frames intact until presentation releases them.
    frameLimit = Int((Double(maxFrames) * min(4, max(1, rate))).rounded(.up))
    lock.broadcast()
    lock.unlock()
  }

  func configureBounded(_ plan: YlBoundedBufferPlan?) { lock.withLock { boundedPlan = plan } }
  var bufferedDurationUs: Int64 { lock.withLock { durationLocked } }
  private var durationLocked: Int64 {
    guard let first = frames.first, let last = frames.last else { return 0 }
    let end = last.ptsUs.addingReportingOverflow(max(0, last.durationUs))
    let span = end.partialValue.subtractingReportingOverflow(first.ptsUs)
    return end.overflow || span.overflow ? Int64.max : max(0, span.partialValue)
  }
  var pendingPTS: [Int64] {
    lock.withLock { frames.map(\.ptsUs) }
  }

  var lateFrameDropCount: Int {
    lock.withLock { droppedFrames }
  }

  var dropDiagnostics: YlFrameDropDiagnostics {
    lock.withLock { .init(total: droppedFrames, waitingEnqueues: waitingEnqueues, counts: dropCounts, events: dropEvents) }
  }

  // Condition lock held. Scalar-only, opt-in diagnostics cannot retain payloads
  // or reservations; lifetime totals survive flush/disposal like droppedFrames.
  private func recordDrop(_ reason: YlFrameDropReason, first: YlFrameEnvelope,
                          lastPTS: Int64? = nil, count: Int = 1,
                          positionUs: Int64? = nil, selectedPTS: Int64? = nil,
                          waitStarted: TimeInterval? = nil) {
    droppedFrames += count
    guard collectDropDiagnostics else { return }
    let now = ProcessInfo.processInfo.systemUptime
    dropCounts[reason, default: 0] += count
    if dropEvents.count == 16 { dropEvents.removeFirst() }
    dropEvents.append(.init(reason: reason, count: count, total: droppedFrames,
      uptime: now, generation: first.generation, firstPTS: first.ptsUs,
      lastPTS: lastPTS ?? first.ptsUs, queueCount: frames.count,
      positionUs: positionUs, selectedPTS: selectedPTS,
      previousPositionUs: previousTick?.positionUs, previousTickUptime: previousTick?.uptime,
      enqueueWaitSeconds: waitStarted.map { max(0, now - $0) } ?? 0))
  }

  private func recordTick(positionUs: Int64) {
    if collectDropDiagnostics {
      previousTick = (ProcessInfo.processInfo.systemUptime, positionUs)
    }
  }

  @discardableResult
  func enqueue(_ frame: YlFrameEnvelope) -> Bool {
    lock.lock()
    guard !disposed,
          activeGeneration == nil || activeGeneration == frame.generation else {
      lock.unlock()
      return false
    }
    if compatibility.usesBackpressure,
       (lastPresentedPTS.map({ frame.ptsUs <= $0 }) ?? false)
        || (lastSubmittedPTS.map({ frame.ptsUs <= $0 }) ?? false) {
      recordDrop(.lateArrival, first: frame)
      lock.unlock()
      return false
    }

    if let boundedPlan {
      let start = min(frames.first?.ptsUs ?? frame.ptsUs, frame.ptsUs)
      let end = frame.ptsUs.addingReportingOverflow(max(0, frame.durationUs))
      let span = end.partialValue.subtractingReportingOverflow(start)
      guard !end.overflow, !span.overflow, span.partialValue <= boundedPlan.maxDurationUs else {
        recordDrop(.durationLimit, first: frame); lock.unlock(); return false
      }
    }
    let waitStarted = collectDropDiagnostics ? ProcessInfo.processInfo.systemUptime : nil
    let deadline = Date(timeIntervalSinceNow: enqueueWaitTimeout)
    while boundedPlan == nil && compatibility.usesBackpressure && frames.count >= frameLimit {
      if collectDropDiagnostics { waitingEnqueues += 1 }
      let signalled = lock.wait(until: deadline)
      if collectDropDiagnostics { waitingEnqueues -= 1 }
      guard !disposed,
            activeGeneration == nil || activeGeneration == frame.generation else {
        lock.unlock()
        return false
      }
      guard signalled else {
        recordDrop(.enqueueTimeout, first: frame, waitStarted: waitStarted)
        lock.unlock()
        return false
      }
    }

    // Presentation can advance while the producer waits for capacity.
    if (lastPresentedPTS.map({ frame.ptsUs <= $0 }) ?? false)
        || (lastSubmittedPTS.map({ frame.ptsUs <= $0 }) ?? false) {
      recordDrop(.lateAfterCapacity, first: frame, waitStarted: waitStarted)
      lock.unlock()
      return false
    }
    let insertionIndex = frames.firstIndex { existing in
      existing.ptsUs > frame.ptsUs
    } ?? frames.endIndex
    frames.insert(frame, at: insertionIndex)
    var releasedFrame: YlFrameEnvelope?
    if boundedPlan == nil && !compatibility.usesBackpressure && frames.count > maxFrames {
      recordDrop(.capacityEviction, first: frames[0])
      releasedFrame = frames.removeFirst()
    }
    lock.unlock()
    withExtendedLifetime(releasedFrame) {}
    return true
  }

  func nextFrame(upTo positionUs: Int64, generation: UInt64) -> YlFrameEnvelope? {
    lock.lock()
    guard !disposed, activeGeneration == nil || activeGeneration == generation else {
      lock.unlock(); return nil
    }
    let stale = frames.filter { $0.generation != generation }
    frames.removeAll { $0.generation != generation }
    guard let first = frames.first, first.ptsUs <= positionUs else {
      if !stale.isEmpty { lock.broadcast() }
      lock.unlock()
      withExtendedLifetime(stale) {}
      return nil
    }
    let selected = frames.removeFirst()
    lastSubmittedPTS = selected.ptsUs
    lock.broadcast()
    lock.unlock()
    withExtendedLifetime(stale) {}
    return selected
  }

  func frame(at positionUs: Int64, generation: UInt64) -> YlFrameEnvelope? {
    lock.lock()
    guard !disposed,
          activeGeneration == nil || activeGeneration == generation else {
      lock.unlock()
      return nil
    }

    let staleFrames = frames.filter { $0.generation != generation }
    if !staleFrames.isEmpty {
      frames.removeAll { $0.generation != generation }
    }
    guard frames.first?.ptsUs ?? .max <= positionUs else {
      if !staleFrames.isEmpty { lock.broadcast() }
      recordTick(positionUs: positionUs)
      lock.unlock()
      withExtendedLifetime(staleFrames) {}
      return nil
    }

    let dueCount = frames.prefix { $0.ptsUs <= positionUs }.count
    let catchUpDropCount = max(0, dueCount - 1)
    let droppedDueFrames = Array(frames.prefix(catchUpDropCount))
    if catchUpDropCount > 0 {
      recordDrop(.catchUp, first: frames[0], lastPTS: frames[catchUpDropCount - 1].ptsUs,
        count: catchUpDropCount, positionUs: positionUs, selectedPTS: frames[catchUpDropCount].ptsUs)
      frames.removeFirst(catchUpDropCount)
    }
    let selectedFrame = frames.removeFirst()
    lastPresentedPTS = selectedFrame.ptsUs
    recordTick(positionUs: positionUs)
    lock.broadcast()
    lock.unlock()
    withExtendedLifetime(staleFrames) {}
    withExtendedLifetime(droppedDueFrames) {}
    return selectedFrame
  }

  func flush(generation: UInt64) {
    lock.lock()
    activeGeneration = generation
    lastPresentedPTS = nil
    lastSubmittedPTS = nil
    previousTick = nil
    let releasedFrames = frames
    frames.removeAll(keepingCapacity: true)
    lock.broadcast()
    lock.unlock()
    withExtendedLifetime(releasedFrames) {}
  }

  func dispose() {
    lock.lock()
    guard !disposed else {
      lock.unlock()
      return
    }
    disposed = true
    lastPresentedPTS = nil
    lastSubmittedPTS = nil
    previousTick = nil
    let releasedFrames = frames
    frames.removeAll(keepingCapacity: false)
    lock.broadcast()
    lock.unlock()
    withExtendedLifetime(releasedFrames) {}
  }

  deinit {
    dispose()
  }
}

private extension NSCondition {
  func withLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
