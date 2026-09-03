import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final hlsSource = YlMediaSource.network(
    Uri.parse(
      'https://devstreaming-cdn.apple.com/videos/streaming/examples/'
      'img_bipbop_adv_example_ts/master.m3u8',
    ),
    formatHint: YlFormatHint.hls,
  );

  testWidgets('opens Apple HLS and produces a native texture first frame', (
    WidgetTester tester,
  ) async {
    final controller = YlPlayerController(
      configuration: const YlPlayerConfiguration(
        bufferMode: YlBufferMode.lowLatency,
      ),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AspectRatio(
          aspectRatio: 16 / 9,
          child: YlPlayerView(controller: controller),
        ),
      ),
    );
    final firstFrame = controller.events
        .firstWhere((event) => event is YlFirstFrameEvent)
        .timeout(const Duration(seconds: 45));

    await controller.open(hlsSource);
    await controller.play();
    await firstFrame;
    await tester.pump();

    expect(controller.textureId.value, isNotNull);
    expect(
      controller.state.status,
      anyOf(YlPlaybackStatus.playing, YlPlaybackStatus.buffering),
    );
    expect(controller.state.engine, isNot(YlPlaybackEngine.unknown));
  });

  testWidgets('rejecting a fallback source does not tear down current HLS', (
    WidgetTester tester,
  ) async {
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
          Uri.parse('https://example.invalid/live.flv'),
          formatHint: YlFormatHint.httpFlv,
          isLive: true,
        ),
      ),
      throwsA(
        isA<YlPlayerError>().having(
          (error) => error.code,
          'code',
          'container.native_fallback_required',
        ),
      ),
    );

    final recoveredState = await controller.states
        .firstWhere(
          (state) =>
              state.status == YlPlaybackStatus.playing ||
              state.status == YlPlaybackStatus.buffering ||
              state.status == YlPlaybackStatus.ready,
        )
        .timeout(const Duration(seconds: 5));
    expect(recoveredState.engine, YlPlaybackEngine.avPlayer);
  });
}
