import '../model/failure.dart';

/// Centralized sanitization for public playback diagnostics.
abstract final class YlSafeDiagnostics {
  static const _fallbackMessage = 'Playback operation failed.';

  /// Fixed public guidance for recognized codes, never native error prose.
  static String messageForCode(String code) => switch (code) {
    YlFailureCodes.drmSessionFailed =>
      'The system DRM session failed. Reload the source or check device DRM support.',
    YlFailureCodes.drmProtectionInsufficient =>
      'The required DRM protection is unavailable. Use a device and output path meeting the content protection requirements.',
    YlFailureCodes.drmProvisioningRequired =>
      'The device DRM system requires provisioning. Complete device DRM initialization before retrying.',
    YlFailureCodes.drmConfigInvalid =>
      'The DRM configuration is incomplete or invalid. Check delivery format, certificate, content ID and license policy.',
    YlFailureCodes.drmUnsupported =>
      'This adapter does not support the requested protected playback path.',
    YlFailureCodes.drmSchemeMismatch =>
      'The DRM scheme does not match this platform. Use Widevine on Android or FairPlay on Apple.',
    YlFailureCodes.drmEncryptionModeUnsupported =>
      'The requested encryption mode is unavailable on this operating system.',
    YlFailureCodes.drmLicenseDenied =>
      'The license server refused the request. Check authorization and license request configuration.',
    YlFailureCodes.drmLicenseExpired =>
      'The license has expired according to explicit DRM evidence. Renew authorization.',
    YlFailureCodes.drmLicenseTimeout =>
      'The license request exceeded its deadline.',
    YlFailureCodes.drmLicenseFailed =>
      'The license request failed. Check the connection and license service.',
    YlFailureCodes.drmLicenseRedirectRejected =>
      'The license redirect was rejected by the POST policy. Configure the final license endpoint.',
    YlFailureCodes.drmPayloadTooLarge =>
      'The DRM request or response exceeds its byte limit.',
    YlFailureCodes.drmLicenseResponseInvalid =>
      'The license server returned an empty or unsupported response.',

    YlFailureCodes.dashManifestInvalid =>
      'The DASH manifest could not be parsed. Ask the provider for a valid UTF-8 MPD.',
    YlFailureCodes.dashDynamicUnsupported =>
      'Dynamic DASH manifests are not supported by this playback path. Choose a static DASH VOD source.',
    YlFailureCodes.dashProtectionUnsupported =>
      'The DASH manifest contains a protected-content declaration unsupported by this playback path. Choose a compatible source.',
    YlFailureCodes.dashSegmentBaseUnsupported =>
      'DASH SegmentBase addressing is not supported by this playback path. Choose a compatible SegmentTemplate or SegmentList source.',
    YlFailureCodes.dashManifestTooLarge =>
      'The DASH manifest exceeds the 2 MiB input limit. Ask the provider for a smaller manifest.',

    'decoder.audio_opus_unsupported' =>
      'Opus currently requires CELT mode, mapping family 0 and mono or stereo at 48 kHz. Try an AAC or FLAC audio track.',
    'decoder.audio_opus_failed' =>
      'The Opus audio packet or timing is invalid. Try another audio track or a complete media file.',
    'policy.opus_track_switch_unsupported' =>
      'Switching to another Opus track is not supported yet. Keep the current track or use AAC.',
    'policy.opus_unsupported' =>
      'Opus currently supports ordinary Matroska VOD without managed networking, bounded buffering or hardware-required decoding.',

    'container.avi_timing_unsupported' =>
      'The AVI video lacks supported presentation timing. Use a file with explicit timestamps or Baseline AVC without frame reordering.',
    'container.avi_open_failed' =>
      'The AVI media could not be opened. Check that the source is complete and uses supported codecs.',
    'container.avi_seek_failed' =>
      'The AVI seek failed. Try another position or a complete media file with a usable index.',
    'container.avi_malformed' =>
      'The AVI packet stream is damaged. Try a complete copy of the media.',
    'container.avi_live_unsupported' =>
      'AVI currently supports on-demand playback only. Use a supported live stream format.',
    'container.mpegts_open_failed' =>
      'The MPEG-TS media or its timeline could not be read. Check that the source contains a complete supported transport stream.',
    'container.mpegts_seek_failed' =>
      'The MPEG-TS seek could not find a usable keyframe within the bounded search. Try an earlier position or a media file with more frequent keyframes.',
    'container.mpegts_malformed' =>
      'The MPEG-TS packet stream is damaged. Try a complete copy of the media.',
    'container.mpegts_live_unsupported' =>
      'Standalone MPEG-TS currently supports on-demand playback only. Use a supported live stream format.',

    'source.seek_failed' =>
      'The playback position could not be restored. Reload the source to continue.',
    'policy.video_selection_unsupported' =>
      'The requested video quality is unavailable for this source.',
    YlFailureCodes.networkProtocolUnsupported =>
      'The media transport protocol is not supported. Use a supported source protocol.',
    YlFailureCodes.networkRtmpHandshakeFailed =>
      'The RTMP connection could not be established. Check the connection and server configuration, then try again.',
    YlFailureCodes.networkRtmpStreamUnavailable =>
      'The RTMP stream is unavailable. Check the stream name and whether the publisher is active.',
    YlFailureCodes.networkRtmpDisconnected =>
      'The RTMP connection was lost during playback. Check the connection and try again.',
    YlFailureCodes.networkDnsFailed =>
      'The media host could not be resolved. Check the network connection and source host configuration.',
    YlFailureCodes.networkHttpForbidden =>
      'The media server refused the request. Check access credentials and request configuration.',
    'network.retry_exhausted' =>
      'The configured network retry attempts were exhausted. Check the connection and try again.',
    YlFailureCodes.loadCancelled => 'The operation was cancelled.',
    YlFailureCodes.containerRtmpTrackLayoutChanged =>
      'The RTMP track configuration changed. Reload the stream to continue playback.',
    YlFailureCodes.containerUnsupported =>
      'The media container is not supported. Try a compatible version of the media.',
    YlFailureCodes.videoConstraintsReloadRequired =>
      'Reload the DASH source with new video constraints to change or clear the limits.',
    YlFailureCodes.qualityConstraintUnsupported =>
      'The source cannot satisfy the requested video constraints. Choose compatible limits or another source.',
    YlFailureCodes.policyUnsupported =>
      'The requested playback policy is unsupported. Check the playback configuration.',
    _ => _fallbackMessage,
  };
  static const _redactedCredential = '<redacted-credential>';
  static const _redactedHeader = '<redacted-header>';
  static const _redactedPath = '<redacted-path>';
  static const _redactedQuery = '<redacted-query>';
  static const _redactedUri = '<redacted-uri>';
  static const _maximumLength = 512;
  static const _httpTokenCharacters = r"A-Za-z0-9!#$%&'*+\-.^_`|~";
  static const _sensitiveNameTerm = r'(?:token|key|secret|credential|auth)';

  static const _sensitiveHeaderNamePattern =
      '(?:authorization|proxy-authorization|cookie|set-cookie|'
      '[$_httpTokenCharacters]*$_sensitiveNameTerm'
      '[$_httpTokenCharacters]*)';

  static final RegExp _credentialPattern = RegExp(
    r'\b(?:bearer|basic)\s+\S+|'
    '(?<![$_httpTokenCharacters])[$_httpTokenCharacters]*'
    r'(?:password|passwd|credential|secret|token|key|auth)'
    '[$_httpTokenCharacters]*\\s*[=:]\\s*\\S+|'
    r'\b[^\s:@/]+:[^\s@/]+@',
    caseSensitive: false,
  );
  static final RegExp _genericHeaderPattern = RegExp(
    '(?<![$_httpTokenCharacters])'
    '[$_httpTokenCharacters]+\\s*:\\s*\\S+',
  );
  static final RegExp _lineBreakPattern = RegExp(r'[\r\n]+');
  static final RegExp _pathPattern = RegExp(
    r'(?:(?:[A-Za-z]:[\\/])|(?:~[\\/])|(?:\.\.?[\\/])|/)[^\s,;\)\]\}]+|'
    r'\b(?:[A-Za-z0-9._-]+[\\/])+(?:[A-Za-z0-9._-]+)(?::\d+(?::\d+)?)?',
  );
  static final RegExp _queryPattern = RegExp(r'\?[^\s#]*');
  static final RegExp _sensitiveHeaderPattern = RegExp(
    '(?<![$_httpTokenCharacters])'
    '$_sensitiveHeaderNamePattern\\s*:\\s*[^\\r\\n]*',
    caseSensitive: false,
  );
  static final RegExp _stackFramePattern = RegExp(
    r'(?:^|\s)#\d+\s+|\bat\s+\S+\s*\(|'
    r'\([^\s()]+\.(?:dart|kt|java|swift|m|mm):\d+(?::\d+)?\)',
    caseSensitive: false,
    multiLine: true,
  );
  static final RegExp _uriPattern = RegExp(
    r'(?<![A-Za-z0-9+.-])'
    '(?!$_sensitiveHeaderNamePattern\\s*:)'
    r'[A-Za-z][A-Za-z0-9+.-]*:[^\s<>()\[\]{}]+',
    caseSensitive: false,
  );

  /// Produces a bounded diagnostic string with sensitive shapes removed.
  static String redact(String input) {
    var output = input.replaceAll(_uriPattern, _redactedUri);
    output = output.replaceAll(_sensitiveHeaderPattern, _redactedHeader);
    output = output.replaceAll(_queryPattern, _redactedQuery);
    output = output.replaceAll(_credentialPattern, _redactedCredential);
    output = output.replaceAll(_pathPattern, _redactedPath);
    output = output.replaceAll(_lineBreakPattern, ' ');
    if (output.length > _maximumLength) {
      return output.substring(0, _maximumLength);
    }
    return output;
  }

  /// Returns a safe public message, using a fixed fallback for unsafe input.
  static String publicMessage(String input) {
    if (_containsUnsafeShape(input)) {
      return _fallbackMessage;
    }
    return redact(input);
  }

  static bool _containsUnsafeShape(String input) =>
      _uriPattern.hasMatch(input) ||
      _genericHeaderPattern.hasMatch(input) ||
      _credentialPattern.hasMatch(input) ||
      _lineBreakPattern.hasMatch(input) ||
      _stackFramePattern.hasMatch(input) ||
      _queryPattern.hasMatch(input) ||
      _pathPattern.hasMatch(input);
}
