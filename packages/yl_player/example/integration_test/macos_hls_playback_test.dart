import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/authenticated_hls_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS HLS reaches first frame, advances, pauses, and disposes', (
    WidgetTester tester,
  ) async {
    final server = await AuthenticatedHlsServer.start();
    addTearDown(server.close);
    final controller = YlPlayerController(
      configuration: const YlPlayerConfiguration(
        bufferMode: YlBufferMode.lowLatency,
      ),
    );

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
          (state) => state.position >= const Duration(milliseconds: 250),
        )
        .timeout(const Duration(seconds: 10));

    await controller.open(
      YlMediaSource.network(server.masterUri, formatHint: YlFormatHint.hls),
    );
    await controller.play();
    try {
      await Future.wait<void>(<Future<void>>[
        firstFrame.then((_) {}),
        positionAdvanced.then((_) {}),
      ]);
    } on TimeoutException {
      debugPrint(
        'macOS HLS timeout: status=${controller.state.status}, '
        'position=${controller.state.position}, '
        'buffered=${controller.state.bufferedPosition}, '
        'error=${controller.state.error}',
      );
      rethrow;
    }

    await controller.pause();
    await controller.states
        .firstWhere((state) => state.status == YlPlaybackStatus.paused)
        .timeout(const Duration(seconds: 5));
    expect(controller.textureId.value, isNotNull);
    expect(controller.state.engine, YlPlaybackEngine.avPlayer);

    await controller.dispose();
  });
}
