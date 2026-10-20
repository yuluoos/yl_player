import yl_player_media_core
import CoreMedia

/// Ordinary decoder ownership; FEL keeps its paired decoder/compositor resource.
/// Evidence describes the created decoder, never the requested policy.
protocol YlVideoDecoderResource: YlVideoToolboxDecoding {
  var hardwareEvidence: YlHardwareDecoderEvidence { get }
  var usesHardwareDecoder: Bool { get }
  func reserveSubmission(byteCount: Int, shouldCancel: () -> Bool) throws -> YlVideoDecodeReservation?
}

extension YlVideoToolboxDecoder: YlVideoDecoderResource {}

/// Hardware is attempted first. Malformed input and cancellation never trigger a
/// second decoder. Software factories must obtain an exact measured admission.
enum YlVideoDecoderSelection {
  static func choose(policy: YlDecoderPolicy,
      hardware: () throws -> any YlVideoDecoderResource,
      software: () throws -> any YlVideoDecoderResource) throws -> any YlVideoDecoderResource {
    do {
      let candidate = try hardware()
      guard candidate.hardwareEvidence.mode == .hardware else {
        candidate.dispose(); throw YlHardwareDecoderEvidence.unavailable()
      }
      return candidate
    } catch let error as NativePlayerError {
      guard ["decoder.unavailable", "decoder.video_hardware_unavailable", "resource.video_decoder_limit"].contains(error.code) else { throw error }
      guard policy != .hardwareRequired else { throw YlHardwareDecoderEvidence.unavailable() }
      return try software()
    }
  }
}
