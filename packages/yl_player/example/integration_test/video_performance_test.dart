import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/display_cleanup.dart';
import 'support/video_performance_series.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('yl_player_example/display_readback');
  Future<Map<String, Object?>> snapshot() async => (await channel
      .invokeMapMethod<String, Object?>('performance')
      .timeout(const Duration(seconds: 3)))!;
  testWidgets(
    'owned continuously playing renderer statistics',
    (tester) async {
      const runId = String.fromEnvironment('YL_VIDEO_METRICS_RUN_ID');
      if (!Platform.isMacOS ||
          kReleaseMode ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(runId)) {
        throw const FormatException(
          'Video performance probe configuration required',
        );
      }
      final clock = Stopwatch()..start();
      final outcomes = <String>[];
      var aborted = false;
      for (var attempt = 1; attempt <= 3; attempt++) {
        final series = VideoPerformanceSeries();
        final cleanup = DisplayTrialCleanup();
        YlPlayerController? player;
        Directory? directory;
        Map<String, Object?>? before, after;
        var outcome = aborted ? 'skipped' : 'failed';
        var stage = 'setup';
        var cleaned = false;
        var engine = 'unknown', decoder = 'unknown';
        if (!aborted) {
          try {
            before = await snapshot();
            expect(before['status'], 'noLayer');
            directory = await Directory.systemTemp.createTemp(
              'yl_video_metrics_',
            );
            final data = await rootBundle.load(
              'assets/test_media/benchmark_sdr.mkv',
            );
            final file = File('${directory.path}/owned.mkv');
            await file.writeAsBytes(
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            );
            player = await cleanup.create<YlPlayerController>(
              YlPlayerController.create(),
              timeout: const Duration(seconds: 10),
              release: (p) => p.dispose(),
            );
            await tester.pumpWidget(
              MaterialApp(home: YlPlayerView(controller: player)),
            );
            stage = 'load';
            final session = await player
                .load(YlFileSource(file.path, format: YlMediaFormat.matroska))
                .timeout(const Duration(seconds: 20));
            await session.play().timeout(const Duration(seconds: 5));
            await session.firstFrame.timeout(const Duration(seconds: 10));
            engine = player.state.engine.name;
            decoder = player.state.decoderMode.name;
            stage = 'playing';
            final deadline = clock.elapsedMilliseconds + 10000;
            // Never pause, seek or replace the session inside this counter window.
            while (clock.elapsedMilliseconds < deadline) {
              await tester.pump();
              series.observe(await snapshot(), clock.elapsedMicroseconds);
              expect(player.state.sessionId, session.id);
              expect(player.state.failure, isNull);
              if (series.complete &&
                  player.state.timeline.position >=
                      const Duration(seconds: 3)) {
                break;
              }
              await Future<void>.delayed(const Duration(milliseconds: 250));
            }
            expect(series.complete, isTrue);
            expect(
              player.state.timeline.position,
              greaterThanOrEqualTo(const Duration(seconds: 3)),
            );
            outcome = 'passed';
          } on TimeoutException {
            outcome = 'timeout';
          } catch (_) {
            outcome = 'failed';
          } finally {
            debugPrint(
              'YL_VIDEO_METRICS_OBSERVATION=${jsonEncode({'runId': runId, 'attempt': attempt, 'outcome': outcome, 'samples': series.observations})}',
              wrapWidth: 100000,
            );
            cleaned = await cleanup.run([
              () async {
                await player?.dispose();
              },
              () => tester.pumpWidget(const SizedBox.shrink()),
              () async {
                after = await snapshot();
                expect(after!['status'], 'noLayer');
              },
              () async {
                await directory?.delete(recursive: true);
              },
            ]);
            if (!cleaned && outcome != 'timeout') outcome = 'failed';
            if (outcome != 'passed') aborted = true;
          }
        }
        debugPrint(
          'YL_VIDEO_METRICS_ROW=${jsonEncode({'schemaVersion': 1, 'runId': runId, 'attempt': attempt, 'plannedAttempts': 3, 'buildMode': kProfileMode ? 'profile' : 'debug', 'measurement': 'continuous-renderer-counters', 'outcome': outcome, 'stage': stage, 'engine': engine, 'decoder': decoder, 'before': before, 'after': after, 'cleaned': cleaned, 'samples': series.observations, 'delta': series.delta, 'firstPresentedUs': null, 'physicalOutputVerified': false, 'performanceBaseline': false})}',
          wrapWidth: 100000,
        );
        outcomes.add(outcome);
      }
      expect(
        outcomes,
        everyElement('passed'),
        reason: 'All video performance outcomes retained',
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
