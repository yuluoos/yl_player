import Foundation

public final class YlOpenCancellationToken {
  public init() {}
  private let lock = NSLock()
  private var cancelled = false
  private var handlers: [() -> Void] = []

  public var isCancelled: Bool {
    lock.withLock { cancelled }
  }

  public func onCancel(_ handler: @escaping () -> Void) {
    let invokeNow = lock.withLock { () -> Bool in
      guard !cancelled else { return true }
      handlers.append(handler)
      return false
    }
    if invokeNow { handler() }
  }

  public func cancel() {
    let pending = lock.withLock { () -> [() -> Void] in
      guard !cancelled else { return [] }
      cancelled = true
      defer { handlers.removeAll() }
      return handlers
    }
    pending.forEach { $0() }
  }

  public func throwIfCancelled() throws {
    if isCancelled { throw Self.cancellationError() }
  }

  public static func cancellationError() -> NativePlayerError {
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
