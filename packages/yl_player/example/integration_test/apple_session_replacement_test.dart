import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/apple_callback_probe.dart';
import 'support/range_media_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final cancel in [false, true]) {
    testWidgets(
      'old playback stays authoritative while candidate ${cancel ? 'is cancelled' : 'fails'}',
      (tester) async {
        final oldServer = await RangeMediaServer.start(
          asset: 'assets/test_media/network_seek_h264_aac.mkv',
        );
        addTearDown(oldServer.close);
        final entered = Completer<void>(), release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        final candidateServer = await RangeMediaServer.start(
          asset: 'assets/test_media/h264_aac.mkv',
          scriptedResponses: const [RangeMediaResponse.status(404)],
          beforeResponse: (_) {
            if (!entered.isCompleted) entered.complete();
            return release.future;
          },
        );
        addTearDown(candidateServer.close);
        final controller = await appleController(tester);
        final old = await controller.load(
          YlNetworkSource(oldServer.mediaUri, format: YlMediaFormat.matroska),
        );
        await readyAndPlay(controller, old);
        final frames = <YlFirstFrameEvent>[];
        final sub = controller.events.listen((event) {
          if (event is YlFirstFrameEvent) frames.add(event);
        });
        addTearDown(sub.cancel);
        final candidate = controller.load(
          YlNetworkSource(
            candidateServer.mediaUri,
            format: YlMediaFormat.matroska,
            networkPolicy: strictNetwork,
          ),
          options: const YlLoadOptions(),
        );
        final rejected = expectLater(
          candidate,
          failureCode(
            cancel ? YlFailureCodes.loadCancelled : 'network.http_status',
          ),
        );
        await entered.future.timeout(const Duration(seconds: 5));
        expect(controller.state.sessionId, old.id);
        final position = controller.state.timeline.position;
        await stateWhere(
          controller,
          (s) => s.sessionId == old.id && s.timeline.position > position,
        );
        await old.pause();
        await stateWhere(
          controller,
          (s) => s.status == YlPlaybackStatus.paused,
        );
        await old.play();
        if (cancel) await controller.stop();
        release.complete();
        await rejected;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(frames.where((e) => e.sessionId != old.id), isEmpty);
        if (!cancel) {
          expect(controller.state.sessionId, old.id);
          await old.pause();
          await old.play();
          await stateWhere(
            controller,
            (s) =>
                s.sessionId == old.id && s.status == YlPlaybackStatus.playing,
          );
        } else {
          expect(controller.state.sessionId, isNull);
        }
      },
    );
  }
  testWidgets(
    'public controller retains ready while actual native callback acknowledgement is held',
    (tester) async {
      final server = await RangeMediaServer.start(
        asset: 'assets/test_media/h264_aac.mkv',
      );
      addTearDown(server.close);
      final probe = AppleCallbackProbe();
      final controller = await YlPlayerController.create(
        platform: probe,
        options: const YlPlayerOptions(
          decoderPolicy: YlDecoderPolicy.systemDefault,
        ),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: YlPlayerView(controller: controller)),
      );
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      probe.messenger.hold = release;
      final loading = controller.load(
        YlNetworkSource(
          server.mediaUri,
          format: YlMediaFormat.matroska,
          networkPolicy: strictNetwork,
        ),
        options: const YlLoadOptions(),
      );
      await probe.messenger.entered.future.timeout(const Duration(seconds: 5));
      final received = probe.messenger.received;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        probe.messenger.received,
        received,
        reason: 'Native FIFO must await actual Pigeon acknowledgement.',
      );
      release.complete();
      final session = await loading;
      await readyAndPlay(controller, session);
      await session.ready;
      await session.firstFrame;
      expect(controller.state.sessionId, session.id);
    },
  );
}
