import 'package:flutter/foundation.dart';
import '../diagnostics/safe_diagnostics.dart';
import '../model/failure.dart';
import '../source/http_request.dart';
import '../source/media_source.dart';
import '../validation/v2_validation.dart';

/// These enums are Dart-only; they do not alter existing native wire ordinals.
enum YlDrmEncryption { cenc, cbcs }

enum YlDrmPostReplay { never, explicitlyIdempotent }

/// Copies opaque DRM data. Logging this value never prints its contents.
final class YlDrmBytes {
  YlDrmBytes(List<int> value) {
    if (value.length > 4 * 1024 * 1024) {
      throw ylDrmException(YlFailureCodes.drmPayloadTooLarge);
    }
    if (value.any((b) => b < 0 || b > 255)) {
      throw ylDrmException(YlFailureCodes.drmConfigInvalid);
    }
    _value = Uint8List.fromList(value);
  }
  late final Uint8List _value;
  Uint8List get bytes => Uint8List.fromList(_value);
  int get length => _value.length;
  @override
  bool operator ==(Object other) =>
      other is YlDrmBytes && listEquals(_value, other._value);
  @override
  int get hashCode => Object.hashAll(_value);
  @override
  String toString() => 'YlDrmBytes(<redacted>)';
}

/// Independent binary POST policy. HTTP is allowed only for explicitly opted-in
/// numeric loopback fixtures. Cross-origin redirects are always forbidden,
/// because even a credential-stripped license challenge can be sensitive.
final class YlDrmLicenseEndpoint {
  factory YlDrmLicenseEndpoint(
    Uri uri, {
    YlHttpRequest? request,
    Duration timeout = const Duration(seconds: 10),
    YlDrmPostReplay replay = YlDrmPostReplay.never,
    int maxRetries = 0,
    bool allowSameOriginRedirects = false,
    bool allowInsecureLoopback = false,
    int maxResponseBytes = 4 * 1024 * 1024,
  }) {
    try {
      final canonical = Uri.parse(uri.toString());
      final metadata = request ?? YlHttpRequest();
      final loopback = canonical.host == '127.0.0.1' || canonical.host == '::1';
      if ((canonical.scheme != 'https' &&
              !(allowInsecureLoopback &&
                  loopback &&
                  canonical.scheme == 'http')) ||
          canonical.userInfo.isNotEmpty ||
          canonical.hasFragment ||
          canonical.toString().length > 8192 ||
          timeout <= Duration.zero ||
          timeout > const Duration(seconds: 60) ||
          maxRetries < 0 ||
          maxRetries > 2 ||
          (maxRetries != 0 && replay == YlDrmPostReplay.never) ||
          maxResponseBytes < 1 ||
          maxResponseBytes > 4 * 1024 * 1024) {
        throw ylDrmException(YlFailureCodes.drmConfigInvalid);
      }
      validateYlSource(YlNetworkSource(canonical, request: metadata));
      for (final name in [
        ...metadata.headers.keys,
        ...metadata.credentials.keys,
      ]) {
        if (['content-type', 'accept-encoding'].contains(name.toLowerCase())) {
          throw ylDrmException(YlFailureCodes.drmConfigInvalid);
        }
      }
      return YlDrmLicenseEndpoint._(
        canonical,
        metadata,
        timeout,
        replay,
        maxRetries,
        allowSameOriginRedirects,
        allowInsecureLoopback,
        maxResponseBytes,
      );
    } catch (_) {
      throw ylDrmException(YlFailureCodes.drmConfigInvalid);
    }
  }
  const YlDrmLicenseEndpoint._(
    this.uri,
    this.request,
    this.timeout,
    this.replay,
    this.maxRetries,
    this.allowSameOriginRedirects,
    this.allowInsecureLoopback,
    this.maxResponseBytes,
  );
  final Uri uri;
  final YlHttpRequest request;
  final Duration timeout;
  final YlDrmPostReplay replay;
  final int maxRetries;
  final bool allowSameOriginRedirects;
  final bool allowInsecureLoopback;
  final int maxResponseBytes;
  @override
  bool operator ==(Object other) =>
      other is YlDrmLicenseEndpoint &&
      uri == other.uri &&
      request == other.request &&
      timeout == other.timeout &&
      replay == other.replay &&
      maxRetries == other.maxRetries &&
      allowSameOriginRedirects == other.allowSameOriginRedirects &&
      allowInsecureLoopback == other.allowInsecureLoopback &&
      maxResponseBytes == other.maxResponseBytes;
  @override
  int get hashCode => Object.hash(
    uri,
    request,
    timeout,
    replay,
    maxRetries,
    allowSameOriginRedirects,
    allowInsecureLoopback,
    maxResponseBytes,
  );
  @override
  String toString() => 'YlDrmLicenseEndpoint(<redacted>)';
}

sealed class YlDrmConfig {
  const YlDrmConfig({required this.license});
  final YlDrmLicenseEndpoint license;
}

final class YlWidevineDrm extends YlDrmConfig {
  const YlWidevineDrm({
    required super.license,
    this.encryption = YlDrmEncryption.cenc,
  });
  final YlDrmEncryption encryption;
  @override
  bool operator ==(Object other) =>
      other is YlWidevineDrm &&
      license == other.license &&
      encryption == other.encryption;
  @override
  int get hashCode => Object.hash(license, encryption);
  @override
  String toString() =>
      'YlWidevineDrm(<redacted>, encryption: ${encryption.name})';
}

/// Certificate acquisition and opaque content-ID selection belong to the host.
/// Supply authorized bytes explicitly; no URL parsing or default ID inference.
final class YlFairPlayDrm extends YlDrmConfig {
  YlFairPlayDrm({
    required super.license,
    required this.certificate,
    required this.contentId,
  }) {
    if (certificate.length == 0 ||
        certificate.length > 64 * 1024 ||
        contentId.length == 0 ||
        contentId.length > 8192) {
      throw ylDrmException(YlFailureCodes.drmConfigInvalid);
    }
  }
  final YlDrmBytes certificate;
  final YlDrmBytes contentId;
  @override
  bool operator ==(Object other) =>
      other is YlFairPlayDrm &&
      license == other.license &&
      certificate == other.certificate &&
      contentId == other.contentId;
  @override
  int get hashCode => Object.hash(license, certificate, contentId);
  @override
  String toString() => 'YlFairPlayDrm(<redacted>)';
}

void validateYlDrmSource(YlNetworkSource source) {
  final drm = source.drm;
  if (drm == null) return;
  if (!['http', 'https'].contains(source.uri.scheme) ||
      (drm is YlWidevineDrm && source.format != YlMediaFormat.dash) ||
      (drm is YlFairPlayDrm && source.format != YlMediaFormat.hls)) {
    throw ylDrmException(YlFailureCodes.drmConfigInvalid);
  }
}

void validateYlDrmPlatform(
  YlDrmConfig config,
  TargetPlatform platform, {
  int? androidApi,
}) {
  if (config is YlWidevineDrm) {
    if (platform != TargetPlatform.android) {
      throw ylDrmException(YlFailureCodes.drmSchemeMismatch);
    }
    if (androidApi == null || androidApi < 24) {
      throw ylDrmException(YlFailureCodes.drmUnsupported);
    }
    if (config.encryption == YlDrmEncryption.cbcs && androidApi < 25) {
      throw ylDrmException(YlFailureCodes.drmEncryptionModeUnsupported);
    }
  } else if (platform != TargetPlatform.iOS &&
      platform != TargetPlatform.macOS) {
    throw ylDrmException(YlFailureCodes.drmSchemeMismatch);
  }
}

int _failureSerial = 0;

/// Constructs diagnostics from allowlisted code only; never takes server prose.
YlPlayerException ylDrmException(String code) => YlPlayerException(
  YlFailure(
    category: switch (code) {
      YlFailureCodes.loadCancelled => YlFailureCategory.cancelled,
      YlFailureCodes.drmConfigInvalid => YlFailureCategory.source,
      YlFailureCodes.drmPayloadTooLarge ||
      YlFailureCodes.resourceExhausted => YlFailureCategory.resource,
      YlFailureCodes.drmUnsupported ||
      YlFailureCodes.drmSchemeMismatch ||
      YlFailureCodes.drmEncryptionModeUnsupported =>
        YlFailureCategory.unsupported,
      _ => YlFailureCategory.network,
    },
    code: code,
    message: YlSafeDiagnostics.messageForCode(code),
    retryable: false,
    scope: YlFailureScope.command,
    diagnosticId: 'drm-${++_failureSerial}',
  ),
);
