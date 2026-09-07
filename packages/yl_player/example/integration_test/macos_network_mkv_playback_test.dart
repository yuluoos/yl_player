import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/range_media_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> openNetworkMkv(
    YlPlayerController controller,
    RangeMediaServer server,
  ) => controller.open(
    YlMediaSource.network(
      server.mediaUri,
      formatHint: YlFormatHint.matroska,
      headers: const <String, String>{'X-Yl-Test': 'network-mkv'},
    ),
  );

  testWidgets('HTTP range MKV uses the native fallback', (
    WidgetTester tester,
  ) async {
    final server = await RangeMediaServer.start(
      asset: 'assets/test_media/network_seek_h264_aac.mkv',
    );
    addTearDown(server.close);
    final controller = YlPlayerController(
      configuration: const YlPlayerConfiguration(
        bufferMode: YlBufferMode.lowLatency,
      ),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: controller)),
    );

    await openNetworkMkv(controller, server);
    expect(server.requests, isNotEmpty);
    expect(server.requests.first.header('x-yl-test'), 'network-mkv');
    expect(server.requests.first.statusCode, 206);
    final firstFrame = controller.events
        .firstWhere((event) => event is YlFirstFrameEvent)
        .timeout(const Duration(seconds: 15));
    await controller.play();
    await firstFrame;
    expect(controller.state.engine, YlPlaybackEngine.nativeFallback);
    expect(controller.state.isHardwareDecoding, isTrue);
    expect(controller.state.isSeekable, isTrue);

    final positionBeforeRateChange = controller.state.position;
    await controller.setPlaybackSpeed(3);
    final accelerated = await controller.states
        .firstWhere(
          (state) =>
              state.position >=
              positionBeforeRateChange + const Duration(milliseconds: 500),
        )
        .timeout(const Duration(seconds: 5));
    await controller.setPlaybackSpeed(1);
    final restored = await controller.states
        .firstWhere(
          (state) =>
              state.position >=
              accelerated.position + const Duration(milliseconds: 250),
        )
        .timeout(const Duration(seconds: 5));
    expect(restored.status, YlPlaybackStatus.playing);
    expect(restored.error, isNull);

    await controller.pause();
    final requestCountBeforeSeek = server.requests.length;
    await controller.seekTo(const Duration(seconds: 16));
    final seeked = await controller.states
        .firstWhere(
          (state) => state.position >= const Duration(milliseconds: 15500),
        )
        .timeout(const Duration(seconds: 10));
    expect(seeked.engine, YlPlaybackEngine.nativeFallback);
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

    expect(controller.audioTracks, hasLength(2));
    await controller.selectAudioTrack(controller.audioTracks[1].id);
    expect(controller.audioTracks[1].isSelected, isTrue);
  });

  testWidgets('HTTP range MKV repeatedly applies and restores playback speed', (
    WidgetTester tester,
  ) async {
    final server = await RangeMediaServer.start(
      asset: 'assets/test_media/network_seek_h264_aac.mkv',
    );
    addTearDown(server.close);
    final controller = YlPlayerController(
      configuration: const YlPlayerConfiguration(
        positionEventInterval: Duration(milliseconds: 100),
      ),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: controller)),
    );

    await openNetworkMkv(controller, server);
    await controller.play();
    await controller.states
        .firstWhere(
          (state) => state.position >= const Duration(milliseconds: 500),
        )
        .timeout(const Duration(seconds: 10));

    final underrunsBeforeTransitions = controller.state.metrics.audioUnderruns;
    for (var cycle = 0; cycle < 2; cycle += 1) {
      await controller.setPlaybackSpeed(3);
      final acceleratedStart = controller.state.position;
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final acceleratedDelta = controller.state.position - acceleratedStart;
      expect(acceleratedDelta, greaterThan(const Duration(milliseconds: 1800)));
      expect(acceleratedDelta, lessThan(const Duration(milliseconds: 3800)));

      await controller.setPlaybackSpeed(1);
      final restoredStart = controller.state.position;
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final restoredDelta = controller.state.position - restoredStart;
      expect(restoredDelta, greaterThan(const Duration(milliseconds: 500)));
      expect(restoredDelta, lessThan(const Duration(milliseconds: 1500)));
      expect(controller.state.status, YlPlaybackStatus.playing);
      expect(controller.state.error, isNull);
    }
    expect(controller.state.metrics.audioUnderruns, underrunsBeforeTransitions);
    expect(controller.state.status, YlPlaybackStatus.playing);
    expect(controller.state.error, isNull);
  });

  testWidgets('HTTP 200 sequential MKV rejects seek without losing playback', (
    WidgetTester tester,
  ) async {
    final server = await RangeMediaServer.start(
      asset: 'assets/test_media/h264_aac.mkv',
      supportsRanges: false,
    );
    addTearDown(server.close);
    final controller = YlPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: controller)),
    );

    await openNetworkMkv(controller, server);
    expect(controller.state.isSeekable, isFalse);
    final positionBeforeSeek = controller.state.position;

    await expectLater(
      controller.seekTo(const Duration(milliseconds: 900)),
      throwsA(
        isA<YlPlayerError>().having(
          (error) => error.code,
          'code',
          'network.range_not_supported',
        ),
      ),
    );
    expect(controller.state.position, positionBeforeSeek);
    expect(controller.state.engine, YlPlaybackEngine.nativeFallback);
  });
}
