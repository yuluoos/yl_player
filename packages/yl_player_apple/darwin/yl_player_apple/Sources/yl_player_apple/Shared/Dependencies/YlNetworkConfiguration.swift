import Foundation

struct YlNetworkConfiguration: Equatable {
  let connectTimeoutMs: Int64
  let readTimeoutMs: Int64
  let maxRetries: Int
  let baseRetryDelayMs: Int64
  let maxRetryDelayMs: Int64
  let maxRedirects: Int

  init(map: [String: Any?]) {
    connectTimeoutMs = Self.clampedMilliseconds(
      int64(map["connectTimeoutMs"]) ?? 10_000
    )
    readTimeoutMs = Self.clampedMilliseconds(
      int64(map["readTimeoutMs"]) ?? 15_000
    )
    maxRetries = Self.clampedCount(int64(map["maxRetries"]) ?? 3)
    baseRetryDelayMs = Self.clampedMilliseconds(
      int64(map["baseRetryDelayMs"]) ?? 500
    )
    maxRetryDelayMs = Self.clampedMilliseconds(
      int64(map["maxRetryDelayMs"]) ?? 8_000
    )
    maxRedirects = Self.clampedCount(int64(map["maxRedirects"]) ?? 5)
  }

  private static func clampedMilliseconds(_ value: Int64) -> Int64 {
    min(max(value, 0), 60_000)
  }

  private static func clampedCount(_ value: Int64) -> Int {
    Int(min(max(value, 0), 20))
  }
}
