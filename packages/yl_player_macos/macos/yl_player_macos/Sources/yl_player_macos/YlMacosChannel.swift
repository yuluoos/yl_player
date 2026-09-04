import CoreMedia
import FlutterMacOS
import Foundation
import VideoToolbox

enum YlMacosChannelGeneration {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var value: UInt64 = 0

  static func next() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    value &+= 1
    return value
  }
}

enum YlMacosChannel {
  static let deviceCapabilities = capabilities(
    hardwareH264: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
    hardwareHevc: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
  )

  static func capabilities(
    hardwareH264: Bool,
    hardwareHevc: Bool
  ) -> [String: Any] {
    var hardwareVideoCodecs: [String] = []
    if hardwareH264 { hardwareVideoCodecs.append("video/avc") }
    if hardwareHevc { hardwareVideoCodecs.append("video/hevc") }

    return [
      "hardwareVideoCodecs": hardwareVideoCodecs,
      "supportedFormats": [
        "automatic",
        "hls",
        "httpFlv",
        "mp4",
        "mov",
        "matroska",
        "flv",
      ],
      "maxConcurrentVideoDecoders": 1,
    ]
  }

  static func fallbackMetrics(
    openDurationMs: Int64?,
    firstFrameDurationMs: Int64?,
    bufferedDurationMs: Int64,
    bufferedBytes: Int,
    droppedVideoFrames: Int,
    audioUnderruns: Int,
    reconnectCount: Int
  ) -> [String: Any?] {
    [
      "openDurationMs": openDurationMs,
      "firstFrameDurationMs": firstFrameDurationMs,
      "rebufferCount": 0,
      "rebufferDurationMs": 0,
      "bufferedDurationMs": bufferedDurationMs,
      "bufferedBytes": bufferedBytes,
      "droppedVideoFrames": droppedVideoFrames,
      "audioUnderruns": audioUnderruns,
      "reconnectCount": reconnectCount,
    ]
  }

  static func fullState(
    playerId: Int64,
    generation: UInt64,
    state: [String: Any?]
  ) -> [String: Any?] {
    [
      "playerId": playerId,
      "protocolVersion": 1,
      "generation": generation,
      "type": "state",
      "state": state,
    ]
  }

  static func stateDelta(
    playerId: Int64,
    generation: UInt64,
    delta: [String: Any?]
  ) -> [String: Any?] {
    [
      "playerId": playerId,
      "protocolVersion": 1,
      "generation": generation,
      "type": "stateDelta",
      "delta": delta,
    ]
  }
}
