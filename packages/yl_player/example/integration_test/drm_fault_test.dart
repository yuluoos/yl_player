import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/drm_acceptance_case.dart';
import 'support/drm_acceptance_owner.dart';
import 'support/drm_acceptance_runtime.dart';
import 'support/drm_fault_server.dart';

/// Requires a real authorized positive baseline. The loopback negative response
/// is a controlled transport fault, not provider denial/expiry/rotation evidence.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'authorized DRM controlled license fault',
    (tester) async {
      DrmAcceptanceCase? resource;
      DrmFaultServer? server;
      final owner = DrmAcceptanceOwner<YlPlayerController>(
        release: (player) =>
            player.dispose().timeout(const Duration(seconds: 45)),
      );
      final observed = <String>[];
      var succeeded = false;
      var failureCode = 'drm.acceptance_config_invalid';
      try {
        final fault = DrmFault.parse(
          const String.fromEnvironment('YL_DRM_FAULT'),
        );
        resource = DrmAcceptanceCase.forRuntime(
          const String.fromEnvironment('YL_DRM_CASE'),
          platform: Platform.operatingSystem,
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
        final baseline = await drmSettle(
          tester,
          player.load(
            drmAcceptanceSource(resource, now: DateTime.now().toUtc()),
          ),
        );
        await _playing(tester, player, baseline);
        observed.add('authorized_baseline_progress');
        final baselineSurface = player.protectedVideoSurface;
        server = await DrmFaultServer.start(fault);
        final candidate = drmCaptureLoadFailure(
          player.load(
            drmAcceptanceSource(
              resource,
              now: DateTime.now().toUtc(),
              license: server.endpoint(
                timeout: Duration(seconds: fault == DrmFault.cancel ? 30 : 2),
              ),
            ),
          ),
        );
        // Observe the POST before stopping: cancelling an unstarted load is not
        // evidence of cancellation while a license exchange is in flight.
        await drmSettle(
          tester,
          Future.any<void>([
            server.firstChallenge,
            candidate.then<void>(
              (_) => throw StateError('No in-flight challenge.'),
            ),
          ]),
        );
        observed.add('fault_challenge_received');
        if (fault == DrmFault.cancel) {
          await drmSettle(tester, player.stop());
        }
        final code = await drmSettle(tester, candidate);
        if (code != fault.expectedCode) {
          throw StateError('Unexpected failure code.');
        }
        observed.add('expected_failure');
        if (fault == DrmFault.cancel) {
          await drmState(tester, player, () => player.state.sessionId == null);
          if (player.protectedVideoSurface != null) {
            throw StateError('Stale surface.');
          }
          final stale = await drmSettle(
            tester,
            drmCaptureLoadFailure(baseline.play()),
          );
          if (stale != YlFailureCodes.sessionStale) {
            throw StateError('Stale session accepted.');
          }
          observed.add('stop_and_stale_session');
          final restored = await drmSettle(
            tester,
            player.load(
              drmAcceptanceSource(resource, now: DateTime.now().toUtc()),
            ),
          );
          if (restored.id == baseline.id) {
            throw StateError('Session identity reused.');
          }
          await _playing(tester, player, restored);
          observed.add('fresh_authorized_session_progress');
        } else {
          if (player.state.sessionId != baseline.id ||
              player.protectedVideoSurface != baselineSurface) {
            throw StateError('Failed candidate replaced current playback.');
          }
          await _progress(tester, player, baseline);
          observed.add('original_session_retained_and_progressing');
        }
        if (server.report['faultServerFailed'] != false ||
            server.challengeCount == 0) {
          throw StateError('Fault fixture failed.');
        }
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
        try {
          await server?.close().timeout(const Duration(seconds: 5));
        } catch (_) {
          succeeded = false;
          failureCode = 'drm.acceptance_cleanup_failed';
        }
      }
      if (server?.report['faultServerFailed'] == true) {
        succeeded = false;
        failureCode = 'drm.acceptance_failed';
      }
      debugPrint(
        'YL_DRM_ACCEPTANCE=${jsonEncode({if (resource != null) ...resource.report, if (server != null) ...server.report, 'stage': 'automated_controlled_license_fault', 'automatedFault': succeeded ? 'passed' : 'failed', 'physicalAcceptance': 'not_run', 'providerNegativeAcceptance': 'not_run', 'observed': observed, if (!succeeded) 'code': failureCode})}',
        wrapWidth: 100000,
      );
      if (!succeeded) {
        fail('DRM fault acceptance did not complete: $failureCode');
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<void> _playing(
  WidgetTester tester,
  YlPlayerController player,
  YlPlaybackSession session,
) async {
  await drmSettle(tester, session.ready);
  await drmSettle(tester, session.play());
  await drmSettle(tester, session.firstFrame);
  if (player.protectedVideoSurface?.sessionId != session.id.value) {
    throw StateError('Missing protected output identity.');
  }
  await _progress(tester, player, session);
}

Future<void> _progress(
  WidgetTester tester,
  YlPlayerController player,
  YlPlaybackSession session,
) async {
  final surface = player.protectedVideoSurface;
  final position = player.state.timeline.position;
  await drmState(tester, player, () {
    if (player.state.sessionId != session.id ||
        player.protectedVideoSurface != surface) {
      throw StateError('Playback identity changed during observation.');
    }
    return player.state.timeline.position >
        position + const Duration(seconds: 1);
  });
}
