import Foundation

final class YlOpenCancellationToken {
  private let lock = NSLock()
  private var cancelled = false
  private var handlers: [() -> Void] = []

  var isCancelled: Bool {
    lock.withLock { cancelled }
  }

  func onCancel(_ handler: @escaping () -> Void) {
    let invokeNow = lock.withLock { () -> Bool in
      guard !cancelled else { return true }
      handlers.append(handler)
      return false
    }
    if invokeNow { handler() }
  }

  func cancel() {
    let pending = lock.withLock { () -> [() -> Void] in
      guard !cancelled else { return [] }
      cancelled = true
      defer { handlers.removeAll() }
      return handlers
    }
    pending.forEach { $0() }
  }

  func throwIfCancelled() throws {
    if isCancelled { throw Self.cancellationError() }
  }

  static func cancellationError() -> NativePlayerError {
    NativePlayerError(
      category: "cancelled",
      code: "network.cancelled",
      message: "The media open was cancelled."
    )
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
