import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/benchmark_trials.dart';
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
      final runClock = Stopwatch()..start();
      await runBenchmarkTrials(
        attempts: attempts,
        nowUs: () => runClock.elapsedMicroseconds,
        record: (row) {
          if (row['outcome'] != 'passed') failures.add(row['attempt'] as int);
          debugPrint(
            'YL_BENCHMARK_ROW=${jsonEncode({...context, ...row})}',
            wrapWidth: 100000,
          );
        },
        body: (trial) async {
          final player = await trial.create(
            YlPlayerController.create(),
            release: (player) => player.dispose(),
          );
          trial.cleanup.add(() => tester.pumpWidget(const SizedBox.shrink()));
          await tester
              .pumpWidget(MaterialApp(home: YlPlayerView(controller: player)))
              .timeout(const Duration(seconds: 10));
          final probe = trial.probe;
          final subscription = player.events.listen((event) {
            if (event is YlFirstFrameEvent) {
              probe.observe(event.sessionId.value);
            }
          });
          trial.cleanup.insert(0, subscription.cancel);
          probe.start(); // Immediately before public Load, never its Future.
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
          await player.states
              .firstWhere(
                (state) =>
                    state.sessionId == session.id &&
                    state.timeline.position > const Duration(milliseconds: 500),
              )
              .timeout(const Duration(seconds: 10));
        },
      );
      expect(
        failures,
        isEmpty,
        reason: 'All trial outcomes were retained in JSONL',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
