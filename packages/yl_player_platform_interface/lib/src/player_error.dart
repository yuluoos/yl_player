/// Stable high-level failure categories exposed across platforms.
enum YlPlayerErrorCategory {
  source,
  network,
  container,
  decoderUnsupported,
  decoderFailure,
  render,
  resource,
  cancelled,
  internal,
}

/// A stable public error with optional platform diagnostics.
final class YlPlayerError implements Exception {
  const YlPlayerError({
    required this.category,
    required this.code,
    required this.message,
    this.platformDiagnostic,
  });

  final YlPlayerErrorCategory category;
  final String code;
  final String message;
  final String? platformDiagnostic;

  @override
  String toString() => 'YlPlayerError($code, ${category.name}): $message';
}
