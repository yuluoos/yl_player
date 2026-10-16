import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/live_mode_series.dart';
import 'support/resource_series.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('owned live smooth-low-smooth transaction capture', (
    tester,
  ) async {
    final config = parseLiveModeConfig({
      'runId': const String.fromEnvironment('YL_LIVE_RUN'),
      'protocol': const String.fromEnvironment('YL_LIVE_PROTOCOL'),
      'url': const String.fromEnvironment('YL_LIVE_URL'),
      'owned': const String.fromEnvironment('YL_LIVE_OWNED'),
      'mediaHash': const String.fromEnvironment('YL_LIVE_MEDIA_SHA256'),
    });
    YlPlayerController? player;
    LiveModeSeries? series;
    final clock = Stopwatch()..start();
    final commits = <Map<String, Object?>>[];
    var stage = 'create', outcome = 'failed', cleaned = false;
    try {
      final owner = await createResourceOwner<YlPlayerController>(
        YlPlayerController.create(),
        timeout: const Duration(seconds: 20),
        release: (value) => value.dispose(),
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
              intent: YlStreamIntent.live,
              format: config['protocol'] == 'hls'
                  ? YlMediaFormat.hls
                  : YlMediaFormat.flv,
            ),
          )
          .timeout(const Duration(seconds: 20));
      await session.ready.timeout(const Duration(seconds: 20));
      series = LiveModeSeries(session.id);
      stage = 'first-frame';
      await session.play().timeout(const Duration(seconds: 10));
      await session.firstFrame.timeout(const Duration(seconds: 20));
      expect(owner.state.livePlayback?.mode, YlLivePlaybackMode.smoothPlayback);
      Future<void> observe() async {
        final positions = <int>{};
        for (var i = 0; i < 20; i++) {
          final state = owner.state;
          expect(state.failure, isNull);
          expect(state.sessionId, session.id);
          series?.add(state, clock.elapsedMicroseconds);
          positions.add(
            (state.metrics.mediaClockPosition ?? state.timeline.position)
                .inMicroseconds,
          );
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        expect(
          positions.length,
          greaterThan(1),
          reason: 'Public media clock must advance',
        );
      }

      Future<void> mode(YlLivePlaybackMode value) async {
        final before = owner.state.revision;
        await session
            .setLivePlaybackMode(value)
            .timeout(const Duration(seconds: 20));
        expect(owner.state.sessionId, session.id);
        expect(owner.state.livePlayback?.mode, value);
        expect(owner.state.revision, greaterThan(before));
        commits.add({
          'mode': value.name,
          'elapsedUs': clock.elapsedMicroseconds,
          'revision': owner.state.revision,
        });
      }

      stage = 'smooth';
      await observe();
      stage = 'paused-low';
      await session.pause();
      await mode(YlLivePlaybackMode.lowLatency);
      expect(owner.state.status, YlPlaybackStatus.paused);
      stage = 'low';
      await session.play();
      await observe();
      stage = 'smooth-again';
      await mode(YlLivePlaybackMode.smoothPlayback);
      await observe();
      stage = 'rapid';
      await Future.wait([
        session.setLivePlaybackMode(YlLivePlaybackMode.lowLatency),
        session.setLivePlaybackMode(YlLivePlaybackMode.smoothPlayback),
      ]).timeout(const Duration(seconds: 20));
      expect(owner.state.livePlayback?.mode, YlLivePlaybackMode.smoothPlayback);
      stage = 'stop';
      await owner.stop().timeout(const Duration(seconds: 10));
      expect(owner.state.livePlayback, isNull);
      await expectLater(
        session.setLivePlaybackMode(YlLivePlaybackMode.lowLatency),
        throwsA(isA<YlPlayerException>()),
      );
      outcome = 'completed';
    } on TimeoutException {
      outcome = 'timeout';
    } catch (_) {
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
          'YL_LIVE_SAMPLE=${jsonEncode({'runId': config['runId'], ...sample})}',
          wrapWidth: 100000,
        );
      }
      debugPrint(
        'YL_LIVE_RESULT=${jsonEncode({'schemaVersion': 1, 'runId': config['runId'], 'protocol': config['protocol'], 'declaredMediaHash': config['mediaHash'], 'platform': Platform.operatingSystem, 'outcome': outcome, 'stage': stage, 'cleaned': cleaned, 'commits': commits, 'endToEndLatency': 'unavailable', 'evidence': 'public-state-only'})}',
        wrapWidth: 100000,
      );
    }
    expect(outcome, 'completed');
    expect(cleaned, isTrue);
  });
}
