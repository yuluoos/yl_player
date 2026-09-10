import Foundation
import QuartzCore

enum YlAppleSafeDiagnostics {
  private static let epoch = CACurrentMediaTime()
  static func nowMilliseconds() -> Int64 {
    max(0, Int64((CACurrentMediaTime() - epoch) * 1000))
  }
  /// This is the single error-publication boundary. Arbitrary NSError/Pigeon
  /// fields are untrusted; no source-derived strings are copied to the envelope.
  static func failure(_ error: Error, scope: AppleFailureScope) -> AppleFailureMessage {
    let native = error as? NativePlayerError
    let pigeon = error as? PigeonError
    let previous = pigeon?.details as? AppleFailureMessage
    let code = native?.code ?? pigeon?.code ?? "platform.failure"
    let safeCode = publicCodes.contains(code) || code.range(of: "^avplayer\\.-?[0-9]{1,20}$", options: .regularExpression) != nil
      ? code : "platform.failure"
    return .init(category: native.map { YlAppleFailureMapper.category($0.category) } ?? previous?.category ?? .internalFailure,
      code: safeCode, message: "Playback operation failed.", retryable: false,
      scope: scope, diagnosticId: identifier())
  }
  // Package-owned classifications only. A syntactically safe source-derived
  // identifier is still private and must not be published as an error code.
  private static let publicCodes: Set<String> = [
    "audio.activation_failed",
    "avplayer.failed",
    "avplayer.first_frame_timeout",
    "avplayer.stall_timeout",
    "container.flv_malformed",
    "container.flv_open_failed",
    "container.headers_require_fallback",
    "container.hls_manifest_invalid",
    "container.hls_url_invalid",
    "container.mkv_malformed",
    "container.mkv_open_failed",
    "container.mkv_seek_failed",
    "container.native_fallback_required",
    "container.network_mkv_live_unsupported",
    "container.unsupported",
    "decoder.audio_aac_unsupported",
    "decoder.audio_failed",
    "decoder.audio_mp3_unsupported",
    "decoder.failed",
    "decoder.quality_constraint_unsupported",
    "decoder.unavailable",
    "decoder.unsupported",
    "decoder.video_configuration_invalid",
    "decoder.video_decode_failed",
    "decoder.video_hardware_unavailable",
    "internal.fallback_invariant",
    "ios.audio_session_failed",
    "network.cancelled",
    "network.configuration",
    "network.connect_timeout",
    "network.content_changed",
    "network.encoding_unsupported",
    "network.framing",
    "network.headers_too_large",
    "network.http_status",
    "network.invalid_redirect",
    "network.local_proxy_unavailable",
    "network.managed",
    "network.protocol_unsupported",
    "network.range_invalid",
    "network.range_not_supported",
    "network.read_timeout",
    "network.redirect_invalid",
    "network.redirect_limit",
    "network.request",
    "network.response_invalid",
    "network.retry_exhausted",
    "platform.failure",
    "playback.speed_invalid",
    "player.detached",
    "player.disposed",
    "policy.unsupported",
    "protocol.mismatch",
    "render.audio_engine_failed",
    "resource.exhausted",
    "resource.hls_manifest_too_large",
    "resource.network_buffer_limit",
    "resource.player_failed",
    "resource.video_decoder_backpressure_timeout",
    "resource.video_decoder_limit",
    "session.failed",
    "session.stale",
    "source.invalid",
    "source.invalid_argument",
    "source.invalid_uri",
    "source.not_live",
    "source.not_seekable",
    "source.quality_constraint_invalid",
    "track.not_found",
  ]
  /// No heuristic redactor can prove absence of encoded credentials or paths.
  /// Keep only a fixed diagnostic; package error codes carry the classification.
  static func diagnostic(_ error: Error) -> String { "Playback operation failed." }
  static func identifier() -> String { "apple-" + UUID().uuidString.lowercased() }
}
