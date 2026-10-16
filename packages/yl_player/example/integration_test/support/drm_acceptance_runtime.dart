import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'drm_acceptance_case.dart';

/// Revalidates authorization for each load. Fault endpoints replace the entire
/// license policy; provider credentials never flow into the local fixture.
YlNetworkSource drmAcceptanceSource(
  DrmAcceptanceCase resource, {
  required DateTime now,
  YlDrmLicenseEndpoint? license,
}) {
  final definition = resource.runtimeDefinition(now: now);
  final endpoint =
      license ??
      YlDrmLicenseEndpoint(
        Uri.parse(definition['licenseUrl'] as String),
        request: YlHttpRequest(
          headers: Map<String, String>.from(
            definition['licenseHeaders'] as Map,
          ),
          credentials: Map<String, String>.from(
            definition['licenseCredentials'] as Map,
          ),
        ),
      );
  return YlNetworkSource(
    Uri.parse(definition['mediaUrl'] as String),
    format: resource.platform == 'android'
        ? YlMediaFormat.dash
        : YlMediaFormat.hls,
    drm: resource.platform == 'android'
        ? YlWidevineDrm(license: endpoint)
        : YlFairPlayDrm(
            license: endpoint,
            certificate: YlDrmBytes(
              base64Decode(definition['certificateBase64'] as String),
            ),
            contentId: YlDrmBytes(
              base64Decode(definition['contentIdBase64'] as String),
            ),
          ),
  );
}

Future<T> drmSettle<T>(WidgetTester tester, Future<T> operation) async {
  var complete = false;
  T? value;
  Object? error;
  operation.then(
    (result) {
      value = result;
      complete = true;
    },
    onError: (Object caught) {
      error = caught;
      complete = true;
    },
  );
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (!complete && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  if (!complete) throw TimeoutException('DRM acceptance deadline');
  if (error != null) throw error!;
  return value as T;
}

Future<void> drmState(
  WidgetTester tester,
  YlPlayerController player,
  bool Function() matches,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!matches()) {
    if (player.state.failure case final failure?) {
      throw YlPlayerException(failure);
    }
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('DRM acceptance state deadline');
    }
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

String drmSafeCode(Object error) {
  if (error is TimeoutException) return 'drm.acceptance_timeout';
  if (error is FormatException) return 'drm.acceptance_config_invalid';
  if (error is YlPlayerException &&
      const {
        YlFailureCodes.drmConfigInvalid,
        YlFailureCodes.drmUnsupported,
        YlFailureCodes.drmLicenseDenied,
        YlFailureCodes.drmLicenseExpired,
        YlFailureCodes.drmLicenseTimeout,
        YlFailureCodes.drmLicenseFailed,
        YlFailureCodes.drmLicenseRedirectRejected,
        YlFailureCodes.drmProtectionInsufficient,
        YlFailureCodes.drmSessionFailed,
        YlFailureCodes.drmPayloadTooLarge,
        YlFailureCodes.drmLicenseResponseInvalid,
        YlFailureCodes.loadCancelled,
      }.contains(error.failure.code)) {
    return error.failure.code;
  }
  return 'drm.acceptance_failed';
}

/// Preserves only a typed public code; success and arbitrary exceptions can
/// never satisfy a negative assertion. Subscribe before awaiting other events.
Future<String?> drmCaptureLoadFailure(Future<Object?> operation) =>
    operation.then(
      (_) => null,
      onError: (Object error) =>
          error is YlPlayerException ? error.failure.code : null,
    );
