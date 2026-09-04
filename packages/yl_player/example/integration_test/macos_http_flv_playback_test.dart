import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

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
    final controller = YlPlayerController(
      configuration: const YlPlayerConfiguration(
        bufferMode: YlBufferMode.lowLatency,
        networkPolicy: YlNetworkPolicy(
          maxRetries: 3,
          baseRetryDelay: Duration(milliseconds: 50),
          maxRetryDelay: Duration(milliseconds: 200),
        ),
      ),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: controller)),
    );
    final capabilities =
        controller.capabilities ??
        (await controller.states
                .firstWhere((state) => state.capabilities != null)
                .timeout(const Duration(seconds: 5)))
            .capabilities!;
    expect(capabilities.supportedFormats, contains(YlFormatHint.httpFlv));
    expect(capabilities.supportedFormats, contains(YlFormatHint.flv));

    final firstFrame = Completer<YlFirstFrameEvent>();
    final retry = Completer<YlRetryEvent>();
    final eventSubscription = controller.events.listen((event) {
      if (event is YlFirstFrameEvent && !firstFrame.isCompleted) {
        firstFrame.complete(event);
      } else if (event is YlRetryEvent && !retry.isCompleted) {
        retry.complete(event);
      }
    });
    addTearDown(eventSubscription.cancel);

    await controller.open(
      YlMediaSource.network(
        server.streamUri,
        isLive: true,
        formatHint: YlFormatHint.httpFlv,
        headers: const <String, String>{'X-Client': 'yl-player-test'},
      ),
    );

    expect(controller.state.engine, YlPlaybackEngine.nativeFallback);
    expect(controller.state.isLive, isTrue);
    expect(controller.state.isSeekable, isFalse);
    expect(controller.state.isHardwareDecoding, isTrue);

    await controller.play();
    await firstFrame.future.timeout(const Duration(seconds: 15));
    final retryEvent = await retry.future.timeout(const Duration(seconds: 15));
    expect(retryEvent.attempt, 1);
    expect(retryEvent.error.category, YlPlayerErrorCategory.network);

    final resumed = await controller.states
        .firstWhere(
          (state) =>
              server.connectionCount >= 2 &&
              state.engine == YlPlaybackEngine.nativeFallback &&
              state.status == YlPlaybackStatus.playing &&
              state.metrics.reconnectCount >= 1,
        )
        .timeout(const Duration(seconds: 15));
    expect(resumed.isLive, isTrue);
    expect(resumed.isSeekable, isFalse);
    expect(server.connectionCount, greaterThanOrEqualTo(2));
    expect(
      server.requestHeaders.every(
        (headers) => headers['x-client']?.single == 'yl-player-test',
      ),
      isTrue,
    );
  });
}
