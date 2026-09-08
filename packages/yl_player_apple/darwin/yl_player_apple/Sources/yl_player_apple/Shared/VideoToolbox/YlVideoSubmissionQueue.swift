import Foundation

/// Holds submitted work in removable storage, so cancellation releases samples
/// immediately instead of retaining them in already-enqueued dispatch blocks.
final class YlVideoSubmissionQueue {
  private let lock = NSLock()
  private let worker = DispatchQueue(label: "dev.ylplayer.\(YlApplePlatform.current.rawValue).fallback.video-decode")
  private var tasks: [() -> Void] = []
  private var running = false

  var isDrained: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !running && tasks.isEmpty
  }

  func submit(_ task: @escaping () -> Void) {
    lock.lock()
    tasks.append(task)
    let shouldStart = !running
    running = true
    lock.unlock()
    if shouldStart { worker.async { [self] in drain() } }
  }

  func cancelPending() {
    lock.lock()
    let released = tasks
    tasks.removeAll(keepingCapacity: false)
    lock.unlock()
    withExtendedLifetime(released) {}
  }

  /// Call after stopping the producer and making running work cancellable.
  func waitUntilIdle() {
    worker.sync {}
  }

  private func drain() {
    while true {
      lock.lock()
      guard !tasks.isEmpty else {
        running = false
        lock.unlock()
        return
      }
      let task = tasks.removeFirst()
      lock.unlock()
      task()
    }
  }
}
