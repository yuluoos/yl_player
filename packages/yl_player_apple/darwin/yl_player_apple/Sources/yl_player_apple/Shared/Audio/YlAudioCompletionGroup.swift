import Foundation

/// Independent one-shot ownership for callbacks from one audio renderer.
final class YlAudioCompletionGroup {
  // System outputs may retain delivered callbacks until the node stops. Sharing
  // synchronization prevents one retained NSLock allocation per audio buffer.
  private let lock = NSLock()

  func makeCompletion(_ body: @escaping () -> Void) -> () -> Void {
    let completion = Completion(lock: lock, body: body)
    return { completion.finish() }
  }

  private final class Completion {
    private let lock: NSLock
    private var body: (() -> Void)?

    init(lock: NSLock, body: @escaping () -> Void) {
      self.lock = lock
      self.body = body
    }

    func finish() {
      lock.lock()
      let callback = body
      body = nil
      lock.unlock()
      // Release payload ownership and allow reentrant scheduling outside the
      // shared lock. Dropping an undelivered callback also drops its own body;
      // there is deliberately no central table retaining pending callbacks.
      callback?()
    }
  }
}
