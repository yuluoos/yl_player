import Foundation

protocol YlTimedVideoEndpoint: AnyObject {
  var isRetired: Bool { get }
  func update(_ snapshot: YlPresentationClockSnapshot, generation: UInt64)
  func enqueue(_ frame: YlFrameEnvelope) -> Bool
  func setReadyHandler(_ handler: @escaping () -> Void)
  func retire(removingImage: Bool, completion: @escaping () -> Void)
}
extension YlTimedVideoEndpoint {
  var isRetired: Bool { false }
  func setReadyHandler(_ handler: @escaping () -> Void) {}
}
protocol YlTimedVideoOutput: AnyObject {
  var supportsTimedVideo: Bool { get }
  func makeTimedVideoEndpoint() -> (any YlTimedVideoEndpoint)?
}

extension YlTimedVideoOutput { var supportsTimedVideo: Bool { false } }

/// Revocable data-plane authority. Control-plane owners never wait for a native
/// enqueue while holding a session lock: the last admitted call starts retirement.
final class YlTimedVideoLeaseEndpoint: YlTimedVideoEndpoint {
  private let lock = NSLock()
  private var endpoint: (any YlTimedVideoEndpoint)?
  private var inFlight = 0
  private var closed = false
  private var retirementStarted = false
  private var retirementFinished = false
  private var removeImage = false
  private var completions: [() -> Void] = []
  private let onFirstEnqueue: (() -> Void)?
  private var notified = false

  init(_ endpoint: any YlTimedVideoEndpoint, onFirstEnqueue: (() -> Void)? = nil) {
    self.endpoint = endpoint; self.onFirstEnqueue = onFirstEnqueue
  }

  var isRetired: Bool {
    let current = lock.withLock { closed ? nil : endpoint }
    return current?.isRetired ?? true
  }

  private func acquire() -> (any YlTimedVideoEndpoint)? {
    lock.withLock {
      guard !closed, let endpoint else { return nil }
      inFlight += 1
      return endpoint
    }
  }

  func update(_ snapshot: YlPresentationClockSnapshot, generation: UInt64) {
    guard let endpoint = acquire() else { return }
    endpoint.update(snapshot, generation: generation)
    release()
  }

  func setReadyHandler(_ handler: @escaping () -> Void) {
    guard let endpoint = acquire() else { return }
    endpoint.setReadyHandler { [weak self] in
      guard let self, !self.isRetired else { return }
      handler()
    }
    release()
  }

  func enqueue(_ frame: YlFrameEnvelope) -> Bool {
    guard let endpoint = acquire() else { return false }
    let accepted = endpoint.enqueue(frame)
    let notify = lock.withLock { () -> Bool in
      guard accepted, !closed, !notified else { return false }
      notified = true; return true
    }
    if notify { onFirstEnqueue?() }
    release()
    return accepted
  }

  private func release() {
    lock.withLock { inFlight -= 1 }
    startRetirementIfReady()
  }

  func retire(removingImage: Bool, completion: @escaping () -> Void) {
    let finished = lock.withLock { () -> Bool in
      guard !retirementFinished else { return true }
      closed = true
      removeImage = removeImage || removingImage
      completions.append(completion)
      return false
    }
    if finished { completion() }
    else { startRetirementIfReady() }
  }

  private func startRetirementIfReady() {
    let work = lock.withLock { () -> ((any YlTimedVideoEndpoint), Bool)? in
      guard closed, inFlight == 0, !retirementStarted, let endpoint else { return nil }
      retirementStarted = true
      return (endpoint, removeImage)
    }
    guard let (endpoint, remove) = work else { return }
    endpoint.retire(removingImage: remove) { [self] in
      let callbacks = lock.withLock { () -> [() -> Void] in
        guard !retirementFinished else { return [] }
        retirementFinished = true
        self.endpoint = nil
        let callbacks = completions
        completions.removeAll()
        return callbacks
      }
      callbacks.forEach { $0() }
    }
  }
}
