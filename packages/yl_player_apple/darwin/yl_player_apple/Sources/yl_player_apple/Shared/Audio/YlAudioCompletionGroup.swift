import Foundation

/// Output notifications are distinct from render progress. Playback completion
/// also retires resources if the output has not sent the earlier notification.
struct YlAudioOutputCallbacks {
  let resourcesReleased: () -> Void
  let playedBack: () -> Void
}

/// Independent one-shot ownership for callbacks from one audio renderer.
final class YlAudioCompletionGroup {
  // System outputs may retain delivered callbacks until the node stops. Sharing
  // synchronization prevents one retained NSLock allocation per audio buffer.
  private let lock = NSLock()

  func makeCompletion(_ body: @escaping () -> Void) -> () -> Void {
    let completion = Completion(lock: lock, body: body)
    return { completion.finish() }
  }

  func makeCallbacks(
    releaseResources: @escaping () -> Void,
    completePlayback: @escaping () -> Void
  ) -> YlAudioOutputCallbacks {
    let completion = LifecycleCompletion(lock: lock, resources: releaseResources, playback: completePlayback)
    return YlAudioOutputCallbacks(
      resourcesReleased: { completion.releaseResources() },
      playedBack: { completion.finishPlayback() }
    )
  }

  private final class LifecycleCompletion {
    private let lock: NSLock
    private var resources: (() -> Void)?
    private var playback: (() -> Void)?

    init(lock: NSLock, resources: @escaping () -> Void, playback: @escaping () -> Void) {
      self.lock = lock
      self.resources = resources
      self.playback = playback
    }

    func releaseResources() {
      lock.lock()
      let callback = resources
      resources = nil
      lock.unlock()
      callback?()
    }

    func finishPlayback() {
      lock.lock()
      let release = resources
      let complete = playback
      resources = nil
      playback = nil
      lock.unlock()
      // Claim both phases once, then invoke/release outside the shared lock.
      // A resource callback claimed concurrently may still be executing; this
      // is not an execution barrier. Each phase keeps its own capture alive.
      release?()
      complete?()
    }
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
