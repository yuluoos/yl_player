import Foundation

struct YlFallbackBufferBudget: Equatable {
  let networkBytes: Int
  let scheduledAudioBytes: Int
  let inFlightPacketBytes: Int

  func validateInFlightPacket(size: Int) throws {
    guard size >= 0, size <= inFlightPacketBytes else {
      throw NativePlayerError(
        category: "resource",
        code: "resource.network_buffer_limit",
        message: "A compressed media packet exceeded its memory budget."
      )
    }
  }

  static func make(configuration: PlayerConfiguration) throws -> Self {
    let mebibyte = 1024 * 1024
    switch configuration.bufferMode {
    case "lowLatency":
      return Self(
        networkBytes: 4 * mebibyte,
        scheduledAudioBytes: mebibyte,
        inFlightPacketBytes: 2 * mebibyte
      )
    case "stable":
      return Self(
        networkBytes: 16 * mebibyte,
        scheduledAudioBytes: 4 * mebibyte,
        inFlightPacketBytes: 8 * mebibyte
      )
    case "custom":
      guard let total = configuration.maxBufferBytes else {
        return balanced(mebibyte: mebibyte)
      }
      let floor = 3 * mebibyte
      guard total >= floor else {
        throw NativePlayerError(
          category: "resource",
          code: "resource.network_buffer_limit",
          message: "Network MKV custom buffering requires at least 3 MiB."
        )
      }
      let remainder = total - floor
      let networkShare = percentage(remainder, percent: 70)
      let audioShare = percentage(remainder, percent: 20)
      let networkBytes = mebibyte + networkShare
      let scheduledAudioBytes = mebibyte + audioShare
      return Self(
        networkBytes: networkBytes,
        scheduledAudioBytes: scheduledAudioBytes,
        inFlightPacketBytes: total - networkBytes - scheduledAudioBytes
      )
    default:
      return balanced(mebibyte: mebibyte)
    }
  }

  private static func balanced(mebibyte: Int) -> Self {
    Self(
      networkBytes: 8 * mebibyte,
      scheduledAudioBytes: 2 * mebibyte,
      inFlightPacketBytes: 4 * mebibyte
    )
  }

  private static func percentage(_ value: Int, percent: Int) -> Int {
    (value / 100) * percent + (value % 100) * percent / 100
  }
}
