import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/playback_sessions.dart';

import 'support/authenticated_hls_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS HLS reaches first frame, advances, pauses, and disposes', (
    WidgetTester tester,
  ) async {
    final server = await AuthenticatedHlsServer.start();
    addTearDown(server.close);
    final controller = await YlPlayerController.create();

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

    await sessionFor(controller).pause();
    await controller.states
        .firstWhere((state) => state.status == YlPlaybackStatus.paused)
        .timeout(const Duration(seconds: 5));
    expect(controller.textureId.value, isNotNull);
    expect(controller.state.engine, YlPlaybackEngine.avPlayer);

    await controller.dispose();
  });
}
