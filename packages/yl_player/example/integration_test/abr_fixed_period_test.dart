import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/abr_network_preflight.dart';
import 'support/abr_network_series.dart';
import 'support/resource_series.dart';

/// Use prepare_fixture.py --missing-high-after 2. All three platforms run the
/// same public path; no platform-specific IDs or native private probes.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'fixed survives existing Period then missing returns auto with caps',
    (tester) async {
      final config = parseAbrConfig({
        'runId': const String.fromEnvironment('YL_ABR_RUN'),
        'mode': 'fixed',
        'url': const String.fromEnvironment('YL_ABR_URL'),
        'profileId': const String.fromEnvironment('YL_ABR_PROFILE'),
        'profileHash': const String.fromEnvironment('YL_ABR_PROFILE_SHA256'),
        'mediaHash': const String.fromEnvironment('YL_ABR_MEDIA_SHA256'),
      });
      YlPlayerController? player;
      AbrNetworkSeries? series;
      final clock = Stopwatch()..start();
      var outcome = 'failed', stage = 'preflight', cleaned = false;
      String? failureCode;
      String? failureType;
      bool? beforeRollbackAutomatic;
      bool? afterRollbackAutomatic;
      try {
        await preflightAbr(config);
        stage = 'create';
        final owner = await createResourceOwner(
          YlPlayerController.create(),
          timeout: const Duration(seconds: 20),
          release: (YlPlayerController p) => p.dispose(),
        );
        player = owner;
        await tester.pumpWidget(
          MaterialApp(home: YlPlayerView(controller: owner)),
        );
        stage = 'load';
        final session = await owner
            .load(
              YlNetworkSource(
                Uri.parse(config['url']!),
                format: YlMediaFormat.dash,
              ),
              options: const YlLoadOptions(
                videoConstraints: YlVideoConstraints(
                  maxWidth: 640,
                  maxHeight: 360,
                  maxBitrate: 700000,
                ),
              ),
            )
            .timeout(const Duration(seconds: 20));
        stage = 'ready';
        await session.ready.timeout(const Duration(seconds: 20));
        series = AbrNetworkSeries(session.id);
        stage = 'select-fixed';
        final high = owner.state.videoTracks
            .where(
              (t) => t.width == 640 && t.height == 360 && t.bitrate == 700000,
            )
            .single;
        await session
            .selectVideoTrack(high.id)
            .timeout(const Duration(seconds: 10));
        // The command reply may precede its public state event. Observe the
        // committed fixed selection before using it as the rollback baseline.
        stage = 'fixed-state';
        final selectionDeadline = clock.elapsed + const Duration(seconds: 10);
        while (owner.state.videoSelection.isAutomatic &&
            clock.elapsed < selectionDeadline) {
          expect(owner.state.sessionId, session.id);
          expect(owner.state.failure, isNull);
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(owner.state.videoSelection.isAutomatic, isFalse);
        // A preparation failure must preserve the committed selection.
        stage = 'rollback';
        final fixed = owner.state.videoSelection;
        beforeRollbackAutomatic = fixed.isAutomatic;
        stage = 'rollback-command';
        await expectLater(
          session
              .setVideoConstraints(
                const YlVideoConstraints(maxWidth: 1, maxHeight: 1),
              )
              .timeout(const Duration(seconds: 10)),
          throwsA(isA<YlPlayerException>()),
        );
        stage = 'rollback-state';
        afterRollbackAutomatic = owner.state.videoSelection.isAutomatic;
        expect(owner.state.videoSelection, fixed);
        stage = 'play';
        await session.play().timeout(const Duration(seconds: 10));
        await session.firstFrame.timeout(const Duration(seconds: 20));
        Future<void> until(
          bool Function(YlPlayerState) predicate, {
          bool fixedRequired = false,
        }) async {
          final deadline = clock.elapsed + const Duration(seconds: 60);
          while (clock.elapsed < deadline) {
            final state = owner.state;
            expect(state.sessionId, session.id);
            expect(state.failure, isNull);
            series!.add(state, clock.elapsedMicroseconds);
            if (fixedRequired &&
                state.timeline.position < const Duration(seconds: 8)) {
              expect(state.videoSelection.isAutomatic, isFalse);
            }
            if (predicate(state)) return;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          throw TimeoutException('Owned Period observation deadline');
        }

        stage = 'fixed-existing-period';
        await until(
          (s) =>
              s.timeline.position > const Duration(milliseconds: 4500) &&
              s.timeline.position < const Duration(seconds: 8) &&
              s.videoGeometry?.encodedSize.width == 640 &&
              !s.videoSelection.isAutomatic,
          fixedRequired: true,
        );
        stage = 'missing-period';
        await until(
          (s) =>
              s.timeline.position >= const Duration(seconds: 8) &&
              s.videoSelection.isAutomatic &&
              s.videoSelection.reason ==
                  YlVideoSelectionReason.trackUnavailable &&
              s.videoGeometry?.encodedSize.width == 320,
          fixedRequired: true,
        );
        stage = 'caps-seek';
        await session.pause().timeout(const Duration(seconds: 10));
        await Future.wait([
          session.setVideoConstraints(
            const YlVideoConstraints(
              maxWidth: 320,
              maxHeight: 180,
              maxBitrate: 350000,
            ),
          ),
          session.seekTo(const Duration(seconds: 1)),
        ]).timeout(const Duration(seconds: 20));
        expect(owner.state.videoSelection.isAutomatic, isTrue);
        await session.play().timeout(const Duration(seconds: 10));
        await until(
          (s) =>
              s.timeline.position > const Duration(milliseconds: 1500) &&
              s.timeline.position < const Duration(seconds: 4) &&
              s.videoSelection.isAutomatic &&
              s.videoGeometry?.encodedSize.width == 320,
        );
        expect(
          owner.state.videoTracks
              .where((t) => t.isSelected)
              .every(
                (t) => (t.width ?? 0) <= 320 && (t.bitrate ?? 0) <= 350000,
              ),
          isTrue,
        );
        outcome = 'completed';
      } on TimeoutException {
        outcome = 'timeout';
      } catch (error) {
        failureType = error.runtimeType.toString();
        failureCode = error is YlPlayerException
            ? error.failure.code
            : player?.state.failure?.code;
        outcome = 'failed';
      } finally {
        try {
          await player?.dispose().timeout(const Duration(seconds: 5));
          await tester.pumpWidget(const SizedBox.shrink());
          cleaned = player != null;
        } catch (_) {
          cleaned = false;
        }
        for (final sample in series?.samples ?? <Map<String, Object?>>[]) {
          debugPrint(
            'YL_ABR_PERIOD_SAMPLE=${jsonEncode({'runId': config['runId'], ...sample})}',
            wrapWidth: 100000,
          );
        }
        debugPrint(
          'YL_ABR_PERIOD_RESULT=${jsonEncode({'schemaVersion': 1, 'runId': config['runId'], 'mediaHash': config['mediaHash'], 'profileHash': config['profileHash'], 'failureCode': failureCode, 'failureType': failureType, 'beforeRollbackAutomatic': beforeRollbackAutomatic, 'afterRollbackAutomatic': afterRollbackAutomatic, 'outcome': outcome, 'stage': stage, 'cleaned': cleaned, 'sampleCount': series?.samples.length ?? 0, 'physicalOutputVerified': false, 'capabilityAccepted': false})}',
          wrapWidth: 100000,
        );
        // Preserve every sample and the result before the test process exits.
        await debugPrintDone.timeout(const Duration(seconds: 30));
      }
      expect(outcome, 'completed');
      expect(cleaned, isTrue);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
