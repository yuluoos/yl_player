import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/playback_sessions.dart';

import 'support/authenticated_hls_server.dart';

void main() {
  // AVPlayer's first-frame event requires the native view to be mounted.
  // Keep rendering while the test awaits asynchronous playback events.
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('macOS HLS reaches first frame, advances, pauses, and disposes', (
    WidgetTester tester,
  ) async {
    final server = await AuthenticatedHlsServer.start();
    addTearDown(server.close);
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
    final positionAdvanced = controller.states
        .firstWhere(
          (state) =>
              state.timeline.position >= const Duration(milliseconds: 250),
        )
        .timeout(const Duration(seconds: 10));

    await loadSession(
      controller,
      YlNetworkSource(server.masterUri, format: YlMediaFormat.hls),
      options: const YlLoadOptions(
        bufferStrategy: YlBufferStrategy.lowLatency(),
      ),
    );
    await sessionFor(controller).play();
    await sessionFor(controller).ready.timeout(const Duration(seconds: 20));
    try {
      await Future.wait<void>(<Future<void>>[
        firstFrame.then((_) {}),
        positionAdvanced.then((_) {}),
      ]);
    } on TimeoutException {
      debugPrint(
        'macOS HLS timeout: status=${controller.state.status}, '
        'position=${controller.state.timeline.position}, '
        'buffered=${controller.state.timeline.bufferedPosition}, '
        'error=${controller.state.failure}',
      );
      rethrow;
    }

    final paused = controller.states
        .firstWhere((state) => state.status == YlPlaybackStatus.paused)
        .timeout(const Duration(seconds: 5));
    await sessionFor(controller).pause();
    await paused;
    expect(controller.textureId.value, isNotNull);
    expect(controller.state.engine, YlPlaybackEngine.avPlayer);
    expect(
      controller.state.videoGeometry,
      isNotNull,
      reason:
          'A decoded HLS frame must carry geometry so the view can display it',
    );
    await tester.pump();
    expect(controller.nativeVideoSurface, isNotNull);
    expect(find.byType(AppKitView), findsOneWidget);
    expect(
      tester.widget<AppKitView>(find.byType(AppKitView)).viewType,
      controller.nativeVideoSurface!.viewType,
    );

    await controller.dispose();
  });
}
