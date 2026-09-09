import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/playback_sessions.dart';

import 'support/range_media_server.dart';

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
      request: YlHttpRequest(
        headers: const <String, String>{'X-Yl-Test': 'network-mkv'},
      ),
    ),
    options: options,
  );

  Future<double> measurePlaybackRate(
    YlPlayerController controller,
    double speed,
  ) async {
    await sessionFor(controller).setPlaybackSpeed(speed);
    final positionBeforeChange = controller.state.timeline.position;
    final first = await controller.states
        .firstWhere((state) => state.timeline.position > positionBeforeChange)
        .timeout(const Duration(seconds: 5));
    final elapsed = Stopwatch()..start();
    final last = await controller.states
        .firstWhere(
          (state) =>
              state.timeline.position > first.timeline.position &&
              elapsed.elapsed >= const Duration(milliseconds: 900),
        )
        .timeout(const Duration(seconds: 5));
    elapsed.stop();
    expect(last.status, YlPlaybackStatus.playing);
    expect(last.failure, isNull);
    return (last.timeline.position - first.timeline.position).inMicroseconds /
        elapsed.elapsedMicroseconds;
  }

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
    expect(controller.state.decoderMode, YlDecoderMode.hardware);
    expect(controller.state.timeline.isSeekable, isTrue);

    final positionBeforeRateChange = controller.state.timeline.position;
    await sessionFor(controller).setPlaybackSpeed(3);
    final accelerated = await controller.states
        .firstWhere(
          (state) =>
              state.timeline.position >=
              positionBeforeRateChange + const Duration(milliseconds: 500),
        )
        .timeout(const Duration(seconds: 5));
    await sessionFor(controller).setPlaybackSpeed(1);
    final restored = await controller.states
        .firstWhere(
          (state) =>
              state.timeline.position >=
              accelerated.timeline.position + const Duration(milliseconds: 250),
        )
        .timeout(const Duration(seconds: 5));
    expect(restored.status, YlPlaybackStatus.playing);
    expect(restored.failure, isNull);

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

  testWidgets('HTTP range MKV repeatedly applies and restores playback speed', (
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

    await openNetworkMkv(controller, server);
    await sessionFor(controller).play();
    await sessionFor(controller).ready.timeout(const Duration(seconds: 20));
    await controller.states
        .firstWhere(
          (state) =>
              state.timeline.position >= const Duration(milliseconds: 500),
        )
        .timeout(const Duration(seconds: 10));

    final underrunsBeforeTransitions = controller.state.metrics.audioUnderruns;
    for (var cycle = 0; cycle < 2; cycle += 1) {
      final acceleratedRate = await measurePlaybackRate(controller, 3);
      expect(acceleratedRate, greaterThan(2));
      expect(acceleratedRate, lessThan(4.25));

      final restoredRate = await measurePlaybackRate(controller, 1);
      expect(restoredRate, greaterThan(0.55));
      expect(restoredRate, lessThan(1.7));
      expect(controller.state.status, YlPlaybackStatus.playing);
      expect(controller.state.failure, isNull);
    }
    expect(controller.state.metrics.audioUnderruns, underrunsBeforeTransitions);
    expect(controller.state.status, YlPlaybackStatus.playing);
    expect(controller.state.failure, isNull);
  });

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
}
