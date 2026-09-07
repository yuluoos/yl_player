import Foundation

struct YlFrameEnvelope {
  let payload: AnyObject
  let ptsUs: Int64
  let durationUs: Int64
  let keyframe: Bool
  let generation: UInt64
}

final class YlFrameScheduler {
  private let lock = NSCondition()
  private let maxFrames: Int
  private let enqueueWaitTimeout: TimeInterval
  private var frames = [YlFrameEnvelope]()
  private var activeGeneration: UInt64?
  private var lastPresentedPTS: Int64?
  private var disposed = false
  private var droppedFrames = 0

  init(
    maxFrames: Int = 3,
    enqueueWaitTimeout: TimeInterval = 0.25
  ) {
    precondition(maxFrames > 0)
    precondition(enqueueWaitTimeout >= 0)
    self.maxFrames = maxFrames
    self.enqueueWaitTimeout = enqueueWaitTimeout
  }

  var pendingPTS: [Int64] {
    lock.withLock { frames.map(\.ptsUs) }
  }

  var lateFrameDropCount: Int {
    lock.withLock { droppedFrames }
  }

  @discardableResult
  func enqueue(_ frame: YlFrameEnvelope) -> Bool {
    lock.lock()
    guard !disposed,
          activeGeneration == nil || activeGeneration == frame.generation else {
      lock.unlock()
      return false
    }
    if let lastPresentedPTS, frame.ptsUs <= lastPresentedPTS {
      droppedFrames += 1
      lock.unlock()
      return false
    }

    let deadline = Date(timeIntervalSinceNow: enqueueWaitTimeout)
    while frames.count >= maxFrames {
      let signalled = lock.wait(until: deadline)
      guard !disposed,
            activeGeneration == nil || activeGeneration == frame.generation else {
        lock.unlock()
        return false
      }
      guard signalled else {
        droppedFrames += 1
        lock.unlock()
        return false
      }
    }

    let insertionIndex = frames.firstIndex { existing in
      existing.ptsUs > frame.ptsUs
    } ?? frames.endIndex
    frames.insert(frame, at: insertionIndex)
    lock.unlock()
    return true
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
      lock.unlock()
      withExtendedLifetime(staleFrames) {}
      return nil
    }

    let dueCount = frames.prefix { $0.ptsUs <= positionUs }.count
    let catchUpDropCount = max(0, dueCount - 1)
    let droppedDueFrames = Array(frames.prefix(catchUpDropCount))
    if catchUpDropCount > 0 {
      frames.removeFirst(catchUpDropCount)
      droppedFrames += catchUpDropCount
    }
    let selectedFrame = frames.removeFirst()
    lastPresentedPTS = selectedFrame.ptsUs
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
