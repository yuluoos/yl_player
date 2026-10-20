import Foundation
import YlFFmpegBridge

public func ylFallbackPacketReadError(
  result: Int32,
  inputError: NativePlayerError?,
  container: YlFallbackContainer
) -> NativePlayerError {
  if result == Int32(YLFResultCallbackFailed), let inputError {
    return inputError
  }
  let code: String
  let message: String
  switch container {
  case .flv:
    code = "container.flv_malformed"
    message = "The FLV packet stream is malformed."
  case .avi:
    code = result == Int32(YLFResultVideoConfigurationInvalid) ? "container.avi_timing_unsupported" : "container.avi_malformed"
    message = result == Int32(YLFResultVideoConfigurationInvalid)
      ? "The AVI video lacks supported presentation timing. Use a file with explicit timestamps or Baseline AVC without frame reordering."
      : "The AVI packet stream is malformed."
  case .mpegPs:
    return NativePlayerError(category: "container", code: "container.mpegps_malformed",
      message: "The MPEG-PS packet or timestamp is invalid.", diagnostic: "YlFFmpegBridge result \(result)")
  case .mpegTs:
    code = "container.mpegts_malformed"
    message = "The MPEG-TS packet stream is malformed."
  case .hlsMpegTs:
    code = "container.hls_mpegts_malformed"
    message = "The MPEG-TS HLS packet stream is malformed."
  case .matroska, .mp4:
    code = "container.mkv_malformed"
    message = "The managed packet stream is malformed."
  }
  return NativePlayerError(
    category: "container",
    code: code,
    message: message,
    diagnostic: "YlFFmpegBridge result \(result)"
  )
}
