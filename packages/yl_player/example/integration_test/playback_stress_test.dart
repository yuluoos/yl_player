import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/benchmark_reporting.dart';
import 'support/benchmark_trials.dart';
import 'support/resource_series.dart';
import 'support/seek_progress_window.dart';

/// Public command/lifecycle observations, deliberately not output timestamps.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'two-player ownership seek resume replacement and release protocol',
    (tester) async {
      final context = parseBenchmarkContext(
        const String.fromEnvironment('YL_BENCHMARK_CONTEXT'),
        platform: Platform.operatingSystem,
        buildMode: kReleaseMode
            ? 'release'
            : kProfileMode
            ? 'profile'
            : 'debug',
      );
      const protocolHash = String.fromEnvironment('YL_STRESS_PROTOCOL_HASH');
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(protocolHash)) {
        throw const FormatException('Invalid stress protocol identity');
      }
      final asset = await rootBundle.load(
        'assets/test_media/network_seek_h264_aac.mkv',
      );
      final bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      if (sha256.convert(bytes).toString() != context['mediaHash']) {
        throw const FormatException('Stress media identity mismatch');
      }
      final directory = await Directory.systemTemp.createTemp('yl_stress_');
      addTearDown(() => directory.delete(recursive: true));
      final media = File('${directory.path}/owned.mkv');
      await media.writeAsBytes(bytes);
      const samplerPayload = String.fromEnvironment(
        'YL_RESOURCE_LIBRARY_BYTES',
      );
      final samplerFile = File('${directory.path}/resources.dylib');
      await samplerFile.writeAsBytes(base64Decode(samplerPayload));
      final readResources = openResourceSampler(samplerFile.path);
      ResourceSeries? resources;
      var resourceFailed = false;
      final resourceTrials = <Map<String, Object?>>[];
      final clock = Stopwatch()..start();
      final trials = <Map<String, Object?>>[];
      const metrics = {
        'loadUs': {'unit': 'us', 'boundary': 'public-event'},
        'seekNearStateUs': {'unit': 'us', 'boundary': 'public-state'},
        'seekStableStateUs': {'unit': 'us', 'boundary': 'public-state'},
        'loadReadyUs': {'unit': 'us', 'boundary': 'public-event'},
        'seekCommandUs': {'unit': 'us', 'boundary': 'command-completed'},
        'resumeCommandUs': {'unit': 'us', 'boundary': 'command-completed'},
        'replacementUs': {'unit': 'us', 'boundary': 'public-event'},
        'rebufferUs': {'unit': 'us', 'boundary': 'buffering-state'},
        'rebufferCount': {'unit': 'count', 'boundary': 'buffering-state'},
        'mediaPeakBytes': {'unit': 'bytes', 'boundary': 'media-ledger'},
      };
      var values = <String, Object?>{};
      var attemptStart = 0;
      await runBenchmarkTrials(
        attempts: context['plannedAttempts'] as int,
        nowUs: () => clock.elapsedMicroseconds,
        body: (trial) async {
          attemptStart = clock.elapsedMicroseconds;
          values = {for (final key in metrics.keys) key: null};
          resourceFailed = false;
          final series = resources = ResourceSeries(read: readResources)
            ..enter('idle');
          final resourceTimer = startResourceSampling(
            series: series,
            cleanup: trial.cleanup,
            onFailure: () => resourceFailed = true,
          );
          // Even setup errors own and stop their sampler; each later phase is
          // sampled from this process, never a host timestamp subtraction.
          trial.cleanup.add(() async {
            series.enter('disposing');
          });
          try {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            series.enter('opening');
            debugPrint('YL_STRESS_STAGE=create');
            final players = <YlPlayerController>[];
            for (var i = 0; i < 2; i++) {
              final player = await trial.create(
                YlPlayerController.create(
                  options: const YlPlayerOptions(
                    audioPolicy: YlAudioPolicy.appManaged,
                  ),
                ),
                release: (player) => player.dispose(),
              );
              players.add(player);
              await player.setVolume(0).timeout(const Duration(seconds: 5));
            }
            trial.cleanup.add(() => tester.pumpWidget(const SizedBox.shrink()));
            await tester
                .pumpWidget(
                  MaterialApp(
                    home: Row(
                      children: [
                        for (final player in players)
                          Expanded(child: YlPlayerView(controller: player)),
                      ],
                    ),
                  ),
                )
                .timeout(const Duration(seconds: 10));
            final subscription = players.first.events.listen((event) {
              if (event is YlFirstFrameEvent) {
                trial.probe.observe(event.sessionId.value);
              }
            });
            trial.cleanup.insert(0, subscription.cancel);
            debugPrint('YL_STRESS_STAGE=load');
            final sessions = <YlPlaybackSession>[];
            trial.probe.start();
            for (final player in players) {
              final session = await player
                  .load(
                    YlFileSource(media.path, format: YlMediaFormat.matroska),
                  )
                  .timeout(const Duration(seconds: 20));
              if (sessions.isEmpty) trial.probe.bind(session.id.value);
              sessions.add(session);
              await session.play().timeout(const Duration(seconds: 5));
              await session.firstFrame.timeout(const Duration(seconds: 15));
              await stateWhere(
                player,
                (s) => s.timeline.position > const Duration(milliseconds: 300),
              );
            }
            values['loadUs'] = trial.probe.fields('passed')['firstFrameUs'];
            values['loadReadyUs'] =
                players.first.state.metrics.loadToReady?.inMicroseconds;
            series.enter('playing');
            int? peak;
            void sample() {
              final counters = players
                  .map((p) => p.state.metrics.managedBufferedBytes)
                  .toList();
              if (counters.every((n) => n != null)) {
                final sum = counters.fold<int>(0, (total, n) => total + n!);
                if (peak == null || sum > peak!) peak = sum;
              }
            }

            sample();
            final timer = Timer.periodic(
              const Duration(milliseconds: 100),
              (_) => sample(),
            );
            trial.cleanup.insert(0, () async => timer.cancel());
            debugPrint('YL_STRESS_STAGE=pause');
            await sessions.first.pause().timeout(const Duration(seconds: 5));
            debugPrint('YL_STRESS_STAGE=seek');
            final seekStart = clock.elapsedMicroseconds;
            final seekWindow = SeekProgressWindow(
              session: sessions.first.id.value,
              startedUs: seekStart,
              targetUs: 5000000,
            );
            await sessions.first
                .seekTo(const Duration(seconds: 5))
                .timeout(const Duration(seconds: 15));
            values['seekCommandUs'] = clock.elapsedMicroseconds - seekStart;
            await stateWhere(
              players.first,
              (s) =>
                  (s.timeline.position - const Duration(seconds: 5)).abs() <=
                  const Duration(milliseconds: 250),
            );
            seekWindow.observe(
              sessionId: players.first.state.sessionId?.value,
              nowUs: clock.elapsedMicroseconds,
              positionUs: players.first.state.timeline.position.inMicroseconds,
              playing: false,
              buffering: false,
            );
            final resumeStart = clock.elapsedMicroseconds;
            await sessions.first.play().timeout(const Duration(seconds: 5));
            values['resumeCommandUs'] = clock.elapsedMicroseconds - resumeStart;
            while (seekWindow.stableUs == null &&
                !seekWindow.cancelled &&
                clock.elapsedMicroseconds - seekStart < 10000000) {
              final state = players.first.state;
              seekWindow.observe(
                sessionId: state.sessionId?.value,
                nowUs: clock.elapsedMicroseconds,
                positionUs: state.timeline.position.inMicroseconds,
                playing: state.status == YlPlaybackStatus.playing,
                buffering: state.status == YlPlaybackStatus.buffering,
              );
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            values['seekNearStateUs'] = seekWindow.firstNearUs == null
                ? null
                : seekWindow.firstNearUs! - seekStart;
            values['seekStableStateUs'] = seekWindow.stableUs == null
                ? null
                : seekWindow.stableUs! - seekStart;
            if (seekWindow.stableUs == null) {
              throw TimeoutException('Seek state window not observed');
            }
            expect(players.last.state.failure, isNull);
            debugPrint('YL_STRESS_STAGE=replace');
            final replacementStart = clock.elapsedMicroseconds;
            final replacement = await players.first
                .load(YlFileSource(media.path, format: YlMediaFormat.matroska))
                .timeout(const Duration(seconds: 20));
            await replacement.play().timeout(const Duration(seconds: 5));
            await replacement.firstFrame.timeout(const Duration(seconds: 15));
            values['replacementUs'] =
                clock.elapsedMicroseconds - replacementStart;
            await expectLater(
              sessions.first.play(),
              throwsA(isA<YlPlayerException>()),
            );
            // Apple commits deactivate peer video leases. Explicit Play restores
            // the peer after releasing the active instance; no concurrent claim.
            debugPrint('YL_STRESS_STAGE=peer-stop');
            void peerSnapshot(String phase) {
              final state = players.last.state;
              debugPrint(
                'YL_STRESS_PEER=${jsonEncode({'phase': phase, 'status': state.status.name, 'positionUs': state.timeline.position.inMicroseconds, 'durationUs': state.timeline.duration?.inMicroseconds, 'clockUs': state.metrics.mediaClockPosition?.inMicroseconds, 'failureCode': state.failure?.code})}',
              );
            }

            peerSnapshot('before-stop');
            final peerPosition = players.last.state.timeline.position;
            await players.first.stop().timeout(const Duration(seconds: 5));
            await sessions.last.play().timeout(const Duration(seconds: 5));
            try {
              await stateWhere(
                players.last,
                (s) => s.timeline.position > peerPosition,
              );
            } finally {
              peerSnapshot('after-observation');
            }
            final peerMetrics = players.last.state.metrics;
            values['rebufferUs'] = peerMetrics.rebufferDuration?.inMicroseconds;
            values['rebufferCount'] = peerMetrics.rebufferCount;
            values['mediaPeakBytes'] = peak;
            await players.last.stop().timeout(const Duration(seconds: 5));
          } finally {
            trial.cleanup.add(() async {
              resourceTimer.cancel();
              try {
                series.enter('disposed');
                await Future<void>.delayed(const Duration(milliseconds: 500));
                series.sample();
              } finally {
                series.close();
              }
              if (resourceFailed) {
                throw const FormatException('Resource observations incomplete');
              }
            });
          }
        },
        record: (row) {
          final skipped = row['outcome'] == 'skipped';
          final result = <String, Object?>{
            'attempt': row['attempt'], 'outcome': row['outcome'],
            // The ownership runner downgrades successful observations on cleanup
            // failure; failed trials never satisfy a performance sample gate.
            'cleanup': row['outcome'] == 'passed' ? 'passed' : 'unknown',
            'startedUs': skipped ? clock.elapsedMicroseconds : attemptStart,
            'endedUs': clock.elapsedMicroseconds,
            'values': skipped
                ? {for (final key in metrics.keys) key: null}
                : values,
          };
          trials.add(result);
          resourceTrials.add({
            'schemaVersion': 1,
            'runId': context['runId'],
            'attempt': row['attempt'],
            'plannedAttempts': context['plannedAttempts'],
            'pid': pid,
            'buildMode': context['buildMode'],
            'intervalMs': 250,
            'engine': 'unknown',
            'decoder': 'unknown',
            'outcome': row['outcome'],
            'samples': skipped
                ? <Object?>[]
                : resources?.observations ?? <Object?>[],
          });
          debugPrint(
            'YL_STRESS_TRIAL=${jsonEncode(result)}',
            wrapWidth: 100000,
          );
        },
      );
      final run = {
        'schemaVersion': 1,
        for (final key in [
          'runId',
          'commit',
          'sourceHash',
          'dependencyHash',
          'artifactHash',
          'baselineComparable',
          'plannedAttempts',
        ])
          key: context[key],
        'warmupAttempts': 0,
        'conditions': {
          for (final key in [
            'platform',
            'device',
            'os',
            'architecture',
            'deviceKind',
            'buildMode',
            'power',
            'thermal',
            'output',
            'mediaHash',
            'networkProfile',
            'cacheState',
          ])
            key: context[key],
          'caseId': 'two-player-seek-resume',
          'protocolHash': protocolHash,
        },
        'qualification': {'contentVerified': false, 'evidenceHash': null},
        'metrics': metrics,
        'trials': trials,
      };
      debugPrint(
        'YL_STRESS_RESOURCES=${jsonEncode(resourceTrials)}',
        wrapWidth: 100000,
      );
      debugPrint('YL_PERFORMANCE_RUN=${jsonEncode(run)}', wrapWidth: 100000);
      expect(
        trials.every((trial) => trial['outcome'] == 'passed'),
        isTrue,
        reason: 'All attempted and skipped trials retained',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
