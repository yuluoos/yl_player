import 'dart:async';
import 'package:yl_player_android/src/pigeon/yl_player_android.g.dart';
import 'support/android_callback_probe.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/android_test_support.dart';
import 'support/range_media_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Newer Load cancels strict inspection before decoder evidence; stale sessions reject',
    (tester) async {
      final media = await RangeMediaServer.start(
        asset: 'assets/test_media/network_seek_h264_aac.mkv',
      );
      final held = await HeldAndroidServer.start();
      addTearDown(media.close);
      addTearDown(held.close);
      final player = await YlPlayerController.create();
      addTearDown(player.dispose);
      await tester.pumpWidget(
        MaterialApp(home: YlPlayerView(controller: player)),
      );
      final source = YlNetworkSource(
        media.mediaUri,
        format: YlMediaFormat.matroska,
      );
      final old = await player.load(source);
      await old.play();
      await old.firstFrame.timeout(const Duration(seconds: 20));
      final events = <YlPlayerEvent>[];
      final subscription = player.events.listen(events.add);
      addTearDown(subscription.cancel);
      var settled = false;
      final pending = player.load(
        YlNetworkSource(held.uri, format: YlMediaFormat.matroska),
        options: const YlLoadOptions(
          decoderPolicyOverride: YlDecoderPolicy.hardwareRequired,
        ),
      );
      final cancelled = expectLater(
        pending.whenComplete(() => settled = true),
        throwsA(failureCode(YlFailureCodes.loadCancelled)),
      );
      await held.requested.future.timeout(const Duration(seconds: 10));
      expect(
        settled,
        isFalse,
        reason: 'Initial buffering cannot complete Load/Ready',
      );
      expect(player.state.sessionId, old.id);
      expect(
        events.whereType<YlFirstFrameEvent>(),
        isEmpty,
        reason: 'Private candidate output cannot publish a frame',
      );
      final newer = await player.load(source);
      await cancelled;
      await newer.play();
      await newer.firstFrame.timeout(const Duration(seconds: 20));
      expect(newer.id, isNot(old.id));
      await expectLater(
        old.seekTo(Duration.zero),
        throwsA(failureCode(YlFailureCodes.sessionStale)),
      );
    },
  );
  testWidgets(
    'Actual native callbacks wait for delayed acknowledgement across methods',
    (tester) async {
      final media = await RangeMediaServer.start(
        asset: 'assets/test_media/network_seek_h264_aac.mkv',
      );
      addTearDown(media.close);
      final created = await AndroidPlayerFactoryHostApi().create(
        AndroidCreateRequest(
          schemaMajor: 2,
          options: AndroidPlayerOptionsMessage(
            decoderPolicy: AndroidDecoderPolicy.hardwarePreferred,
            audioPolicy: AndroidAudioPolicy.appManaged,
            positionUpdateIntervalMs: 100,
          ),
        ),
      );
      final host = AndroidPlayerHostApi(
        messageChannelSuffix: created.channelSuffix,
      );
      final probe = AndroidCallbackProbe(created.channelSuffix);
      final release = Completer<void>();
      probe.hold = release;
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await host.dispose();
        probe.close();
      });
      await host.attach();
      final loading = host.load(
        AndroidLoadRequest(
          loadRequestId: 'integration-ack',
          source: AndroidSourceMessage(
            kind: AndroidSourceKind.network,
            locator: media.mediaUri.toString(),
            intent: AndroidStreamIntent.onDemand,
            format: AndroidMediaFormat.matroska,
          ),
          options: AndroidLoadOptionsMessage(
            autoplay: false,
            bufferStrategy: AndroidBufferStrategyMessage(
              kind: AndroidBufferKind.automatic,
            ),
            videoConstraints: AndroidVideoConstraintsMessage(),
          ),
        ),
      );
      await probe.entered.future.timeout(const Duration(seconds: 15));
      final delivered = probe.received.length;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(
        probe.received,
        hasLength(delivered),
        reason: 'No native callback may overtake an unacknowledged callback',
      );
      await host.setVolume(.4).timeout(const Duration(seconds: 3));
      release.complete();
      final loaded = await loading.timeout(const Duration(seconds: 25));
      expect(loaded.sessionId, isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(probe.received.length, greaterThan(delivered));
      expect(probe.received.whereType<AndroidStateMessage>(), isNotEmpty);
      expect(
        probe.received.any(
          (message) =>
              message is AndroidStateDeltaMessage ||
              message is AndroidFirstFrameMessage,
        ),
        isTrue,
        reason:
            'Acknowledgement releases the shared FIFO across callback methods',
      );
    },
  );
}
