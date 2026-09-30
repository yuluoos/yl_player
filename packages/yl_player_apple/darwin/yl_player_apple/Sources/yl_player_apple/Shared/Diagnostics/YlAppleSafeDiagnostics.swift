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
    let safeCode = publicCodes.contains(code) || YlFairPlayFailure.codes.contains(code) || code.range(of: "^avplayer\\.-?[0-9]{1,20}$", options: .regularExpression) != nil
      ? code : "platform.failure"
    return .init(category: native.map { YlAppleFailureMapper.category($0.category) } ?? previous?.category ?? .internalFailure,
      code: safeCode, message: publicMessages[safeCode] ?? YlFairPlayFailure.messages[safeCode] ?? "Playback failed for an unknown reason.",
      retryable: retryableCodes.contains(safeCode),
      scope: scope, diagnosticId: identifier())
  }
  // Package-owned classifications only. A syntactically safe source-derived
  // identifier is still private and must not be published as an error code.
  private static let publicCodes: Set<String> = [
    "decoder.audio_opus_unsupported",
    "decoder.audio_opus_failed",
    "policy.opus_unsupported",
    "policy.opus_track_switch_unsupported",

    "container.dash_manifest_invalid",
    "container.dash_dynamic_unsupported",
    "container.dash_protection_unsupported",
    "container.dash_segment_base_unsupported",
    "resource.dash_manifest_too_large",

    "render.video_surface_failed", "render.hdr_surface_unavailable",
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
    "container.avi_timing_unsupported",
    "container.avi_open_failed",
    "container.avi_seek_failed",
    "container.avi_malformed",
    "container.avi_live_unsupported",
    "container.mpegts_open_failed", "container.mpegts_seek_failed", "container.mpegts_malformed", "container.mpegts_live_unsupported",
    "container.mkv_seek_failed",
    "container.native_fallback_required",
    "container.network_mkv_live_unsupported",
    "container.unsupported",
    "decoder.audio_aac_unsupported",
    "decoder.audio_ac3_unsupported",
    "decoder.audio_eac3_unsupported",
    "decoder.audio_flac_unsupported",
    "decoder.audio_dts_unsupported",
    "decoder.audio_unsupported",
    "decoder.dolby_vision_unsupported",
    "decoder.dolby_vision_fel_invalid",
    "decoder.dolby_vision_fel_metadata_unsupported",
    "decoder.fel_probe_requires_rewind",
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
    "network.rtmp_handshake_failed", "network.rtmp_disconnected", "network.rtmp_stream_unavailable",
    "container.rtmp_track_layout_changed",
    "network.cancelled",
    "network.configuration",
    "network.connect_timeout",
    "network.content_changed",
    "network.encoding_unsupported",
    "network.framing",
    "network.headers_too_large",
    "network.http_status",
    "network.http_forbidden",
    "network.dns_failed",
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
    "policy.video_constraints_reload_required",
    "policy.video_selection_unsupported",
    "source.seek_failed",
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
  private static let retryableCodes: Set<String> = [
    "network.rtmp_handshake_failed", "network.rtmp_disconnected",
    "network.dns_failed", "network.connect_timeout", "network.read_timeout",
  ]
  private static let publicMessages: [String: String] = [
    "decoder.audio_opus_unsupported": "Opus currently requires mapping family 0 and mono or stereo at 48 kHz. Try another audio track.",
    "decoder.audio_opus_failed": "The Opus audio packet or timing is invalid. Try another audio track or a complete media file.",
    "policy.opus_unsupported": "Opus currently supports ordinary Matroska VOD without strict networking, buffer or hardware policies.",
    "policy.opus_track_switch_unsupported": "Activate or resume playback before switching an Opus track.",

    "container.avi_timing_unsupported": "The AVI video lacks supported presentation timing. Use a file with explicit timestamps or Baseline AVC without frame reordering.",
    "container.avi_open_failed": "The AVI media could not be opened. Check that the source is complete and uses supported codecs.",
    "container.avi_seek_failed": "The AVI seek failed. Try another position or a complete media file with a usable index.",
    "container.avi_malformed": "The AVI packet stream is damaged. Try a complete copy of the media.",
    "container.avi_live_unsupported": "AVI currently supports on-demand playback only. Use a supported live stream format.",
    "container.mpegts_open_failed": "The MPEG-TS media or its timeline could not be read. Check that the source contains a complete supported transport stream.",
    "container.mpegts_seek_failed": "The MPEG-TS seek could not find a usable keyframe within the bounded search. Try an earlier position or a media file with more frequent keyframes.",
    "container.mpegts_malformed": "The MPEG-TS packet stream is damaged. Try a complete copy of the media.",
    "container.mpegts_live_unsupported": "Standalone MPEG-TS currently supports on-demand playback only. Use a supported live stream format.",
    "decoder.audio_flac_unsupported": "This FLAC audio configuration is unsupported; use 16- or 24-bit mono/stereo audio on a device with a FLAC decoder.",
    "container.dash_manifest_invalid": "The DASH manifest could not be parsed. Ask the provider for a valid UTF-8 MPD.",
    "container.dash_dynamic_unsupported": "Dynamic DASH manifests are not supported by this playback path. Choose a static DASH VOD source.",
    "container.dash_protection_unsupported": "The DASH manifest contains a protected-content declaration unsupported by this playback path. Choose a compatible source.",
    "container.dash_segment_base_unsupported": "DASH SegmentBase addressing is not supported by this playback path. Choose a compatible SegmentTemplate or SegmentList source.",
    "resource.dash_manifest_too_large": "The DASH manifest exceeds the 2 MiB input limit. Ask the provider for a smaller manifest.",

    "source.seek_failed": "The playback position could not be restored. Reload the source to continue.",
    "policy.video_selection_unsupported": "The requested video quality is unavailable for this source.",
    "policy.video_constraints_reload_required": "Reload the DASH source with new video constraints to change or clear the limits.",
    "decoder.quality_constraint_unsupported": "The source cannot satisfy the requested video constraints.",
    "network.rtmp_handshake_failed": "The RTMP connection could not be established. Check the server and connection, then try again.",
    "network.rtmp_disconnected": "The RTMP stream was disconnected. Check the connection and try again.",
    "network.rtmp_stream_unavailable": "The RTMP stream is unavailable. Check the stream address and access permissions.",
    "container.rtmp_track_layout_changed": "The RTMP track configuration changed. Reload the stream to continue playback.",
    "decoder.dolby_vision_unsupported": "This Dolby Vision profile is not supported. Try a compatible version of the media.",
    "decoder.dolby_vision_fel_metadata_unsupported": "This Dolby Vision enhancement metadata is not supported. Try a base-layer or compatible version.",
    "network.connect_timeout": "The media request timed out while connecting. Check the network connection and try again.",
    "network.read_timeout": "The media request timed out while reading. Check the network connection and try again.",
    "decoder.video_hardware_unavailable": "A required hardware video decoder is unavailable. Close other media apps or choose compatible media.",
    "network.cancelled": "The media request was cancelled.",
    "network.dns_failed": "The media host could not be resolved. Check the network connection and source host configuration.",
    "network.http_forbidden": "The media server refused the request. Check access credentials and request configuration.",
    "network.retry_exhausted": "The configured network retry attempts were exhausted. Check the connection and try again.",
  ]
  /// No heuristic redactor can prove absence of encoded credentials or paths.
  /// Keep only a fixed diagnostic; package error codes carry the classification.
  static func diagnostic(_ error: Error) -> String { "Playback operation failed." }
  static func identifier() -> String { "apple-" + UUID().uuidString.lowercased() }
}
