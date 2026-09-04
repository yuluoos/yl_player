import Foundation

/// Owns the retry budget for a live input connection.
///
/// The backend remains responsible for scheduling work and replacing pipelines;
/// this type only makes the retry/cancellation decision thread-safe.
final class YlLiveReconnectController {
  private let lock = NSLock()
  private let maxRetries: Int
  private let baseRetryDelayMs: Int64
  private let maxRetryDelayMs: Int64
  private var retryAttempt = 0
  private var isCancelled = false

  init(configuration: YlNetworkConfiguration) {
    maxRetries = configuration.maxRetries
    baseRetryDelayMs = configuration.baseRetryDelayMs
    maxRetryDelayMs = configuration.maxRetryDelayMs
  }

  var attempt: Int {
    lock.withLock { retryAttempt }
  }

  func nextDelayMs() -> Int64? {
    lock.withLock {
      guard !isCancelled, retryAttempt < maxRetries else { return nil }

      let exponent = retryAttempt
      retryAttempt += 1
      var delay = baseRetryDelayMs
      for _ in 0..<exponent {
        if delay >= maxRetryDelayMs || delay > Int64.max / 2 {
          return maxRetryDelayMs
        }
        delay *= 2
      }
      return min(delay, maxRetryDelayMs)
    }
  }

  func markFirstFrame() {
    lock.withLock {
      guard !isCancelled else { return }
      retryAttempt = 0
    }
  }

  func cancel() {
    lock.withLock { isCancelled = true }
  }

  func shouldInstall(
    reconnectGeneration: UInt64,
    currentGeneration: UInt64
  ) -> Bool {
    lock.withLock {
      !isCancelled && reconnectGeneration == currentGeneration
    }
  }
}
