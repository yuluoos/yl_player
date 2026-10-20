import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
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
    String? failureKind, commandFailureCode;
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
        int? previousPosition;
        var previousPlaying = false, advancing = false;
        // A declared five-second network stall may span a whole sample window.
        // Keep recording until progression returns, with a finite 20-second guard.
        for (var i = 0; i < 80; i++) {
          final state = owner.state;
          expect(state.failure, isNull);
          expect(state.sessionId, session.id);
          series?.add(state, clock.elapsedMicroseconds);
          final position =
              (state.metrics.mediaClockPosition ?? state.timeline.position)
                  .inMicroseconds;
          final playing = state.status == YlPlaybackStatus.playing;
          if (!playing ||
              (previousPosition != null && position < previousPosition)) {
            advancing = false;
          } else if (previousPlaying &&
              previousPosition != null &&
              position > previousPosition) {
            advancing = true;
          }
          previousPosition = position;
          previousPlaying = playing;
          await Future<void>.delayed(const Duration(milliseconds: 250));
          if (i >= 19 && advancing && playing) break;
        }
        expect(
          advancing && previousPlaying,
          isTrue,
          reason:
              'Public media clock must advance during playing; an epoch reset is not progression',
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
      stage = 'low-resume';
      final reconnectsBeforePause = owner.state.metrics.reconnectCount;
      await session.pause();
      final pausedPosition =
          owner.state.metrics.mediaClockPosition ??
          owner.state.timeline.position;
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(owner.state.status, YlPlaybackStatus.paused);
      expect(
        ((owner.state.metrics.mediaClockPosition ??
                    owner.state.timeline.position) -
                pausedPosition)
            .abs(),
        lessThan(const Duration(milliseconds: 500)),
      );
      await session.play();
      await observe();
      if ((Platform.isMacOS || Platform.isIOS) && config['protocol'] != 'hls') {
        expect(
          owner.state.metrics.reconnectCount,
          greaterThan(reconnectsBeforePause ?? 0),
          reason: 'Low-latency resume must retire the paused transport backlog',
        );
      }
      stage = 'same-mode';
      await mode(YlLivePlaybackMode.lowLatency);
      stage = 'smooth-again';
      await mode(YlLivePlaybackMode.smoothPlayback);
      await observe();
      stage = 'rapid';
      await Future.wait([
        session.setLivePlaybackMode(YlLivePlaybackMode.lowLatency),
        session.setLivePlaybackMode(YlLivePlaybackMode.smoothPlayback),
      ]).timeout(const Duration(seconds: 20));
      expect(owner.state.livePlayback?.mode, YlLivePlaybackMode.smoothPlayback);
      stage = 'replacement';
      final replacement = await owner
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
      await replacement.play();
      await replacement.firstFrame.timeout(const Duration(seconds: 20));
      expect(owner.state.sessionId, replacement.id);
      await expectLater(
        session.setLivePlaybackMode(YlLivePlaybackMode.lowLatency),
        throwsA(isA<YlPlayerException>()),
      );
      stage = 'stop';
      await owner.stop().timeout(const Duration(seconds: 10));
      // Stop ACK fences the session before its authoritative idle snapshot.
      // Keep the stale-command check immediate; do not assume channel ordering.
      await expectLater(
        replacement.setLivePlaybackMode(YlLivePlaybackMode.lowLatency),
        throwsA(isA<YlPlayerException>()),
      );
      if (owner.state.status != YlPlaybackStatus.idle) {
        await owner.states
            .firstWhere((state) => state.status == YlPlaybackStatus.idle)
            .timeout(const Duration(seconds: 5));
      }
      expect(owner.state.livePlayback, isNull);
      outcome = 'completed';
    } on TimeoutException {
      outcome = 'timeout';
    } catch (error) {
      outcome = 'failed';
      failureKind = error.runtimeType.toString();
      if (error is YlPlayerException) commandFailureCode = error.failure.code;
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
        'YL_LIVE_RESULT=${jsonEncode({'schemaVersion': 1, 'runId': config['runId'], 'protocol': config['protocol'], 'declaredMediaHash': config['mediaHash'], 'platform': Platform.operatingSystem, 'outcome': outcome, 'stage': stage, 'failureKind': failureKind, 'failureCode': commandFailureCode ?? player?.state.failure?.code, 'cleaned': cleaned, 'commits': commits, 'endToEndLatency': 'unavailable', 'evidence': 'public-state-only'})}',
        wrapWidth: 100000,
      );
      // Drain throttled evidence before the integration runner exits the app.
      await debugPrintDone;
    }
    expect(outcome, 'completed');
    expect(cleaned, isTrue);
  });
}
