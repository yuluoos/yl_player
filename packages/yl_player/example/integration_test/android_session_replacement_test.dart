import 'dart:async';
import 'package:yl_player_android/src/pigeon/yl_player_android.g.dart';
import 'support/android_callback_probe.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/android_test_support.dart';
import 'support/range_media_server.dart';
import 'support/gated_android_media_server.dart';
import 'support/android_frame_observation.dart';

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
        reason: 'A candidate with held input cannot publish a frame',
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
    'Decoded private candidate frame is suppressed until authoritative public output',
    (tester) async {
      final original = await RangeMediaServer.start(
        asset: 'assets/test_media/network_seek_h264_aac.mkv',
      );
      final gated = await GatedAndroidMediaServer.start();
      addTearDown(original.close);
      addTearDown(gated.close);
      final player = await YlPlayerController.create();
      addTearDown(player.dispose);
      await tester.pumpWidget(
        MaterialApp(home: YlPlayerView(controller: player)),
      );
      final old = await player.load(
        YlNetworkSource(original.mediaUri, format: YlMediaFormat.matroska),
      );
      await old.play();
      await old.firstFrame.timeout(const Duration(seconds: 20));
      final publicFrames = <(YlFirstFrameEvent, YlPlaybackSessionId?, int)>[];
      final sub = player.events
          .where((event) => event is YlFirstFrameEvent)
          .cast<YlFirstFrameEvent>()
          .listen((event) {
            publicFrames.add((
              event,
              player.state.sessionId,
              player.state.revision,
            ));
          });
      addTearDown(sub.cancel);
      final observer = AndroidFrameObservation();
      addTearDown(observer.remove);
      var settled = false;
      final loading = player.load(
        YlNetworkSource(gated.uri, format: YlMediaFormat.matroska),
      );
      // Observe rejection immediately too, so cleanup does not create an unhandled Future.
      final observedLoad = loading.whenComplete(() => settled = true);
      unawaited(observedLoad.then<void>((_) {}, onError: (Object _) {}));
      await gated.requested.future.timeout(const Duration(seconds: 10));
      final installed = await observer.install(old.id.value);
      gated.prefix.complete();
      await gated.deliveredPrefix.future.timeout(const Duration(seconds: 5));
      Map<Object?, Object?>? privateFrame;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (privateFrame == null && DateTime.now().isBefore(deadline)) {
        final records = await observer.read();
        for (final record in records) {
          if (record['kind'] == 'frame' && record['private'] == true) {
            privateFrame = record;
          }
        }
        if (privateFrame == null) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      expect(
        privateFrame,
        isNotNull,
        reason:
            'Real Media3 must have rendered the valid prefix to its actual private Surface',
      );
      expect(privateFrame!['decoderSeen'], isTrue);
      expect(privateFrame['matchesCurrentSurface'], isTrue);
      expect(privateFrame['public'], isFalse);
      expect(privateFrame['surfaceId'], installed['privateSurfaceId']);
      expect(privateFrame['sessionId'], installed['sessionId']);
      expect(gated.bodyBytesSent, greaterThan(0));
      expect(settled, isFalse);
      expect(player.state.sessionId, old.id);
      expect(publicFrames, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(settled, isFalse);
      expect(publicFrames, isEmpty);
      gated.remainder.complete();
      final current = await observedLoad.timeout(const Duration(seconds: 20));
      expect(current.id.value, installed['sessionId']);
      await current.play();
      await current.firstFrame.timeout(const Duration(seconds: 15));
      final records = await observer.read();
      final publicNativeFrames = records
          .where(
            (record) => record['kind'] == 'frame' && record['public'] == true,
          )
          .toList();
      expect(publicNativeFrames, isNotEmpty);
      final publicNative = publicNativeFrames.first;
      expect(publicNative['private'], isFalse);
      expect(publicNative['matchesCurrentSurface'], isTrue);
      expect(publicNative['surfaceId'], isNot(privateFrame['surfaceId']));
      expect(
        publicNative['timeMs'] as int,
        greaterThan(privateFrame['timeMs'] as int),
      );
      expect(publicFrames, hasLength(1));
      final (event, stateAtEvent, revisionAtEvent) = publicFrames.single;
      expect(event.sessionId, current.id);
      expect(stateAtEvent, current.id);
      expect(revisionAtEvent, greaterThanOrEqualTo(event.revision));
      expect(event.occurredAt.inMilliseconds, publicNative['timeMs']);
      await expectLater(
        old.play(),
        throwsA(failureCode(YlFailureCodes.sessionStale)),
      );
      debugPrint(
        'YL_PRIVATE_FRAME_PROOF private=${privateFrame['surfaceId']} public=${publicNative['surfaceId']} privateMs=${privateFrame['timeMs']} publicMs=${publicNative['timeMs']}',
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
