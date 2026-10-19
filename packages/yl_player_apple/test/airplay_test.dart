import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_apple/src/apple_airplay.dart';
import 'package:yl_player_apple/src/apple_player.dart';
import 'package:yl_player_apple/src/pigeon/yl_player_apple.g.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'support/apple_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channel = BasicMessageChannel<Object?>(
    'dev.ylplayer.airplay.instance-1',
    ApplePlayerHostApi.pigeonChannelCodec,
  );
  Map<String, Object?> snapshot(
    int revision, {
    String? session,
    bool enabled = false,
    bool active = false,
  }) => {
    'version': 1,
    'revision': revision,
    'sessionId': session,
    'enabled': enabled,
    'active': active,
  };
  Future<void> event(Map<String, Object?> value) async {
    await messenger.handlePlatformMessage(
      'dev.ylplayer.airplay.events.instance-1',
      const StandardMessageCodec().encodeMessage(value),
      (_) {},
    );
  }

  Future<ApplePlayer> create(FakeTransport transport) => ApplePlayer.create(
    const YlPlayerOptions(),
    factory: FakeFactory(wireCreate()),
    transportForSuffix: (_) => transport,
    setupCallbacks: (_, api) => transport.callbacks = api,
    airPlayFactory: AppleAirPlayChannel.new,
  );
  tearDown(() => messenger.setMockDecodedMessageHandler(channel, null));

  Future<ApplePlayer> createActiveAirPlay(FakeTransport transport) async {
    var loads = 0;
    messenger.setMockDecodedMessageHandler(channel, (message) async {
      final request = message! as Map;
      switch (request['method']) {
        case 'state':
          return {'value': snapshot(0)};
        case 'assess':
          return {
            'value': AppleAssessmentReply(
              outcome: AppleAssessmentOutcome.compatible,
              candidateEngine: AppleEngine.avPlayer,
              satisfiedRequirements: [],
              limitations: [],
            ),
          };
        case 'load':
          final load = request['request'] as AppleLoadRequest;
          final ordinal = ++loads;
          final session = 's$ordinal';
          transport.callbacks!.onState(
            wireState(
              requestId: load.loadRequestId,
              session: session,
              revision: ordinal,
              sequence: ordinal,
            ),
          );
          await event(
            snapshot(ordinal, session: session, enabled: true, active: true),
          );
          return {
            'value': AppleLoadReply(
              loadRequestId: load.loadRequestId,
              sessionId: session,
            ),
          };
        default:
          throw StateError('Unexpected method');
      }
    });
    final player = await create(transport);
    await player.loadForAirPlay(source);
    return player;
  }

  test(
    'rejected Stop preserves AirPlay state and later route events',
    () async {
      final transport = FakeTransport();
      final player = await createActiveAirPlay(transport);
      transport.stopping = () async => throw PlatformException(
        code: 'command.failed',
        details: wireFailure(scope: AppleFailureScope.command),
      );
      await expectLater(player.stop(), throwsA(isA<YlPlayerException>()));
      expect(player.airPlayState.value.active, isTrue);
      expect(
        player.airPlayState.value.sessionId,
        const YlPlaybackSessionId('s1'),
      );
      await event(snapshot(2, session: 's1', enabled: true));
      expect(player.airPlayState.value.enabled, isTrue);
      expect(player.airPlayState.value.active, isFalse);
      await event(snapshot(3, session: 's1', enabled: true, active: true));
      expect(player.airPlayState.value.active, isTrue);
      await player.play(const YlPlaybackSessionId('s1'));
      await player.dispose();
    },
  );

  test('old Stop ACK cannot clear a newer committed AirPlay session', () async {
    final transport = FakeTransport();
    final player = await createActiveAirPlay(transport);
    final stopReply = Completer<void>();
    transport.stopping = () => stopReply.future;
    final stopping = player.stop();
    await flush();
    expect(player.airPlayState.value.active, isTrue);
    await player.loadForAirPlay(source);
    expect(
      player.airPlayState.value.sessionId,
      const YlPlaybackSessionId('s2'),
    );
    stopReply.complete();
    await stopping;
    expect(player.airPlayState.value.active, isTrue);
    expect(
      player.airPlayState.value.sessionId,
      const YlPlaybackSessionId('s2'),
    );
    await event(snapshot(3, session: 's2', enabled: true));
    expect(player.airPlayState.value.enabled, isTrue);
    expect(player.airPlayState.value.active, isFalse);
    await player.play(const YlPlaybackSessionId('s2'));
    await player.dispose();
  });

  test(
    'absent optional channel is unsupported and preserves regular operation',
    () async {
      final transport = FakeTransport();
      final player = await create(transport);
      expect(player.airPlayState.value.supported, isFalse);
      await expectLater(
        player.loadForAirPlay(source),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.policyUnsupported,
          ),
        ),
      );
      await commit(transport, player);
      expect(transport.calls, contains('load'));
      await player.dispose();
    },
  );

  test(
    'malformed negotiated state fails creation and releases native identity',
    () async {
      messenger.setMockDecodedMessageHandler(
        channel,
        (_) async => {'value': snapshot(-1)},
      );
      final transport = FakeTransport();
      await expectLater(
        create(transport),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.protocolMismatch,
          ),
        ),
      );
      expect(transport.calls, contains('dispose'));
    },
  );

  test(
    'channel failures are typed and diagnostic transport data is redacted',
    () async {
      messenger.setMockDecodedMessageHandler(channel, (message) async {
        if ((message! as Map)['method'] == 'state') {
          return {'value': snapshot(0)};
        }
        return {'error': wireFailure(scope: AppleFailureScope.command)};
      });
      final player = await create(FakeTransport());
      await expectLater(
        player.assess(source, options: const YlLoadOptions(airPlay: true)),
        throwsA(
          isA<YlPlayerException>()
              .having((e) => e.failure.code, 'code', 'network.failed')
              .having(
                (e) => e.toString(),
                'safe diagnostics',
                isNot(contains('token=secret')),
              ),
        ),
      );
      expect(player.airPlayState.value.supported, isTrue);
      await player.dispose();
    },
  );

  test(
    'malformed state event terminates the player without leaking the event',
    () async {
      messenger.setMockDecodedMessageHandler(
        channel,
        (_) async => {'value': snapshot(0)},
      );
      final player = await create(FakeTransport());
      await event(snapshot(1, active: true));
      expect(player.state.failure?.code, YlFailureCodes.protocolMismatch);
      await player.dispose();
      expect(player.airPlayState.value.supported, isFalse);
    },
  );

  test(
    'newer cleared route state cannot revive from a pre-ACK snapshot',
    () async {
      final reply = Completer<AppleLoadReply>();
      messenger.setMockDecodedMessageHandler(channel, (message) async {
        return switch ((message! as Map)['method']) {
          'state' => {'value': snapshot(0)},
          'assess' => {
            'value': AppleAssessmentReply(
              outcome: AppleAssessmentOutcome.compatible,
              candidateEngine: AppleEngine.avPlayer,
              satisfiedRequirements: [],
              limitations: [],
            ),
          },
          'load' => {'value': await reply.future},
          _ => throw StateError('Unexpected method'),
        };
      });
      final transport = FakeTransport();
      final player = await create(transport);
      final loading = player.loadForAirPlay(source);
      await flush();
      await event(snapshot(1, session: 's1', enabled: true, active: true));
      await event(snapshot(2));
      transport.callbacks!.onState(
        wireState(session: 's1', revision: 1, sequence: 1),
      );
      reply.complete(AppleLoadReply(loadRequestId: 'load-1', sessionId: 's1'));
      await loading;
      expect(player.airPlayState.value.enabled, isFalse);
      await event(snapshot(3, session: 's1', enabled: true, active: true));
      expect(player.airPlayState.value.active, isTrue);
      await player.stop();
      await event(snapshot(4, session: 's1', enabled: true, active: true));
      expect(player.airPlayState.value.enabled, isFalse);
      await player.dispose();
    },
  );

  test(
    'direct AirPlay load uses typed channel and retains ACK and stale-state barriers',
    () async {
      final methods = <String>[];
      AppleLoadRequest? loadRequest;
      final reply = Completer<AppleLoadReply>();
      messenger.setMockDecodedMessageHandler(channel, (message) async {
        final request = message! as Map;
        methods.add(request['method'] as String);
        return switch (request['method']) {
          'state' => {'value': snapshot(0)},
          'assess' => {
            'value': AppleAssessmentReply(
              outcome: AppleAssessmentOutcome.compatible,
              candidateEngine: AppleEngine.avPlayer,
              satisfiedRequirements: [],
              limitations: [],
            ),
          },
          'load' => await (() async {
            loadRequest = request['request'] as AppleLoadRequest;
            return {'value': await reply.future};
          })(),
          _ => throw StateError('Unexpected method'),
        };
      });
      final transport = FakeTransport();
      final player = await create(transport);
      final loading = player.load(
        source,
        options: const YlLoadOptions(airPlay: true),
      );
      var completed = false;
      unawaited(loading.then((_) => completed = true));
      await flush();
      expect(loadRequest, isNotNull);
      expect(transport.calls, isNot(contains('load')));
      await event(snapshot(1, session: 's1', enabled: true, active: true));
      expect(player.airPlayState.value.enabled, isFalse);
      transport.callbacks!.onState(
        wireState(session: 's1', revision: 1, sequence: 1),
      );
      await flush();
      expect(completed, isFalse);
      reply.complete(
        AppleLoadReply(
          loadRequestId: loadRequest!.loadRequestId,
          sessionId: 's1',
        ),
      );
      await loading;
      expect(player.airPlayState.value.active, isTrue);
      await event(snapshot(0));
      expect(player.airPlayState.value.active, isTrue);
      // Ordinary replacement must retire routing state even if the old native
      // session emits a newer sequence after the replacement ACK.
      await commit(transport, player, session: 's2', revision: 2, sequence: 2);
      await event(snapshot(2, session: 's1', enabled: true, active: true));
      expect(player.airPlayState.value.enabled, isFalse);
      await player.stop();
      expect(player.airPlayState.value.enabled, isFalse);
      await event(snapshot(3, session: 's2', enabled: true, active: true));
      expect(player.airPlayState.value.enabled, isFalse);
      await player.dispose();
      await event(snapshot(4, session: 's1', enabled: true, active: true));
      expect(player.airPlayState.value.enabled, isFalse);
      expect(methods, ['state', 'assess', 'load']);
    },
  );
}
