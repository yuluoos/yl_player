import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/playback_sessions.dart';

import 'support/range_media_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final hlsSource = YlNetworkSource(
    Uri.parse(
      'https://devstreaming-cdn.apple.com/videos/streaming/examples/'
      'img_bipbop_adv_example_ts/master.m3u8',
    ),
    format: YlMediaFormat.hls,
  );

  Future<bool> openNetworkMkvOrVerifyHardwareError(
    YlPlayerController controller,
    RangeMediaServer server, {
    YlLoadOptions options = const YlLoadOptions(),
  }) async {
    try {
      await loadSession(
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
      return true;
    } on YlPlayerException catch (error) {
      expect(
        error.failure.code,
        YlFailureCodes.decoderUnavailable,
        reason: error.toString(),
      );
      expect(error.failure.category, YlFailureCategory.decoder);
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
    final controller = await YlPlayerController.create();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: controller)),
    );

    final opened = await openNetworkMkvOrVerifyHardwareError(
      controller,
      server,
      options: const YlLoadOptions(
        bufferStrategy: YlBufferStrategy.lowLatency(),
      ),
    );
    expect(server.requests, isNotEmpty);
    expect(server.requests.first.header('x-yl-test'), 'network-mkv');
    expect(server.requests.first.statusCode, 206);
    if (!opened) return;

    final firstFrame = controller.events
        .firstWhere((event) => event is YlFirstFrameEvent)
        .timeout(const Duration(seconds: 15));
    await sessionFor(controller).play();
    await sessionFor(controller).ready.timeout(const Duration(seconds: 20));
    await firstFrame;
    expect(controller.state.engine, YlPlaybackEngine.managedFallback);
    expect(controller.state.decoderMode, YlDecoderMode.hardware);
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

    if (!await openNetworkMkvOrVerifyHardwareError(controller, server)) {
      expect(server.requests.first.statusCode, 200);
      return;
    }
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
    await loadSession(controller, hlsSource);
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
