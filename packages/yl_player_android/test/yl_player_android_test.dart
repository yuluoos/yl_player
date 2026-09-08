import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_android/yl_player_android.dart';
import 'package:yl_player_android/src/pigeon/yl_player_android.g.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'support/android_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const prefix = 'dev.flutter.pigeon.yl_player_android';
  const codec = AndroidPlayerHostApi.pigeonChannelCodec;

  void host(
    String method,
    FutureOr<Object?> Function(Object?) handler, {
    String suffix = '.instance-1',
  }) {
    final channel = BasicMessageChannel<Object?>(
      '$prefix.AndroidPlayerHostApi.$method$suffix',
      codec,
    );
    messenger.setMockDecodedMessageHandler(
      channel,
      (message) async => handler(message),
    );
    addTearDown(() => messenger.setMockDecodedMessageHandler(channel, null));
  }

  void factory(FutureOr<Object?> Function(Object?) handler) {
    final channel = BasicMessageChannel<Object?>(
      '$prefix.AndroidPlayerFactoryHostApi.create',
      AndroidPlayerFactoryHostApi.pigeonChannelCodec,
    );
    messenger.setMockDecodedMessageHandler(
      channel,
      (message) async => handler(message),
    );
    addTearDown(() => messenger.setMockDecodedMessageHandler(channel, null));
  }

  Future<Object?> callback(
    String name,
    Object value, {
    String suffix = 'instance-1',
  }) async {
    final completion = Completer<Object?>();
    await messenger.handlePlatformMessage(
      '$prefix.AndroidPlayerFlutterApi.$name.$suffix',
      codec.encodeMessage([value]),
      (data) {
        completion.complete(codec.decodeMessage(data));
      },
    );
    return completion.future;
  }

  test('registerWith installs v2 implementation', () {
    YlPlayerAndroid.registerWith();
    expect(YlPlayerPlatform.instance, isA<YlPlayerAndroid>());
  });
  test(
    'production Pigeon wrappers create, route every command and remove suffix callbacks',
    () async {
      final calls = <String>[];
      factory((message) {
        final request = (message as List).single as AndroidCreateRequest;
        expect(request.schemaMajor, 2);
        expect(request.options.audioPolicy, AndroidAudioPolicy.appManaged);
        return [wireCreate()];
      });
      host('attach', (_) async {
        calls.add('attach');
        // Receiving a callback from attach proves setup precedes the host call.
        expect(
          await callback('onState', wireState(revision: 1, sequence: 1)),
          isEmpty,
        );
        return [];
      });
      host('assess', (message) {
        final request = (message as List).single as AndroidAssessRequest;
        expect(request.source.kind, AndroidSourceKind.network);
        return [
          AndroidAssessmentReply(
            outcome: AndroidAssessmentOutcome.compatible,
            satisfiedRequirements: [],
            limitations: [],
          ),
        ];
      });
      host('load', (message) async {
        final request = (message as List).single as AndroidLoadRequest;
        expect(request.source.locator, 'https://media.test/a?token=secret');
        expect(request.options.videoConstraints.maxWidth, 1280);
        await callback(
          'onState',
          wireState(session: 's1', revision: 2, sequence: 2),
        );
        return [AndroidLoadReply(loadRequestId: 'load-1', sessionId: 's1')];
      });
      for (final method in ['play', 'pause', 'seekToLiveEdge']) {
        host(method, (message) {
          expect(
            ((message as List).single as AndroidSessionCommand).sessionId,
            's1',
          );
          calls.add(method);
          return [];
        });
      }
      host('seekTo', (message) {
        final command = (message as List).single as AndroidSeekCommand;
        expect(command.sessionId, 's1');
        expect(command.positionMs, 3000);
        calls.add('seekTo');
        return [];
      });
      host('setPlaybackSpeed', (message) {
        final command = (message as List).single as AndroidSpeedCommand;
        expect(command.sessionId, 's1');
        expect(command.speed, 1.25);
        calls.add('speed');
        return [];
      });
      host('selectAudioTrack', (message) {
        final command = (message as List).single as AndroidTrackCommand;
        expect(command.sessionId, 's1');
        expect(command.trackId, 'audio-main');
        calls.add('track');
        return [];
      });
      host('setVideoConstraints', (message) {
        final command =
            (message as List).single as AndroidVideoConstraintsCommand;
        expect(command.sessionId, 's1');
        expect(command.constraints.maxHeight, 720);
        calls.add('constraints');
        return [];
      });
      host('setVolume', (message) {
        expect((message as List).single, .5);
        calls.add('volume');
        return [];
      });
      host('stop', (_) {
        calls.add('stop');
        return [];
      });
      host('dispose', (_) {
        calls.add('dispose');
        return [];
      });
      final player = await YlPlayerAndroid().createPlayer(
        const YlPlayerOptions(),
      );
      final load = await player.load(
        source,
        options: const YlLoadOptions(
          videoConstraints: YlVideoConstraints(maxWidth: 1280),
        ),
      );
      await player.play(load.sessionId);
      await player.pause(load.sessionId);
      await player.seekTo(load.sessionId, const Duration(seconds: 3));
      await player.seekToLiveEdge(load.sessionId);
      await player.setPlaybackSpeed(load.sessionId, 1.25);
      await player.selectAudioTrack(load.sessionId, 'audio-main');
      await player.setVideoConstraints(
        load.sessionId,
        const YlVideoConstraints(maxHeight: 720),
      );
      await player.setVolume(.5);
      await player.stop();
      await player.dispose();
      expect(calls, [
        'attach',
        'play',
        'pause',
        'seekTo',
        'seekToLiveEdge',
        'speed',
        'track',
        'constraints',
        'volume',
        'stop',
        'dispose',
      ]);
      expect(await callback('onState', wireState()), isNull);
      expect(player.textureId.value, isNull);
    },
  );
  test(
    'production typed native rejection is safe; missing host is terminal',
    () async {
      factory((_) => [wireCreate()]);
      host('attach', (_) => []);
      host('dispose', (_) => []);
      host(
        'assess',
        (_) => [
          'native-failure',
          'secret',
          wireFailure(scope: AndroidFailureScope.command),
        ],
      );
      final player = await YlPlayerAndroid().createPlayer(
        const YlPlayerOptions(),
      );
      await expectLater(
        player.assess(source),
        throwsA(
          isA<YlPlayerException>()
              .having(
                (e) => e.failure.message,
                'message',
                'Playback operation failed.',
              )
              .having(
                (e) => e.failure.diagnosticId,
                'diagnosticId',
                'android-network-1',
              ),
        ),
      );
      // No setVolume host is registered: generated channel-error becomes terminal.
      await expectLater(
        player.setVolume(.5),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.platformUnavailable,
          ),
        ),
      );
      expect(player.state.failure!.scope, YlFailureScope.player);
      await player.dispose();
    },
  );
}
