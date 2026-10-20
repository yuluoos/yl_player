import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/drm/license_timing.dart';
import 'support/drm_acceptance_case.dart';
import 'support/drm_acceptance_owner.dart';
import 'support/drm_acceptance_runtime.dart';

/// Only authorized physical runs may use this entry. A missing config fails;
/// a skipped/default test must never stand in for protected playback evidence.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'authorized DRM public lifecycle observations',
    (tester) async {
      final licenseTimings = LicenseTimingTrace();
      await withLicenseTimingTrace(
        licenseTimings,
        () async {
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
            final source = drmAcceptanceSource(
              resource,
              now: DateTime.now().toUtc(),
            );
            final player = await drmSettle(
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
            final session = await drmSettle(tester, player.load(source));
            await drmSettle(tester, session.ready);
            observed.add('ready');
            await drmSettle(tester, session.play());
            await drmSettle(tester, session.firstFrame);
            if (player.protectedVideoSurface?.sessionId != session.id.value) {
              throw const FormatException();
            }
            observed.add('protected_view_first_frame_signal');
            var position = player.state.timeline.position;
            await drmState(
              tester,
              player,
              () =>
                  player.state.timeline.position >
                  position + const Duration(seconds: 1),
            );
            observed.add('progress');
            await drmSettle(tester, session.pause());
            await drmState(
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
            await drmSettle(tester, session.seekTo(target));
            await drmState(
              tester,
              player,
              () =>
                  (player.state.timeline.position - target).abs() <
                  const Duration(seconds: 1),
            );
            observed.add('seek');
            await drmSettle(tester, session.play());
            position = player.state.timeline.position;
            await drmState(
              tester,
              player,
              () =>
                  player.state.timeline.position >
                  position + const Duration(seconds: 1),
            );
            observed.add('resume');
            final replacement = await drmSettle(tester, player.load(source));
            if (replacement.id == session.id) throw const FormatException();
            await drmSettle(tester, replacement.ready);
            await drmSettle(tester, replacement.play());
            await drmSettle(tester, replacement.firstFrame);
            observed.add('replacement_first_frame_signal');
            await drmSettle(tester, player.stop());
            await drmState(
              tester,
              player,
              () => player.state.sessionId == null,
            );
            try {
              await drmSettle(tester, replacement.play());
              throw const FormatException();
            } on YlPlayerException catch (error) {
              if (error.failure.code != YlFailureCodes.sessionStale) rethrow;
            }
            observed.add('stop_and_stale_session');
            succeeded = true;
          } catch (error) {
            failureCode = drmSafeCode(error);
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
        onClosed: (closed) {
          debugPrint(
            'YL_DRM_LICENSE_TIMINGS=${jsonEncode({'rows': closed.rows, 'omitted': closed.omitted, 'incomplete': closed.incomplete, 'boundary': 'license-http-wall-clock'})}',
            wrapWidth: 100000,
          );
        },
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
