import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/authenticated_hls_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('opens HLS and produces a native texture first frame', (
    WidgetTester tester,
  ) async {
    final server = await AuthenticatedHlsServer.start();
    addTearDown(server.close);
    final hlsSource = YlMediaSource.network(
      server.masterUri,
      formatHint: YlFormatHint.hls,
    );
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
    final server = await AuthenticatedHlsServer.start();
    addTearDown(server.close);
    final hlsSource = YlMediaSource.network(
      server.masterUri,
      formatHint: YlFormatHint.hls,
    );
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
          Uri.parse('https://example.invalid/live.mkv'),
          formatHint: YlFormatHint.matroska,
          isLive: true,
        ),
      ),
      throwsA(
        isA<YlPlayerError>().having(
          (error) => error.code,
          'code',
          'container.network_mkv_live_unsupported',
        ),
      ),
    );

    expect(controller.state.engine, YlPlaybackEngine.avPlayer);
    final recoveredState = controller.states
        .firstWhere(
          (state) =>
              state.engine == YlPlaybackEngine.avPlayer &&
              state.status != YlPlaybackStatus.error,
        )
        .timeout(const Duration(seconds: 5));
    await controller.play();
    await recoveredState;
  });
}
