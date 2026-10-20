import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/live_mode_series.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'owned HLS resumes after its paused live window expires',
    (tester) async {
      final config = parseLiveModeConfig({
        'runId': const String.fromEnvironment('YL_LIVE_RUN'),
        'protocol': 'hls',
        'url': const String.fromEnvironment('P04_HLS'),
        'owned': 'true',
        'ownedHost': const String.fromEnvironment(
          'YL_LIVE_OWNED_HOST',
          defaultValue: '127.0.0.1',
        ),
        'mediaHash':
            'cfe009b1b03b6cacf4ae9f037eed4441a32b99508d4fabccb429bea439cf570b',
      });
      final player = await YlPlayerController.create();
      final label = ValueNotifier<String>('HLS 恢复回归');
      final clock = Stopwatch()..start();
      final lifecycle = AppLifecycleListener(
        onStateChange: (state) {
          debugPrintSynchronously('HLS_RESUME_LIFECYCLE=${state.name}');
        },
      );
      final samples = <Map<String, Object?>>[];
      var stage = 'load', completed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              child: Column(
                children: [
                  ValueListenableBuilder<String>(
                    valueListenable: label,
                    builder: (_, value, _) => Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        value,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                        ),
                      ),
                    ),
                  ),
                  Expanded(child: YlPlayerView(controller: player)),
                ],
              ),
            ),
          ),
        ),
      );
      void sample() {
        final state = player.state;
        expect(state.failure, isNull);
        samples.add({
          'elapsedUs': clock.elapsedMicroseconds,
          'stage': stage,
          'status': state.status.name,
          'positionUs':
              (state.metrics.mediaClockPosition ?? state.timeline.position)
                  .inMicroseconds,
          'reconnects': state.metrics.reconnectCount,
        });
      }

      Future<void> hold(String name, int seconds) async {
        stage = name;
        debugPrintSynchronously('HLS_RESUME_STAGE=$name');
        for (var remaining = seconds; remaining > 0; remaining--) {
          label.value = 'HLS · $name\n剩余 $remaining 秒';
          await Future<void>.delayed(const Duration(seconds: 1));
          sample();
        }
      }

      try {
        final session = await player
            .load(
              YlNetworkSource(
                Uri.parse(config['url']!),
                intent: YlStreamIntent.live,
                format: YlMediaFormat.hls,
              ),
            )
            .timeout(const Duration(seconds: 20));
        await session.ready.timeout(const Duration(seconds: 20));
        await player.setVolume(1);
        await session.play().timeout(const Duration(seconds: 10));
        await session.firstFrame.timeout(const Duration(seconds: 20));
        Future<void> pause() async {
          await session.pause().timeout(const Duration(seconds: 5));
          if (player.state.status != YlPlaybackStatus.paused) {
            await player.states
                .firstWhere(
                  (state) =>
                      state.sessionId == session.id &&
                      state.status == YlPlaybackStatus.paused,
                )
                .timeout(const Duration(seconds: 5));
          }
        }

        await hold('流畅播放', 15);
        await pause();
        await hold('第一次暂停', 5);
        await session
            .setLivePlaybackMode(YlLivePlaybackMode.lowLatency)
            .timeout(const Duration(seconds: 10));
        await session.play().timeout(const Duration(seconds: 10));
        await hold('低延迟播放', 15);
        for (var cycle = 0; cycle < 2; cycle++) {
          await pause();
          await hold('低延迟暂停 ${cycle + 1}', 5);
          stage = 'resume-${cycle + 1}';
          label.value = 'HLS · 正在恢复 ${cycle + 1}';
          final beforeReconnects = player.state.metrics.reconnectCount ?? 0;
          await session.play().timeout(const Duration(seconds: 10));
          // A new AVPlayer item resets its media epoch. Require consecutive
          // playing samples to advance; neither a seek nor an epoch reset passes.
          int? previous;
          var previousPlaying = false, advancementUs = 0;
          for (var tick = 0; tick < 40 && advancementUs < 500000; tick++) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
            sample();
            expect(player.state.sessionId, session.id);
            final position =
                (player.state.metrics.mediaClockPosition ??
                        player.state.timeline.position)
                    .inMicroseconds;
            final playing = player.state.status == YlPlaybackStatus.playing;
            if (!playing || previous == null || position < previous) {
              advancementUs = 0;
            } else if (previousPlaying) {
              advancementUs += position - previous;
            }
            previous = position;
            previousPlaying = playing;
          }
          // This guards proactive resume, before the 15s read-stall fallback.
          // It is not an end-to-end latency SLO.
          expect(
            advancementUs,
            greaterThanOrEqualTo(500000),
            reason: 'Expired HLS window must resume before read-stall recovery',
          );
          expect(
            player.state.livePlayback?.mode,
            YlLivePlaybackMode.lowLatency,
          );
          expect(
            player.state.metrics.reconnectCount ?? 0,
            greaterThan(beforeReconnects),
          );
          await hold('恢复成功 ${cycle + 1}：请观察音画', 10);
        }
        // The initial switch from smooth plus two expired-window resumes use
        // all three lifetime refresh attempts. Successful frames cannot reset it.
        expect(player.state.metrics.reconnectCount, 3);
        await pause();
        await hold('额度检查：保持暂停', 5);
        final heldPosition =
            player.state.metrics.mediaClockPosition ??
            player.state.timeline.position;
        await expectLater(
          session.play().timeout(const Duration(seconds: 5)),
          throwsA(
            isA<YlPlayerException>().having(
              (error) => error.failure.code,
              'code',
              'network.retry_exhausted',
            ),
          ),
        );
        await hold('额度耗尽：保持暂停', 2);
        expect(player.state.status, YlPlaybackStatus.paused);
        expect(player.state.metrics.reconnectCount, 3);
        expect(
          ((player.state.metrics.mediaClockPosition ??
                      player.state.timeline.position) -
                  heldPosition)
              .abs(),
          lessThan(const Duration(milliseconds: 500)),
        );
        await player.stop().timeout(const Duration(seconds: 5));
        completed = true;
      } finally {
        await player.dispose().timeout(const Duration(seconds: 5));
        runApp(const SizedBox.shrink());
        label.dispose();
        lifecycle.dispose();
        for (final record in samples) {
          debugPrintSynchronously('HLS_RESUME_SAMPLE=${jsonEncode(record)}');
        }
        debugPrintSynchronously(
          'HLS_RESUME_RESULT=${jsonEncode({'runId': config['runId'], 'completed': completed, 'stage': stage, 'physicalObservation': 'requires-user', 'endToEndLatencyUs': null})}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
