import Foundation

struct YlFrameEnvelope {
  let payload: AnyObject
  let ptsUs: Int64
  let durationUs: Int64
  let keyframe: Bool
  let generation: UInt64
}

final class YlFrameScheduler {
  private let lock = NSLock()
  private var frames = [YlFrameEnvelope]()
  private var activeGeneration: UInt64?
  private var disposed = false
  private var droppedFrames = 0

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

    let insertionIndex = frames.firstIndex { existing in
      existing.ptsUs > frame.ptsUs
    } ?? frames.endIndex
    frames.insert(frame, at: insertionIndex)

    var releasedFrame: YlFrameEnvelope?
    if frames.count > 3 {
      releasedFrame = frames.removeFirst()
      droppedFrames += 1
    }
    lock.unlock()
    withExtendedLifetime(releasedFrame) {}
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
    let dueCount = frames.prefix { $0.ptsUs <= positionUs }.count
    guard dueCount > 0 else {
      lock.unlock()
      withExtendedLifetime(staleFrames) {}
      return nil
    }

    let dueFrames = Array(frames.prefix(dueCount))
    frames.removeFirst(dueCount)
    let selectedFrame = dueFrames.last
    let droppedDueFrames = Array(dueFrames.dropLast())
    droppedFrames += droppedDueFrames.count
    lock.unlock()
    withExtendedLifetime(staleFrames) {}
    withExtendedLifetime(droppedDueFrames) {}
    return selectedFrame
  }

  func flush(generation: UInt64) {
    lock.lock()
    activeGeneration = generation
    let releasedFrames = frames
    frames.removeAll(keepingCapacity: true)
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
    let releasedFrames = frames
    frames.removeAll(keepingCapacity: false)
    lock.unlock()
    withExtendedLifetime(releasedFrames) {}
  }

  deinit {
    dispose()
  }
}

private extension NSLock {
  func withLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
