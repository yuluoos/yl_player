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
  static const drmConfigInvalid = 'drm.config_invalid';
  static const drmUnsupported = 'drm.unsupported';
  static const drmSchemeMismatch = 'drm.scheme_mismatch';
  static const drmEncryptionModeUnsupported = 'drm.encryption_mode_unsupported';
  static const drmLicenseDenied = 'drm.license_denied';
  static const drmLicenseExpired = 'drm.license_expired';
  static const drmLicenseTimeout = 'drm.license_timeout';
  static const drmLicenseFailed = 'drm.license_failed';
  static const drmLicenseRedirectRejected = 'drm.license_redirect_rejected';
  static const drmPayloadTooLarge = 'drm.payload_too_large';
  static const drmLicenseResponseInvalid = 'drm.license_response_invalid';
  static const drmSessionFailed = 'drm.session_failed';
  static const drmProtectionInsufficient = 'drm.protection_insufficient';
  static const drmProvisioningRequired = 'drm.provisioning_required';

  static const playerDisposed = 'player.disposed';
  static const platformUnavailable = 'platform.unavailable';
  static const platformIncompatible = 'platform.incompatible';
  static const loadCancelled = 'load.cancelled';
  static const sessionStale = 'session.stale';
  static const policyUnsupported = 'policy.unsupported';
  static const videoConstraintsReloadRequired =
      'policy.video_constraints_reload_required';
  static const qualityConstraintUnsupported =
      'decoder.quality_constraint_unsupported';
  static const sourceInvalid = 'source.invalid';
  static const sourceMissing = 'source.missing';
  static const networkFailed = 'network.failed';
  static const networkProtocolUnsupported = 'network.protocol_unsupported';

  /// The source host could not be resolved from structured platform DNS evidence.
  static const networkDnsFailed = 'network.dns_failed';

  /// The media server returned HTTP 403. This failure is not retryable.
  static const networkHttpForbidden = 'network.http_forbidden';

  /// RTMP connection or setup failed before playback.
  static const networkRtmpHandshakeFailed = 'network.rtmp_handshake_failed';

  /// The server denied the requested stream. This failure is not retryable.
  static const networkRtmpStreamUnavailable = 'network.rtmp_stream_unavailable';

  /// An established RTMP playback connection was lost.
  static const networkRtmpDisconnected = 'network.rtmp_disconnected';

  /// RTMP tracks or codec configuration changed within an established epoch.
  static const containerRtmpTrackLayoutChanged =
      'container.rtmp_track_layout_changed';
  static const containerUnsupported = 'container.unsupported';
  static const dashManifestInvalid = 'container.dash_manifest_invalid';
  static const dashDynamicUnsupported = 'container.dash_dynamic_unsupported';
  static const dashProtectionUnsupported =
      'container.dash_protection_unsupported';
  static const dashSegmentBaseUnsupported =
      'container.dash_segment_base_unsupported';
  static const dashManifestTooLarge = 'resource.dash_manifest_too_large';

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
