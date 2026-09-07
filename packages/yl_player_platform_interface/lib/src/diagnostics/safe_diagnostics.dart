/// Centralized sanitization for public playback diagnostics.
abstract final class YlSafeDiagnostics {
  static const _fallbackMessage = 'Playback operation failed.';
  static const _redactedCredential = '<redacted-credential>';
  static const _redactedHeader = '<redacted-header>';
  static const _redactedPath = '<redacted-path>';
  static const _redactedQuery = '<redacted-query>';
  static const _redactedUri = '<redacted-uri>';
  static const _maximumLength = 512;

  static final RegExp _credentialPattern = RegExp(
    r'\b(?:bearer|basic)\s+\S+|'
    r'\b(?:password|passwd|credential|secret|token|api[_-]?key)\s*[=:]\s*\S+|'
    r'\b[^\s:@/]+:[^\s@/]+@',
    caseSensitive: false,
  );
  static final RegExp _genericHeaderPattern = RegExp(
    r'\b[A-Za-z][A-Za-z0-9-]*\s*:\s*\S+',
  );
  static final RegExp _lineBreakPattern = RegExp(r'[\r\n]+');
  static final RegExp _pathPattern = RegExp(
    r'(?:(?:[A-Za-z]:[\\/])|(?:~[\\/])|(?:\.\.?[\\/])|/)[^\s,;\)\]\}]+|'
    r'\b(?:[A-Za-z0-9._-]+[\\/])+(?:[A-Za-z0-9._-]+)(?::\d+(?::\d+)?)?',
  );
  static final RegExp _queryPattern = RegExp(r'\?[^\s#]*');
  static final RegExp _sensitiveHeaderPattern = RegExp(
    r'\b(?:authorization|proxy-authorization|cookie|set-cookie|'
    r'[A-Za-z0-9_-]*(?:token|key|secret|credential|auth)[A-Za-z0-9_-]*)'
    r'\s*:\s*[^\r\n]*',
    caseSensitive: false,
  );
  static final RegExp _stackFramePattern = RegExp(
    r'(?:^|\s)#\d+\s+|\bat\s+\S+\s*\(|'
    r'\([^\s()]+\.(?:dart|kt|java|swift|m|mm):\d+(?::\d+)?\)',
    caseSensitive: false,
    multiLine: true,
  );
  static final RegExp _uriPattern = RegExp(
    r'\b(?:[A-Za-z][A-Za-z0-9+.-]*://|(?:package|dart):)'
    r'[^\s<>()\[\]{}]+',
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
