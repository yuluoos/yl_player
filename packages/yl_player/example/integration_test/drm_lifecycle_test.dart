import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/drm_acceptance_case.dart';
import 'support/drm_acceptance_owner.dart';

/// Only authorized physical runs may use this entry. A missing config fails;
/// a skipped/default test must never stand in for protected playback evidence.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'authorized DRM public lifecycle observations',
    (tester) async {
      DrmAcceptanceCase? resource;
      final owner = DrmAcceptanceOwner<YlPlayerController>(
        release: (player) =>
            player.dispose().timeout(const Duration(seconds: 45)),
      );
      var failureCode = 'drm.acceptance_config_invalid';
      var succeeded = false;
      final observed = <String>[];
      try {
        resource = DrmAcceptanceCase.forRuntime(
          const String.fromEnvironment('YL_DRM_CASE'),
          platform: Platform.operatingSystem,
          now: DateTime.now().toUtc(),
        );
        final definition = resource.runtimeDefinition(
          now: DateTime.now().toUtc(),
        );
        final endpoint = YlDrmLicenseEndpoint(
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
        final source = YlNetworkSource(
          Uri.parse(definition['mediaUrl'] as String),
          format: Platform.isAndroid ? YlMediaFormat.dash : YlMediaFormat.hls,
          drm: Platform.isAndroid
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
        final player = await _settle(
          tester,
          owner.acquire(
            YlPlayerController.create(
              options: const YlPlayerOptions(
                decoderPolicy: YlDecoderPolicy.systemDefault,
              ),
            ),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(home: YlPlayerView(controller: player)),
        );
        final session = await _settle(tester, player.load(source));
        await _settle(tester, session.ready);
        observed.add('ready');
        await _settle(tester, session.play());
        await _settle(tester, session.firstFrame);
        if (player.protectedVideoSurface?.sessionId != session.id.value) {
          throw const FormatException();
        }
        observed.add('protected_view_first_frame_signal');
        var position = player.state.timeline.position;
        await _state(
          tester,
          player,
          () =>
              player.state.timeline.position >
              position + const Duration(seconds: 1),
        );
        observed.add('progress');
        await _settle(tester, session.pause());
        await _state(
          tester,
          player,
          () => player.state.status == YlPlaybackStatus.paused,
        );
        observed.add('pause');
        final target = Duration(
          milliseconds: definition['seekPositionMs'] as int,
        );
        final duration = player.state.timeline.duration;
        if (!player.state.timeline.isSeekable ||
            duration == null ||
            target >= duration - const Duration(seconds: 2)) {
          throw const FormatException();
        }
        await _settle(tester, session.seekTo(target));
        await _state(
          tester,
          player,
          () =>
              (player.state.timeline.position - target).abs() <
              const Duration(seconds: 1),
        );
        observed.add('seek');
        await _settle(tester, session.play());
        position = player.state.timeline.position;
        await _state(
          tester,
          player,
          () =>
              player.state.timeline.position >
              position + const Duration(seconds: 1),
        );
        observed.add('resume');
        final replacement = await _settle(tester, player.load(source));
        if (replacement.id == session.id) throw const FormatException();
        await _settle(tester, replacement.ready);
        await _settle(tester, replacement.play());
        await _settle(tester, replacement.firstFrame);
        observed.add('replacement_first_frame_signal');
        await _settle(tester, player.stop());
        await _state(tester, player, () => player.state.sessionId == null);
        try {
          await _settle(tester, replacement.play());
          throw const FormatException();
        } on YlPlayerException catch (error) {
          if (error.failure.code != YlFailureCodes.sessionStale) rethrow;
        }
        observed.add('stop_and_stale_session');
        succeeded = true;
      } catch (error) {
        failureCode = _safeCode(error);
      } finally {
        try {
          await owner.close(
            unmount: () => tester
                .pumpWidget(const SizedBox.shrink())
                .timeout(const Duration(seconds: 45)),
          );
        } catch (_) {
          succeeded = false;
          failureCode = 'drm.acceptance_cleanup_failed';
        }
      }
      debugPrint(
        'YL_DRM_ACCEPTANCE=${jsonEncode({if (resource != null) ...resource.report, 'stage': 'automated_public_lifecycle', 'automatedLifecycle': succeeded ? 'passed' : 'failed', 'physicalAcceptance': 'not_run', 'observed': observed, if (!succeeded) 'code': failureCode})}',
        wrapWidth: 100000,
      );
      if (!succeeded) fail('DRM acceptance did not complete: $failureCode');
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<T> _settle<T>(WidgetTester tester, Future<T> operation) async {
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

Future<void> _state(
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

String _safeCode(Object error) {
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
