import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/playback_sessions.dart';

import 'support/live_flv_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('HTTP-FLV plays live and reconnects after a dropped socket', (
    WidgetTester tester,
  ) async {
    final server = await LiveFlvServer.start(
      asset: 'assets/test_media/h264_aac.flv',
      disconnectFirstConnection: true,
    );
    addTearDown(server.close);
    final controller = await YlPlayerController.create();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: controller)),
    );
    expect(
      controller.capabilities.availableEngines,
      contains(YlPlaybackEngine.managedFallback),
    );

    final firstFrame = Completer<YlFirstFrameEvent>();
    final retry = Completer<YlRetryScheduledEvent>();
    final eventSubscription = controller.events.listen((event) {
      if (event is YlFirstFrameEvent && !firstFrame.isCompleted) {
        firstFrame.complete(event);
      } else if (event is YlRetryScheduledEvent && !retry.isCompleted) {
        retry.complete(event);
      }
    });
    addTearDown(eventSubscription.cancel);

    try {
      await loadSession(
        controller,
        YlNetworkSource(
          server.streamUri,
          intent: YlStreamIntent.live,
          format: YlMediaFormat.flv,
          request: YlHttpRequest(
            headers: const <String, String>{'X-Client': 'yl-player-test'},
          ),
        ),
        options: const YlLoadOptions(
          bufferStrategy: YlBufferStrategy.lowLatency(),
        ),
      );
    } on YlPlayerException catch (error) {
      // Simulator runtimes do not guarantee an available VideoToolbox H.264
      // session. The exact hardware-only error remains a valid simulator gate;
      // physical-device rows require playback and reconnect success.
      expect(error.failure.code, YlFailureCodes.decoderUnavailable);
      expect(error.failure.category, YlFailureCategory.decoder);
      expect(server.connectionCount, greaterThanOrEqualTo(1));
      return;
    }

    await sessionFor(controller).play();
    await sessionFor(controller).ready.timeout(const Duration(seconds: 20));
    expect(controller.state.engine, YlPlaybackEngine.managedFallback);
    expect(controller.state.timeline.isLive, isTrue);
    expect(controller.state.timeline.isSeekable, isFalse);
    expect(controller.state.decoderMode, YlDecoderMode.hardware);

    await firstFrame.future.timeout(const Duration(seconds: 15));
    final retryEvent = await retry.future.timeout(const Duration(seconds: 15));
    expect(retryEvent.retryIndex, 1);
    expect(retryEvent.failure.category, YlFailureCategory.network);

    final resumed = await controller.states
        .firstWhere(
          (state) =>
              server.connectionCount >= 2 &&
              state.engine == YlPlaybackEngine.managedFallback &&
              state.status == YlPlaybackStatus.playing &&
              (state.metrics.reconnectCount ?? 0) >= 1,
        )
        .timeout(const Duration(seconds: 15));
    expect(resumed.timeline.isLive, isTrue);
    expect(resumed.timeline.isSeekable, isFalse);
    expect(server.connectionCount, greaterThanOrEqualTo(2));
    expect(
      server.requestHeaders.every(
        (headers) => headers['x-client']?.single == 'yl-player-test',
      ),
      isTrue,
    );
  });
}
