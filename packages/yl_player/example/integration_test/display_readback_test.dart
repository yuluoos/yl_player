import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/display_markers.dart';
import 'support/resource_series.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('yl_player_example/display_readback');
  Future<Map<String, Object?>> snapshot() async => (await channel
      .invokeMapMethod<String, Object?>('snapshot')
      .timeout(const Duration(seconds: 3)))!;
  testWidgets(
    'owned paused display-layer markers',
    (tester) async {
      if (!Platform.isMacOS || !kDebugMode) {
        throw StateError('macOS Debug probe required');
      }
      const runId = String.fromEnvironment('YL_DISPLAY_RUN_ID');
      if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$').hasMatch(runId)) {
        throw const FormatException('Display run identity required');
      }
      final clock = Stopwatch()..start();
      var aborted = false;
      final outcomes = <String>[];
      for (var attempt = 1; attempt <= 3; attempt++) {
        YlPlayerController? player;
        Directory? directory;
        DisplayMarkers? markers;
        var outcome = aborted ? 'skipped' : 'failed';
        var stage = 'setup';
        var cleaned = false;
        String engine = 'unknown', decoder = 'unknown';
        Map<String, Object?>? before, after;
        if (!aborted) {
          try {
            before = await snapshot();
            expect(before['status'], 'noLayer');
            directory = await Directory.systemTemp.createTemp('yl_display_');
            final asset = await rootBundle.load(
              'assets/test_media/benchmark_sdr.mkv',
            );
            final file = File('${directory.path}/owned.mkv');
            await file.writeAsBytes(
              asset.buffer.asUint8List(
                asset.offsetInBytes,
                asset.lengthInBytes,
              ),
            );
            player = await createResourceOwner<YlPlayerController>(
              YlPlayerController.create(),
              timeout: const Duration(seconds: 10),
              release: (p) => p.dispose(),
            );
            await tester.pumpWidget(
              MaterialApp(home: YlPlayerView(controller: player)),
            );
            markers = DisplayMarkers(startedUs: clock.elapsedMicroseconds);
            stage = 'load';
            final session = await player
                .load(YlFileSource(file.path, format: YlMediaFormat.matroska))
                .timeout(const Duration(seconds: 20));
            await session.play().timeout(const Duration(seconds: 5));
            await session.firstFrame.timeout(const Duration(seconds: 10));
            engine = player.state.engine.name;
            decoder = player.state.decoderMode.name;
            for (var index = 0; index < 4; index++) {
              stage = 'marker-$index';
              await stateWhere(
                player,
                (s) =>
                    s.timeline.position >=
                    Duration(milliseconds: index * 1000 + 250),
              );
              await session.pause().timeout(const Duration(seconds: 5));
              final deadline = clock.elapsedMilliseconds + 1500;
              while (markers.markersSeen <= index &&
                  clock.elapsedMilliseconds < deadline) {
                await tester.pump();
                markers.observe(await snapshot(), clock.elapsedMicroseconds);
                if (markers.markersSeen <= index) {
                  await Future<void>.delayed(const Duration(milliseconds: 50));
                }
              }
              expect(markers.markersSeen, index + 1);
              expect(player.state.failure, isNull);
              if (index < 3) {
                await session.play().timeout(const Duration(seconds: 5));
              }
            }
            expect(markers.complete, isTrue);
            outcome = 'passed';
          } on TimeoutException {
            outcome = 'timeout';
          } catch (_) {
            outcome = 'failed';
          } finally {
            // Retain all known readbacks even if native disposal stalls.
            debugPrint(
              'YL_DISPLAY_OBSERVATION=${jsonEncode({'runId': runId, 'attempt': attempt, 'stage': stage, 'outcome': outcome, 'samples': markers?.observations ?? []})}',
              wrapWidth: 100000,
            );
            try {
              await player?.dispose().timeout(const Duration(seconds: 5));
              await tester.pumpWidget(const SizedBox.shrink());
              after = await snapshot();
              expect(after['status'], 'noLayer');
              await directory
                  ?.delete(recursive: true)
                  .timeout(const Duration(seconds: 5));
              cleaned = true;
            } catch (_) {
              if (outcome != 'timeout') outcome = 'failed';
            }
            if (!cleaned || outcome != 'passed') aborted = true;
          }
        }
        debugPrint(
          'YL_DISPLAY_ROW=${jsonEncode({'schemaVersion': 1, 'runId': runId, 'attempt': attempt, 'plannedAttempts': 3, 'buildMode': 'debug', 'measurement': 'paused-display-layer-readback', 'outcome': outcome, 'stage': stage, 'engine': engine, 'decoder': decoder, 'startedUs': markers?.startedUs, 'firstReadbackUs': markers?.firstReadbackUs, 'firstReadbackDelayUs': markers?.firstReadbackDelayUs, 'markersComplete': markers?.complete ?? false, 'before': before, 'after': after, 'cleaned': cleaned, 'samples': markers?.observations ?? [], 'physicalOutputVerified': false, 'performanceBaseline': false})}',
          wrapWidth: 100000,
        );
        outcomes.add(outcome);
      }
      expect(
        outcomes,
        everyElement('passed'),
        reason: 'All display trial outcomes retained',
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
