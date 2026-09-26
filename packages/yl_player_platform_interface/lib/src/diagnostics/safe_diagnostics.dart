import '../model/failure.dart';

/// Centralized sanitization for public playback diagnostics.
abstract final class YlSafeDiagnostics {
  static const _fallbackMessage = 'Playback operation failed.';

  /// Fixed public guidance for recognized codes, never native error prose.
  static String messageForCode(String code) => switch (code) {
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
