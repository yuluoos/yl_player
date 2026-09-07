import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_channel.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('yl_player_platform_interface_test/methods');
  late StreamController<Object?> nativeEvents;
  late List<MethodCall> calls;
  PlatformException? commandError;
  bool failDispose = false;

  setUp(() {
    nativeEvents = StreamController<Object?>.broadcast(sync: true);
    calls = <MethodCall>[];
    commandError = null;
    failDispose = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
          calls.add(call);
          if (call.method == 'create') {
            return <String, Object?>{'playerId': 7, 'textureId': 42};
          }
          if (call.method == 'command' && commandError != null) {
            throw commandError!;
          }
          if (call.method == 'dispose' && failDispose) {
            throw PlatformException(code: 'dispose.failed');
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, null);
    if (!nativeEvents.isClosed) {
      await nativeEvents.close();
    }
  });

  YlChannelPlayer createPlayer({Stream<Object?>? stream}) => YlChannelPlayer(
    playerId: 7,
    initialTextureId: 42,
    methods: methods,
    nativeEvents: stream ?? nativeEvents.stream,
    platform: 'android',
    initialEngine: YlPlaybackEngine.media3,
  );

  test('command failure preserves native state and emits no event', () async {
    final player = createPlayer();
    final events = <YlPlayerEvent>[];
    final subscription = player.events.listen(events.add);
    nativeEvents.add(_stateEnvelope(generation: 8));
    commandError = PlatformException(
      code: 'decoder.unsupported',
      details: const <String, Object?>{
        'category': 'decoderUnsupported',
        'code': 'decoder.unsupported',
        'message': 'Unsupported stream.',
      },
    );

    await expectLater(
      player.play(),
      throwsA(
        isA<YlPlayerError>().having(
          (error) => error.code,
          'code',
          'decoder.unsupported',
        ),
      ),
    );

    expect(player.state.status, YlPlaybackStatus.playing);
    expect(player.state.error, isNull);
    expect(events, isEmpty);
    await subscription.cancel();
    await player.dispose();
  });

  test(
    'merges only deltas matching the current versioned generation',
    () async {
      final player = createPlayer();
      final states = <YlPlayerState>[];
      final subscription = player.states.listen(states.add);

      nativeEvents.add(_deltaEnvelope(generation: 8, positionMs: 100));
      expect(states, isEmpty);

      nativeEvents.add(_stateEnvelope(generation: 8));
      nativeEvents.add(_deltaEnvelope(generation: 8, positionMs: 2000));
      expect(player.state.position, const Duration(seconds: 2));
      expect(states, hasLength(2));

      nativeEvents.add(_deltaEnvelope(generation: 7, positionMs: 3000));
      nativeEvents.add(_deltaEnvelope(generation: 9, positionMs: 4000));
      expect(player.state.position, const Duration(seconds: 2));
      expect(states, hasLength(2));

      await subscription.cancel();
      await player.dispose();
    },
  );

  test('supports legacy snapshots but never applies deltas to them', () async {
    final player = createPlayer();
    final states = <YlPlayerState>[];
    final subscription = player.states.listen(states.add);

    nativeEvents.add(_stateEnvelope(generation: null, protocolVersion: null));
    nativeEvents.add(_deltaEnvelope(generation: 8, positionMs: 5000));

    expect(states, hasLength(1));
    expect(player.state.position, const Duration(milliseconds: 1500));
    await subscription.cancel();
    await player.dispose();
  });

  test('native error event does not perform the state transition', () async {
    final player = createPlayer();
    final states = <YlPlayerState>[];
    final events = <YlPlayerEvent>[];
    final stateSubscription = player.states.listen(states.add);
    final eventSubscription = player.events.listen(events.add);
    nativeEvents.add(_stateEnvelope(generation: 8));
    states.clear();

    nativeEvents.add(<String, Object?>{
      'playerId': 7,
      'type': 'error',
      'error': _errorMap('network.io'),
    });
    expect(player.state.status, YlPlaybackStatus.playing);
    expect(states, isEmpty);
    expect(events, hasLength(1));

    nativeEvents.add(
      _stateEnvelope(
        generation: 8,
        status: 'error',
        error: _errorMap('network.io'),
      ),
    );
    expect(player.state.status, YlPlaybackStatus.error);
    expect(player.state.error?.code, 'network.io');
    expect(states, hasLength(1));
    expect(events, hasLength(1));

    await stateSubscription.cancel();
    await eventSubscription.cancel();
    await player.dispose();
  });

  test(
    'native fallback activation marker does not terminate the channel',
    () async {
      final player = createPlayer();
      final states = <YlPlayerState>[];
      final events = <YlPlayerEvent>[];
      final stateSubscription = player.states.listen(states.add);
      final eventSubscription = player.events.listen(events.add);
      nativeEvents.add(_stateEnvelope(generation: 8));
      states.clear();

      nativeEvents.add(<String, Object?>{
        'playerId': 7,
        'type': 'fallbackActivated',
        'engine': 'nativeFallback',
      });

      expect(player.state.status, YlPlaybackStatus.playing);
      expect(player.state.error, isNull);
      expect(states, isEmpty);
      expect(events, isEmpty);

      nativeEvents.add(_stateEnvelope(generation: 9, status: 'paused'));
      nativeEvents.add(_deltaEnvelope(generation: 9, positionMs: 2500));
      expect(states, hasLength(2));
      expect(player.state.status, YlPlaybackStatus.paused);
      expect(player.state.position, const Duration(milliseconds: 2500));
      expect(player.state.error, isNull);
      expect(events, isEmpty);

      await stateSubscription.cancel();
      await eventSubscription.cancel();
      await player.dispose();
    },
  );

  test('stream error reports one terminal channel error', () async {
    final player = createPlayer();
    final states = <YlPlayerState>[];
    final events = <YlPlayerEvent>[];
    final stateSubscription = player.states.listen(states.add);
    final eventSubscription = player.events.listen(events.add);

    nativeEvents.addError(StateError('transport'));
    nativeEvents.addError(StateError('again'));
    await nativeEvents.close();

    expect(states, hasLength(1));
    expect(states.single.status, YlPlaybackStatus.error);
    expect(states.single.error?.code, 'channel.event_stream_error');
    expect(events, hasLength(1));
    expect(
      (events.single as YlErrorEvent).error.code,
      'channel.event_stream_error',
    );

    await stateSubscription.cancel();
    await eventSubscription.cancel();
    await player.dispose();
  });

  test('normal stream close reports one terminal channel error', () async {
    final player = createPlayer();
    final states = <YlPlayerState>[];
    final events = <YlPlayerEvent>[];
    final stateSubscription = player.states.listen(states.add);
    final eventSubscription = player.events.listen(events.add);

    await nativeEvents.close();

    expect(states, hasLength(1));
    expect(states.single.error?.code, 'channel.event_stream_done');
    expect(events, hasLength(1));
    expect(
      (events.single as YlErrorEvent).error.code,
      'channel.event_stream_done',
    );

    await stateSubscription.cancel();
    await eventSubscription.cancel();
    await player.dispose();
  });

  test(
    'malformed matching envelopes report once and other players are ignored',
    () async {
      final player = createPlayer();
      final events = <YlPlayerEvent>[];
      final subscription = player.events.listen(events.add);

      nativeEvents.add(<String, Object?>{'playerId': 999, 'type': 'unknown'});
      nativeEvents.add(<String, Object?>{
        'playerId': 7,
        'type': 'state',
        'state': 'not-a-map',
      });
      nativeEvents.add(<String, Object?>{'playerId': 7, 'type': 'unknown'});

      expect(events, hasLength(1));
      expect(
        (events.single as YlErrorEvent).error.code,
        'channel.event_malformed',
      );
      expect(player.state.status, YlPlaybackStatus.error);

      await subscription.cancel();
      await player.dispose();
    },
  );

  test('validates direct commands before invoking the backend', () async {
    final player = createPlayer();
    final commandCount = calls.length;

    expect(
      () => player.seekTo(const Duration(milliseconds: -1)),
      throwsArgumentError,
    );
    expect(() => player.setPlaybackSpeed(double.nan), throwsArgumentError);
    expect(() => player.setVolume(2), throwsArgumentError);
    expect(
      () => player.setQualityConstraint(const YlQualityConstraint(maxWidth: 0)),
      throwsArgumentError,
    );
    expect(calls, hasLength(commandCount));
    await player.dispose();
  });

  test(
    'factory validates configuration and preserves platform error codes',
    () async {
      await expectLater(
        createYlChannelPlayer(
          configuration: const YlPlayerConfiguration(
            positionEventInterval: Duration.zero,
          ),
          methods: methods,
          nativeEvents: nativeEvents.stream,
          platform: 'android',
          initialEngine: YlPlaybackEngine.media3,
        ),
        throwsArgumentError,
      );
      expect(calls, isEmpty);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            methods,
            (call) async => <String, Object?>{},
          );
      await expectLater(
        createYlChannelPlayer(
          configuration: const YlPlayerConfiguration(),
          methods: methods,
          nativeEvents: nativeEvents.stream,
          platform: 'android',
          initialEngine: YlPlaybackEngine.media3,
        ),
        throwsA(
          isA<YlPlayerError>().having(
            (error) => error.code,
            'code',
            'android.invalid_create_response',
          ),
        ),
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methods, (call) async {
            throw MissingPluginException('missing');
          });
      await expectLater(
        createYlChannelPlayer(
          configuration: const YlPlayerConfiguration(),
          methods: methods,
          nativeEvents: nativeEvents.stream,
          platform: 'ios',
          initialEngine: YlPlaybackEngine.avPlayer,
        ),
        throwsA(
          isA<YlPlayerError>().having(
            (error) => error.code,
            'code',
            'ios.plugin_unavailable',
          ),
        ),
      );
    },
  );

  test(
    'dispose is idempotent and closes locally after native failure',
    () async {
      final player = createPlayer();
      failDispose = true;

      await player.dispose();
      await player.dispose();
      nativeEvents.add(<String, Object?>{
        'playerId': 7,
        'type': 'error',
        'error': _errorMap('late.error'),
      });

      expect(player.state.status, YlPlaybackStatus.disposed);
      expect(player.textureId.value, isNull);
      expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
    },
  );
}

Map<String, Object?> _stateEnvelope({
  required int? generation,
  int? protocolVersion = 1,
  String status = 'playing',
  Object? error,
}) => <String, Object?>{
  'playerId': 7,
  'protocolVersion': ?protocolVersion,
  'generation': ?generation,
  'type': 'state',
  'state': <String, Object?>{
    'status': status,
    'positionMs': 1500,
    'bufferedPositionMs': 4000,
    'engine': 'media3',
    'error': ?error,
  },
};

Map<String, Object?> _deltaEnvelope({
  required int generation,
  required int positionMs,
}) => <String, Object?>{
  'playerId': 7,
  'protocolVersion': 1,
  'generation': generation,
  'type': 'stateDelta',
  'delta': <String, Object?>{
    'positionMs': positionMs,
    'bufferedPositionMs': positionMs + 1000,
  },
};

Map<String, Object?> _errorMap(String code) => <String, Object?>{
  'category': 'network',
  'code': code,
  'message': 'Playback failed.',
};
