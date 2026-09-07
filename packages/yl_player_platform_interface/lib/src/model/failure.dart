import 'value_helpers.dart';

final RegExp _safeFailureMetadata = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
);

String _displayFailureMetadata(String value) =>
    _safeFailureMetadata.hasMatch(value) ? value : '<redacted-metadata>';

enum YlFailureCategory {
  cancelled,
  unsupported,
  source,
  network,
  container,
  decoder,
  render,
  resource,
  protocol,
  platform,
  internal,
}

enum YlFailureScope { command, session, player }

abstract final class YlFailureCodes {
  static const playerDisposed = 'player.disposed';
  static const platformUnavailable = 'platform.unavailable';
  static const platformIncompatible = 'platform.incompatible';
  static const loadCancelled = 'load.cancelled';
  static const sessionStale = 'session.stale';
  static const policyUnsupported = 'policy.unsupported';
  static const sourceInvalid = 'source.invalid';
  static const sourceMissing = 'source.missing';
  static const networkFailed = 'network.failed';
  static const containerUnsupported = 'container.unsupported';
  static const decoderUnsupported = 'decoder.unsupported';
  static const decoderUnavailable = 'decoder.unavailable';
  static const resourceExhausted = 'resource.exhausted';
  static const protocolMismatch = 'protocol.mismatch';
  static const platformFailure = 'platform.failure';
  static const internal = 'internal.failure';
}

/// A transportable playback failure with safe public metadata.
final class YlFailure {
  const YlFailure({
    required this.category,
    required this.code,
    required this.message,
    required this.retryable,
    required this.scope,
    required this.diagnosticId,
  });

  final YlFailureCategory category;
  final String code;
  final String message;
  final bool retryable;
  final YlFailureScope scope;
  final String diagnosticId;

  @override
  int get hashCode =>
      Object.hash(category, code, message, retryable, scope, diagnosticId);

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        category == other.category &&
        code == other.code &&
        message == other.message &&
        retryable == other.retryable &&
        scope == other.scope &&
        diagnosticId == other.diagnosticId,
  );

  @override
  String toString() =>
      'YlFailure('
      'category: ${category.name}, '
      'code: ${_displayFailureMetadata(code)}, '
      'retryable: $retryable, '
      'scope: ${scope.name}, '
      'diagnosticId: ${_displayFailureMetadata(diagnosticId)}'
      ')';
}

/// Exception wrapper for a transportable playback failure.
final class YlPlayerException implements Exception {
  const YlPlayerException(this.failure);

  final YlFailure failure;

  @override
  String toString() => failure.toString();
}
