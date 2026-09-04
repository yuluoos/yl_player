import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/range_media_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final hlsSource = YlMediaSource.network(
    Uri.parse(
      'https://devstreaming-cdn.apple.com/videos/streaming/examples/'
      'img_bipbop_adv_example_ts/master.m3u8',
    ),
    formatHint: YlFormatHint.hls,
  );

  Future<bool> openNetworkMkvOrVerifyHardwareError(
    YlPlayerController controller,
    RangeMediaServer server,
  ) async {
    try {
      await controller.open(
        YlMediaSource.network(
          server.mediaUri,
          formatHint: YlFormatHint.matroska,
          headers: const <String, String>{'X-Yl-Test': 'network-mkv'},
        ),
      );
      return true;
    } on YlPlayerError catch (error) {
      expect(
        error.code,
        'decoder.video_hardware_unavailable',
        reason: error.toString(),
      );
      expect(error.category, YlPlayerErrorCategory.decoderUnsupported);
      return false;
    }
  }

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

    final opened = await openNetworkMkvOrVerifyHardwareError(
      controller,
      server,
    );
    expect(server.requests, isNotEmpty);
    expect(server.requests.first.header('x-yl-test'), 'network-mkv');
    expect(server.requests.first.statusCode, 206);
    if (!opened) return;

    final firstFrame = controller.events
        .firstWhere((event) => event is YlFirstFrameEvent)
        .timeout(const Duration(seconds: 15));
    await controller.play();
    await firstFrame;
    expect(controller.state.engine, YlPlaybackEngine.nativeFallback);
    expect(controller.state.isHardwareDecoding, isTrue);
    expect(controller.state.isSeekable, isTrue);

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

    if (!await openNetworkMkvOrVerifyHardwareError(controller, server)) {
      expect(server.requests.first.statusCode, 200);
      return;
    }
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
    final controller = YlPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: controller)),
    );
    final firstFrame = controller.events
        .firstWhere((event) => event is YlFirstFrameEvent)
        .timeout(const Duration(seconds: 45));
    await controller.open(hlsSource);
    await controller.play();
    await firstFrame;

    await expectLater(
      controller.open(
        YlMediaSource.network(
          failingServer.mediaUri,
          formatHint: YlFormatHint.matroska,
        ),
      ),
      throwsA(
        isA<YlPlayerError>().having(
          (error) => error.code,
          'code',
          'network.http_status',
        ),
      ),
    );

    expect(controller.state.engine, YlPlaybackEngine.avPlayer);
    await controller.play();
    final recoveredState = await controller.states
        .firstWhere(
          (state) =>
              state.engine == YlPlaybackEngine.avPlayer &&
              state.status != YlPlaybackStatus.error,
        )
        .timeout(const Duration(seconds: 5));
    expect(recoveredState.engine, YlPlaybackEngine.avPlayer);
    expect(failingServer.requests, hasLength(1));
  });
}
