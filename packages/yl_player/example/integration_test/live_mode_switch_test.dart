import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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
      'profileId': const String.fromEnvironment('YL_LIVE_PROFILE'),
      'profileHash': const String.fromEnvironment('YL_LIVE_PROFILE_SHA256'),
    });
    YlPlayerController? player;
    LiveModeSeries? series;
    final clock = Stopwatch()..start();
    final commits = <Map<String, Object?>>[];
    var stage = 'create', outcome = 'failed', cleaned = false;
    String? sessionId;
    var rapidSwitchVerified = false, staleStopVerified = false;
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
      sessionId = session.id.value;
      series = LiveModeSeries(session.id);
      stage = 'first-frame';
      await session.play().timeout(const Duration(seconds: 10));
      await session.firstFrame.timeout(const Duration(seconds: 20));
      expect(owner.state.livePlayback?.mode, YlLivePlaybackMode.smoothPlayback);
      // Three 12-second windows cover the 25-second recovery boundary.
      Future<void> observe() async {
        final positions = <int>{};
        for (var i = 0; i < 48; i++) {
          final state = owner.state;
          expect(state.failure, isNull);
          expect(state.sessionId, session.id);
          series?.add(state, clock.elapsedMicroseconds, stage: stage);
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
        final startedUs = clock.elapsedMicroseconds;
        await session
            .setLivePlaybackMode(value)
            .timeout(const Duration(seconds: 20));
        expect(owner.state.sessionId, session.id);
        expect(owner.state.livePlayback?.mode, value);
        expect(owner.state.revision, greaterThan(before));
        commits.add({
          'mode': value.name,
          'startedUs': startedUs,
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
      series.add(owner.state, clock.elapsedMicroseconds, stage: stage);
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
      rapidSwitchVerified = true;
      stage = 'stop';
      await owner.stop().timeout(const Duration(seconds: 10));
      expect(owner.state.livePlayback, isNull);
      await expectLater(
        session.setLivePlaybackMode(YlLivePlaybackMode.lowLatency),
        throwsA(isA<YlPlayerException>()),
      );
      staleStopVerified = true;
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
        'YL_LIVE_RESULT=${jsonEncode({'schemaVersion': 2, 'sessionId': sessionId, 'sampleCount': series?.samples.length ?? 0, 'profileId': config['profileId'], 'profileHash': config['profileHash'], 'rapidSwitchVerified': rapidSwitchVerified, 'staleStopVerified': staleStopVerified, 'endToEndLatencyUs': null, 'runId': config['runId'], 'protocol': config['protocol'], 'declaredMediaHash': config['mediaHash'], 'platform': Platform.operatingSystem, 'buildMode': kReleaseMode
            ? 'release'
            : kProfileMode
            ? 'profile'
            : 'debug', 'outcome': outcome, 'stage': stage, 'cleaned': cleaned, 'commits': commits, 'endToEndLatency': 'unavailable', 'evidence': 'public-state-only'})}',
        wrapWidth: 100000,
      );
      // Preserve every sample and the result before the test process exits.
      await debugPrintDone.timeout(const Duration(seconds: 30));
    }
    expect(outcome, 'completed');
    expect(cleaned, isTrue);
  });
}
