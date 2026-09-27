import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/first_frame_probe.dart';
import 'support/benchmark_reporting.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'owned local AVC first-frame measurement smoke',
    (tester) async {
      const raw = String.fromEnvironment('YL_BENCHMARK_CONTEXT');
      final actualMode = kReleaseMode
          ? 'release'
          : (kProfileMode ? 'profile' : 'debug');
      final context = parseBenchmarkContext(
        raw,
        platform: Platform.operatingSystem,
        buildMode: actualMode,
      );
      final attempts = context['plannedAttempts'] as int;
      final media = await rootBundle.load('assets/test_media/h264_aac.mkv');
      final directory = await Directory.systemTemp.createTemp('yl_benchmark_');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/sample.mkv');
      await file.writeAsBytes(
        media.buffer.asUint8List(media.offsetInBytes, media.lengthInBytes),
      );
      final failures = <int>[];
      var aborted = false;
      final runClock = Stopwatch()..start();
      void emitRow(Map<String, Object?> row) =>
          debugPrint('YL_BENCHMARK_ROW=${jsonEncode(row)}', wrapWidth: 100000);
      for (var attempt = 1; attempt <= attempts; attempt++) {
        if (aborted) {
          emitRow({
            ...context,
            'attempt': attempt,
            'outcome': 'skipped',
            'startedUs': runClock.elapsedMicroseconds,
            'firstPresentedUs': null,
            'firstFrameUs': null,
          });
          continue;
        }
        final player = await YlPlayerController.create();
        await tester.pumpWidget(
          MaterialApp(home: YlPlayerView(controller: player)),
        );
        final probe = FirstFrameProbe(
          nowUs: () => runClock.elapsedMicroseconds,
        );
        final subscription = player.events.listen((event) {
          if (event is YlFirstFrameEvent) probe.observe(event.sessionId.value);
        });
        var outcome = 'failed';
        probe
            .start(); // Immediately before public Load, never after its Future.
        try {
          final session = await player
              .load(YlFileSource(file.path, format: YlMediaFormat.matroska))
              .timeout(const Duration(seconds: 20));
          probe.bind(session.id.value);
          await session.play().timeout(const Duration(seconds: 10));
          await session.firstFrame.timeout(const Duration(seconds: 15));
          await tester.pump();
          expect(player.state.sessionId, session.id);
          expect(player.state.failure, isNull);
          expect(player.state.videoGeometry, isNotNull);
          expect(player.state.audioTracks, isNotEmpty);
          // A frame alone is not evidence of sustained playback correctness.
          await player.states
              .firstWhere(
                (state) =>
                    state.sessionId == session.id &&
                    state.timeline.position > const Duration(milliseconds: 500),
              )
              .timeout(const Duration(seconds: 10));
          outcome = 'passed';
        } on TimeoutException {
          outcome = 'timeout';
        } catch (_) {
          outcome =
              'failed'; // Never print exception strings, addresses or stacks.
        } finally {
          probe.close();
          final row = {
            ...context,
            'attempt': attempt,
            ...probe.fields(outcome),
          };
          final cleaned = await recordBenchmarkTrial(
            row: row,
            observe: (value) => debugPrint(
              'YL_BENCHMARK_OBSERVATION=${jsonEncode(value)}',
              wrapWidth: 100000,
            ),
            record: emitRow,
            cleanup: () async {
              await subscription.cancel();
              await player.dispose();
              await tester.pumpWidget(const SizedBox.shrink());
            },
          );
          if (!cleaned) {
            aborted = true;
            failures.add(attempt);
            debugPrint('YL_BENCHMARK_RUN_FAILED=cleanup');
          }
        }
        if (outcome != 'passed') failures.add(attempt);
      }
      expect(
        failures,
        isEmpty,
        reason: 'All trial outcomes were retained in JSONL',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
