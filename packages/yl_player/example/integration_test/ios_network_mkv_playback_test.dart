import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/playback_sessions.dart';

import 'support/range_media_server.dart';
import 'support/authenticated_hls_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> openNetworkMkv(
    YlPlayerController controller,
    RangeMediaServer server, {
    YlLoadOptions options = const YlLoadOptions(),
  }) => loadSession(
    controller,
    YlNetworkSource(
      server.mediaUri,
      format: YlMediaFormat.matroska,
      request: YlHttpRequest(headers: const {'X-Yl-Test': 'network-mkv'}),
    ),
    options: options,
  );

  testWidgets('HTTP range MKV uses the native fallback', (
    WidgetTester tester,
  ) async {
    final server = await RangeMediaServer.start(
      asset: 'assets/test_media/network_seek_h264_aac.mkv',
    );
    addTearDown(server.close);
    final controller = await YlPlayerController.create();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: controller)),
    );

    await openNetworkMkv(
      controller,
      server,
      options: const YlLoadOptions(
        bufferStrategy: YlBufferStrategy.lowLatency(),
      ),
    );
    expect(server.requests, isNotEmpty);
    expect(server.requests.first.header('x-yl-test'), 'network-mkv');
    expect(server.requests.first.statusCode, 206);

    final firstFrame = controller.events
        .firstWhere((event) => event is YlFirstFrameEvent)
        .timeout(const Duration(seconds: 15));
    await sessionFor(controller).play();
    await sessionFor(controller).ready.timeout(const Duration(seconds: 20));
    await firstFrame;
    expect(controller.state.engine, YlPlaybackEngine.managedFallback);
    expect(controller.state.decoderIdentity, 'VideoToolbox');
    debugPrint(
      'TASK8_DEFAULT_NETWORK_MKV_DECODER=${controller.state.decoderMode.name}',
    );
    expect(controller.state.timeline.isSeekable, isTrue);

    await sessionFor(controller).pause();
    final requestCountBeforeSeek = server.requests.length;
    await sessionFor(controller).seekTo(const Duration(seconds: 16));
    final seeked = await controller.states
        .firstWhere(
          (state) =>
              state.timeline.position >= const Duration(milliseconds: 15500),
        )
        .timeout(const Duration(seconds: 10));
    expect(seeked.engine, YlPlaybackEngine.managedFallback);
    final seekRequests = server.requests.skip(requestCountBeforeSeek).toList();
    expect(seekRequests, isNotEmpty);
    expect(
      seekRequests.any(
        (request) => RegExp(
          r'^bytes=[1-9]\d*-$',
        ).hasMatch(request.header('range') ?? ''),
      ),
      isTrue,
    );
    expect(seekRequests.every((request) => request.statusCode == 206), isTrue);

    expect(controller.state.audioTracks, hasLength(2));
    final session = sessionFor(controller);
    final secondTrack = controller.state.audioTracks[1];
    await session.selectAudioTrack(secondTrack.id);
    final selectedState =
        controller.state.sessionId == session.id &&
            controller.state.audioTracks.any(
              (track) => track.id == secondTrack.id && track.isSelected,
            )
        ? controller.state
        : await controller.states
              .firstWhere(
                (state) =>
                    state.sessionId == session.id &&
                    state.audioTracks.length == 2 &&
                    state.audioTracks.any(
                      (track) => track.id == secondTrack.id && track.isSelected,
                    ),
              )
              .timeout(const Duration(seconds: 5));
    expect(selectedState.audioTracks, hasLength(2));
    expect(
      selectedState.audioTracks
          .singleWhere((track) => track.id == secondTrack.id)
          .isSelected,
      isTrue,
    );
  });

  testWidgets(
    'HTTP range MKV restores real-time playback after sustained 3x',
    (WidgetTester tester) async {
      // Synthetic 65s/60fps H264 video and 44.1kHz stereo AAC exercise sustained
      // audio/video backpressure without requiring a large or licensed movie.
      final server = await RangeMediaServer.start(
        asset: 'assets/test_media/long_60fps_h264_aac.mkv',
      );
      addTearDown(server.close);
      final controller = await YlPlayerController.create();
      addTearDown(controller.dispose);
      final failures = <YlPlayerState>[];
      final subscription = controller.states.listen((state) {
        if (state.status == YlPlaybackStatus.failed || state.failure != null) {
          failures.add(state);
        }
      });
      addTearDown(subscription.cancel);
      await tester.pumpWidget(
        MaterialApp(home: YlPlayerView(controller: controller)),
      );
      await openNetworkMkv(controller, server);
      final session = sessionFor(controller);
      await session.setPlaybackSpeed(1);
      await session.play();
      await session.ready.timeout(const Duration(seconds: 20));
      await session.firstFrame.timeout(const Duration(seconds: 15));
      if (controller.state.timeline.position < const Duration(seconds: 1)) {
        await controller.states
            .firstWhere(
              (state) => state.timeline.position >= const Duration(seconds: 1),
            )
            .timeout(const Duration(seconds: 10));
      }
      expect(controller.state.engine, YlPlaybackEngine.managedFallback);
      expect(controller.state.audioTracks, isNotEmpty);

      Future<double> measureRate(Duration interval) async {
        final start = controller.state.timeline.position;
        final clock = Stopwatch()..start();
        await Future<void>.delayed(interval);
        clock.stop();
        final state = controller.state;
        expect(state.failure, isNull);
        expect(state.status, YlPlaybackStatus.playing);
        expect(failures, isEmpty, reason: 'No transient playback failure');
        return (state.timeline.position - start).inMicroseconds /
            clock.elapsedMicroseconds;
      }

      Future<void> setSpeedAndWaitForFreshPosition(double speed) async {
        await session.setPlaybackSpeed(speed);
        // Command completion does not publish a timeline sample. Wait for a
        // fresh playing position before comparing media time with wall time.
        final previousPosition = controller.state.timeline.position;
        await controller.states
            .firstWhere(
              (state) =>
                  state.sessionId == session.id &&
                  state.status == YlPlaybackStatus.playing &&
                  state.timeline.position > previousPosition,
            )
            .timeout(const Duration(seconds: 1));
      }

      await setSpeedAndWaitForFreshPosition(3);
      final acceleratedRate = await measureRate(const Duration(seconds: 10));
      expect(
        acceleratedRate,
        inInclusiveRange(2.4, 3.6),
        reason: 'The test must sustain actual 3x before exercising recovery',
      );

      await setSpeedAndWaitForFreshPosition(1);
      // Check successive windows as well as the overall rate: a burst followed
      // by an audio stall must not look like a successful return to real time.
      final restoredStart = controller.state.timeline.position;
      final restoredClock = Stopwatch()..start();
      for (var window = 0; window < 3; window++) {
        final restoredRate = await measureRate(
          const Duration(milliseconds: 1500),
        );
        expect(
          restoredRate,
          inInclusiveRange(0.65, 1.35),
          reason: 'Recovery window $window must progress at 1x',
        );
      }
      restoredClock.stop();
      final overallRate =
          (controller.state.timeline.position - restoredStart).inMicroseconds /
          restoredClock.elapsedMicroseconds;
      expect(overallRate, inInclusiveRange(0.75, 1.25));
      expect(controller.state.sessionId, session.id);
      expect(failures, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'HTTP range MKV completes a long video tail after audio ends',
    (WidgetTester tester) async {
      // 720 video packets cover 12s at 60fps; stereo AAC ends at 1.023s.
      // The remaining video exceeds the 256-packet queue, so demux cannot reach
      // EOF if the audio-backed clock freezes when its last buffer completes.
      final server = await RangeMediaServer.start(
        asset: 'assets/test_media/video_tail_60fps_h264_aac.mkv',
      );
      addTearDown(server.close);
      final controller = await YlPlayerController.create();
      addTearDown(controller.dispose);
      final failures = <YlPlayerState>[];
      final subscription = controller.states.listen((state) {
        if (state.status == YlPlaybackStatus.failed || state.failure != null) {
          failures.add(state);
        }
      });
      addTearDown(subscription.cancel);
      await tester.pumpWidget(
        MaterialApp(home: YlPlayerView(controller: controller)),
      );
      await openNetworkMkv(controller, server);
      final session = sessionFor(controller);
      final completed = await (() async {
        await session.play();
        await session.ready;
        await session.firstFrame;
        if (controller.state.status == YlPlaybackStatus.completed) {
          return controller.state;
        }
        return controller.states.firstWhere(
          (state) =>
              state.sessionId == session.id &&
              (state.status == YlPlaybackStatus.completed ||
                  state.status == YlPlaybackStatus.failed ||
                  state.failure != null),
        );
      })().timeout(const Duration(seconds: 25));
      expect(completed.engine, YlPlaybackEngine.managedFallback);
      expect(completed.status, YlPlaybackStatus.completed);
      expect(completed.failure, isNull);
      expect(failures, isEmpty);
      expect(completed.audioTracks, isNotEmpty);
      expect(
        completed.timeline.position,
        greaterThanOrEqualTo(const Duration(milliseconds: 11800)),
        reason: 'Playback must reach the video tail, not end with the audio',
      );
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  testWidgets('HTTP 200 sequential MKV rejects seek without losing playback', (
    WidgetTester tester,
  ) async {
    final server = await RangeMediaServer.start(
      asset: 'assets/test_media/h264_aac.mkv',
      supportsRanges: false,
    );
    addTearDown(server.close);
    final controller = await YlPlayerController.create();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: controller)),
    );

    await openNetworkMkv(controller, server);
    expect(server.requests.first.statusCode, 200);
    final session = sessionFor(controller);
    await session.ready.timeout(const Duration(seconds: 20));
    expect(controller.state.sessionId, session.id);
    expect(controller.state.timeline.isSeekable, isFalse);
    final positionBeforeSeek = controller.state.timeline.position;

    await expectLater(
      session.seekTo(const Duration(milliseconds: 900)),
      throwsA(
        isA<YlPlayerException>().having(
          (error) => error.failure.code,
          'code',
          'network.range_not_supported',
        ),
      ),
    );
    expect(controller.state.timeline.position, positionBeforeSeek);
    expect(controller.state.engine, YlPlaybackEngine.managedFallback);
  });

  testWidgets('failed network MKV candidate preserves current HLS', (
    WidgetTester tester,
  ) async {
    final failingServer = await RangeMediaServer.start(
      asset: 'assets/test_media/h264_aac.mkv',
      scriptedResponses: const <RangeMediaResponse>[
        RangeMediaResponse.status(404),
      ],
    );
    addTearDown(failingServer.close);
    final controller = await YlPlayerController.create();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: controller)),
    );
    final firstFrame = controller.events
        .firstWhere((event) => event is YlFirstFrameEvent)
        .timeout(const Duration(seconds: 45));
    final hlsServer = await AuthenticatedHlsServer.start(sameOrigin: true);
    addTearDown(hlsServer.close);
    await loadSession(
      controller,
      YlNetworkSource(hlsServer.masterUri, format: YlMediaFormat.hls),
    );
    await sessionFor(controller).play();
    await sessionFor(controller).ready.timeout(const Duration(seconds: 20));
    await firstFrame;

    await expectLater(
      loadSession(
        controller,
        YlNetworkSource(failingServer.mediaUri, format: YlMediaFormat.matroska),
      ),
      throwsA(
        isA<YlPlayerException>().having(
          (error) => error.failure.code,
          'code',
          'network.http_status',
        ),
      ),
    );

    expect(controller.state.engine, YlPlaybackEngine.avPlayer);
    await sessionFor(controller).play();
    await sessionFor(controller).ready.timeout(const Duration(seconds: 20));
    final recoveredState = await controller.states
        .firstWhere(
          (state) =>
              state.engine == YlPlaybackEngine.avPlayer &&
              state.status != YlPlaybackStatus.failed,
        )
        .timeout(const Duration(seconds: 5));
    expect(recoveredState.engine, YlPlaybackEngine.avPlayer);
    expect(failingServer.requests, hasLength(1));
  });
}
