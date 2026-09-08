import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/playback_sessions.dart';

import 'support/authenticated_hls_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('opens HLS and produces a native texture first frame', (
    WidgetTester tester,
  ) async {
    final server = await AuthenticatedHlsServer.start();
    addTearDown(server.close);
    final hlsSource = YlNetworkSource(
      server.masterUri,
      format: YlMediaFormat.hls,
    );
    final controller = await YlPlayerController.create();
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

    await loadSession(
      controller,
      hlsSource,
      options: const YlLoadOptions(
        bufferStrategy: YlBufferStrategy.lowLatency(),
      ),
    );
    await sessionFor(controller).play();
    await sessionFor(controller).ready.timeout(const Duration(seconds: 20));
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
    final hlsSource = YlNetworkSource(
      server.masterUri,
      format: YlMediaFormat.hls,
    );
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
        YlNetworkSource(
          Uri.parse('https://example.invalid/live.mkv'),
          format: YlMediaFormat.matroska,
          intent: YlStreamIntent.live,
        ),
      ),
      throwsA(
        isA<YlPlayerException>().having(
          (error) => error.failure.code,
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
              state.status != YlPlaybackStatus.failed,
        )
        .timeout(const Duration(seconds: 5));
    await sessionFor(controller).play();
    await sessionFor(controller).ready.timeout(const Duration(seconds: 20));
    await recoveredState;
  });
}
