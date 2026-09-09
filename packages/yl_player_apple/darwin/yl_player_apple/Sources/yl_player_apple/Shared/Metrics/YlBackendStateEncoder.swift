import CoreMedia
import Foundation
import VideoToolbox

enum YlBackendGeneration {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var value: UInt64 = 0

  static func next() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    value &+= 1
    return value
  }
}

struct YlNativeCapabilities {
  let hardwareVideoCodecs: [String]
  let supportedFormats: [String]
  let maxConcurrentVideoDecoders: Int
}

enum YlBackendStateEncoder {
  static let deviceCapabilities = capabilities(
    hardwareH264: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
    hardwareHevc: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
  )

  static func capabilities(
    hardwareH264: Bool,
    hardwareHevc: Bool
  ) -> YlNativeCapabilities {
    var hardwareVideoCodecs: [String] = []
    if hardwareH264 { hardwareVideoCodecs.append("video/avc") }
    if hardwareHevc { hardwareVideoCodecs.append("video/hevc") }

    return YlNativeCapabilities(hardwareVideoCodecs: hardwareVideoCodecs,
      supportedFormats: ["automatic", "hls", "httpFlv", "mp4", "mov", "matroska", "flv"],
      maxConcurrentVideoDecoders: 1)
  }

  static func fallbackMetrics(
    openDurationMs: Int64?, firstFrameDurationMs: Int64?,
    bufferedDurationMs: Int64, bufferedBytes: Int,
    droppedVideoFrames: Int, audioUnderruns: Int, reconnectCount: Int
  ) -> YlNativeMetrics {
    YlNativeMetrics(openDurationMs: openDurationMs,
      firstFrameDurationMs: firstFrameDurationMs, rebufferCount: 0,
      rebufferDurationMs: 0, bufferedDurationMs: bufferedDurationMs,
      bufferedBytes: bufferedBytes, droppedVideoFrames: droppedVideoFrames,
      audioUnderruns: audioUnderruns, reconnectCount: reconnectCount)
  }
}
