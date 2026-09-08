import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/range_media_server.dart';
import 'support/android_test_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android progressive Ready, immediate Play, frame, seek and reload',
    (tester) async {
      final server = await RangeMediaServer.start(
        asset: 'assets/test_media/network_seek_h264_aac.mkv',
      );
      addTearDown(server.close);
      final player = await YlPlayerController.create(
        options: const YlPlayerOptions(
          audioPolicy: YlAudioPolicy.pluginManagedMediaPlayback,
        ),
      );
      addTearDown(player.dispose);
      expect(
        player.capabilities.availableEngines,
        contains(YlPlaybackEngine.media3),
      );
      await tester.pumpWidget(
        MaterialApp(home: YlPlayerView(controller: player)),
      );
      final source = YlNetworkSource(
        server.mediaUri,
        format: YlMediaFormat.matroska,
      );
      final session = await player
          .load(source)
          .timeout(const Duration(seconds: 30));
      await session.play();
      await session.ready.timeout(const Duration(seconds: 15));
      await session.firstFrame.timeout(const Duration(seconds: 15));
      expect(player.state.engine, YlPlaybackEngine.media3);
      expect(player.state.videoGeometry, isNotNull);
      expect(player.state.audioTracks, isNotEmpty);
      await session.pause();
      const seekTarget = Duration(seconds: 4);
      await session.seekTo(seekTarget);
      await waitForState(
        player,
        (state) =>
            (state.timeline.position - seekTarget).inMilliseconds.abs() <=
                250 &&
            (state.status == YlPlaybackStatus.paused ||
                state.status == YlPlaybackStatus.ready),
      );
      final pausedSeekPosition = player.state.timeline.position;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(player.state.sessionId, session.id);
      expect(player.state.status, isNot(YlPlaybackStatus.playing));
      expect(
        (player.state.timeline.position - pausedSeekPosition).inMilliseconds
            .abs(),
        lessThanOrEqualTo(100),
        reason: 'The resulting seek position stays stable while paused',
      );
      await session.play();
      await waitForState(
        player,
        (state) =>
            state.status == YlPlaybackStatus.playing &&
            state.timeline.position >
                seekTarget + const Duration(milliseconds: 500),
      );
      await player.stop();
      await expectLater(
        session.play(),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.sessionStale,
          ),
        ),
      );
      final reloaded = await player.load(source);
      expect(reloaded.id, isNot(session.id));
      await reloaded.play();
      await reloaded.firstFrame.timeout(const Duration(seconds: 15));
    },
  );
  testWidgets(
    'Audio-only strict Ready is independent of First Frame and native background suspends',
    (tester) async {
      final server = await RangeMediaServer.start(
        asset: 'assets/test_media/android_audio_only.m4a',
      );
      addTearDown(server.close);
      final player = await YlPlayerController.create(
        options: const YlPlayerOptions(
          decoderPolicy: YlDecoderPolicy.hardwareRequired,
          audioPolicy: YlAudioPolicy.pluginManagedMediaPlayback,
        ),
      );
      addTearDown(player.dispose);
      await tester.pumpWidget(
        MaterialApp(home: YlPlayerView(controller: player)),
      );
      final frames = <YlFirstFrameEvent>[];
      final sub = player.events
          .where((e) => e is YlFirstFrameEvent)
          .cast<YlFirstFrameEvent>()
          .listen(frames.add);
      addTearDown(sub.cancel);
      final session = await player.load(
        YlNetworkSource(server.mediaUri, format: YlMediaFormat.mp4),
      );
      await session.play();
      await session.ready.timeout(const Duration(seconds: 20));
      await waitForState(
        player,
        (s) => s.timeline.position > const Duration(milliseconds: 300),
      );
      expect(player.state.audioTracks, isNotEmpty);
      expect(player.state.videoTracks, isEmpty);
      expect(frames, isEmpty);
      debugPrint('YL_ANDROID_LIFECYCLE_BACKGROUND_READY');
      await waitForState(player, (s) => s.status == YlPlaybackStatus.paused);
      final pausedPosition = player.state.timeline.position;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(player.state.status, YlPlaybackStatus.paused);
      expect(player.state.timeline.position, pausedPosition);
      debugPrint('YL_ANDROID_LIFECYCLE_FOREGROUND_READY');
      await waitForState(
        player,
        (s) =>
            s.status == YlPlaybackStatus.playing &&
            s.timeline.position > pausedPosition,
      );
      expect(frames, isEmpty);
    },
  );

  if (const int.fromEnvironment('YL_ANDROID_API') == 24) {
    testWidgets(
      'API24 strict video rejects name-only hardware evidence before public commit',
      (tester) async {
        final server = await RangeMediaServer.start(
          asset: 'assets/test_media/h264_aac.mkv',
        );
        addTearDown(server.close);
        final player = await YlPlayerController.create(
          options: const YlPlayerOptions(
            decoderPolicy: YlDecoderPolicy.hardwareRequired,
          ),
        );
        addTearDown(player.dispose);
        final frames = <YlFirstFrameEvent>[];
        final sub = player.events
            .where((e) => e is YlFirstFrameEvent)
            .cast<YlFirstFrameEvent>()
            .listen(frames.add);
        addTearDown(sub.cancel);
        await expectLater(
          player.load(
            YlNetworkSource(server.mediaUri, format: YlMediaFormat.matroska),
          ),
          throwsA(failureCode(YlFailureCodes.decoderUnavailable)),
        );
        expect(player.state.sessionId, isNull);
        expect(frames, isEmpty);
      },
    );
  }
}
