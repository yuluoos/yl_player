import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'package:yl_player_platform_interface/yl_player_legacy_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('legacy-test');
  late StreamController<Object?> wire;
  late List<MethodCall> calls;
  Object? createReply;
  Future<Object?> Function(MethodCall)? handler;
  Map<String, Object?> snapshot(
    int generation, {
    String status = 'idle',
    String engine = 'media3',
    int? loadToken,
  }) => {
    'playerId': 7,
    'type': 'state',
    'protocolVersion': 1,
    'generation': generation,
    'loadToken': loadToken,
    'state': {
      'status': status,
      'engine': engine,
      'capabilities': <String, Object?>{},
    },
  };
  Future<YlPlatformPlayer> create({
    YlPlayerOptions options = const YlPlayerOptions(),
  }) => createYlLegacyChannelPlayer(
    options: options,
    methods: methods,
    nativeEvents: wire.stream,
    platform: 'android',
    initialEngine: YlPlaybackEngine.media3,
    transportTimeout: const Duration(milliseconds: 100),
  );
  setUp(() {
    wire = StreamController<Object?>.broadcast(sync: true);
    calls = [];
    handler = null;
    createReply = {'playerId': 7, 'textureId': 42};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
          calls.add(call);
          if (call.method == 'create') return createReply;
          if (handler != null) return handler!(call);
          if (call.method == 'command' &&
              (call.arguments as Map)['name'] == 'requestState') {
            wire.add(snapshot(0));
          }
          return null;
        });
  });
  tearDown(() async {
    await wire.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, null);
  });
  Matcher failure(String code) => throwsA(
    isA<YlPlayerException>().having((e) => e.failure.code, 'code', code),
  );
  for (final lateError in [false, true]) {
    test(
      'timed out create consumes late ${lateError ? 'error' : 'identity'}',
      () async {
        final reply = Completer<Object?>();
        createReply = reply.future;
        final cleanup = Completer<Object?>();
        handler = (_) => cleanup.future;
        await expectLater(create(), failure(YlFailureCodes.protocolMismatch));
        expect(calls.where((c) => c.method == 'dispose'), isEmpty);
        if (lateError) {
          reply.completeError(PlatformException(code: 'late.create.error'));
        } else {
          reply.complete({'playerId': 7, 'textureId': 42});
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(
          calls.where((c) => c.method == 'dispose').map((c) => c.arguments),
          lateError
              ? isEmpty
              : [
                  {'playerId': 7},
                ],
        );
        expect(calls.where((c) => c.method == 'command'), isEmpty);
        if (calls.any((c) => c.method == 'dispose')) {
          cleanup.completeError(PlatformException(code: 'late.dispose.error'));
        }
        await Future<void>.delayed(Duration.zero);
      },
    );
  }
  test(
    'malformed create cleanup nonreply cannot hide creation failure',
    () async {
      createReply = {'playerId': 7, 'textureId': null};
      final cleanup = Completer<Object?>();
      handler = (_) => cleanup.future;
      await expectLater(
        create().timeout(const Duration(milliseconds: 350)),
        failure(YlFailureCodes.protocolMismatch),
      );
      expect(calls.where((c) => c.method == 'dispose'), hasLength(1));
      cleanup.complete(null);
    },
  );
  test(
    'accepted Stop fences commands and late events before authoritative idle',
    () async {
      final player = await create();
      wire.add(snapshot(3, status: 'playing'));
      final before = player.state;
      final events = <YlPlayerEvent>[];
      player.events.listen(events.add);
      await player.stop();
      await expectLater(
        player.play(before.sessionId!),
        failure(YlFailureCodes.sessionStale),
      );
      expect(
        calls.where(
          (c) => c.method == 'command' && c.arguments['name'] == 'play',
        ),
        isEmpty,
      );
      for (final type in ['firstFrame', 'retry', 'error']) {
        wire.add({'playerId': 7, 'type': type, 'generation': 3});
      }
      expect(events, isEmpty);
      expect(player.state, before);
      wire.add(snapshot(4));
      expect(player.state.status, YlPlaybackStatus.idle);
      await player.dispose();
    },
  );
  test('rejected Stop retains healthy session and pending events', () async {
    final player = await create();
    wire.add(snapshot(3, status: 'playing'));
    final before = player.state;
    final events = <YlPlayerEvent>[];
    player.events.listen(events.add);
    handler = (call) async {
      if (call.method == 'command' && call.arguments['name'] == 'stop') {
        throw PlatformException(code: 'command.rejected');
      }
      return null;
    };
    await expectLater(player.stop(), throwsA(isA<YlPlayerException>()));
    await player.play(before.sessionId!);
    wire.add({'playerId': 7, 'type': 'firstFrame', 'generation': 3});
    expect(events.whereType<YlFirstFrameEvent>(), hasLength(1));
    expect(player.state, before);
    await player.dispose();
  });
  test('older Stop reply does not fence newer committed Load', () async {
    final player = await create();
    wire.add(snapshot(3, status: 'playing'));
    final stopReply = Completer<Object?>();
    handler = (call) async {
      if (call.method == 'command' && call.arguments['name'] == 'stop') {
        return stopReply.future;
      }
      if (call.method == 'command' && call.arguments['name'] == 'open') {
        final token = call.arguments['arguments']['source']['loadToken'];
        wire.add(snapshot(4, status: 'loading', loadToken: token as int));
        return {'loadToken': token};
      }
      return null;
    };
    final stopping = player.stop();
    final newer = await player.load(
      YlNetworkSource(Uri.parse('https://example.test/a')),
    );
    stopReply.complete(null);
    await stopping;
    await player.play(newer.sessionId);
    final events = <YlPlayerEvent>[];
    player.events.listen(events.add);
    wire.add({'playerId': 7, 'type': 'firstFrame', 'generation': 4});
    expect(events.whereType<YlFirstFrameEvent>(), hasLength(1));
    await player.dispose();
  });
  test('settled commands release their cancellation registrations', () async {
    final player = await create();
    for (var i = 0; i < 32; i++) {
      await player.setVolume(i / 32);
    }
    expect((player as dynamic).debugPendingCommandCount, 0);
    handler = (_) async => throw PlatformException(code: 'command.rejected');
    await expectLater(player.setVolume(.5), throwsA(isA<YlPlayerException>()));
    expect((player as dynamic).debugPendingCommandCount, 0);
    await player.dispose();
  });
  test('termination removes only pending command registrations', () async {
    final player = await create();
    final reply = Completer<Object?>();
    handler = (call) async => call.method == 'command' ? reply.future : null;
    final pending = expectLater(
      player.setVolume(.5).timeout(const Duration(milliseconds: 300)),
      failure(YlFailureCodes.protocolMismatch),
    );
    await Future<void>.delayed(Duration.zero);
    expect((player as dynamic).debugPendingCommandCount, 1);
    wire.addError(StateError('transport lost'));
    await pending;
    expect((player as dynamic).debugPendingCommandCount, 0);
    reply.completeError(PlatformException(code: 'late.native.error'));
    await Future<void>.delayed(Duration.zero);
    await player.dispose();
  });
  test(
    'Stop cancels a Load still awaiting assessment without a microtask drain',
    () async {
      final player = await create();
      wire.add(snapshot(1, status: 'playing'));
      handler = (call) async {
        if (call.method == 'command' && call.arguments['name'] == 'stop') {
          wire.add(snapshot(2));
        }
        if (call.method == 'command' && call.arguments['name'] == 'open') {
          wire.add(snapshot(3, status: 'loading', loadToken: 1));
          return {'loadToken': 1};
        }
        return null;
      };
      final loading = player.load(
        YlNetworkSource(Uri.parse('https://example.test/a')),
      );
      final stopping = player.stop();
      await expectLater(loading, failure(YlFailureCodes.loadCancelled));
      await stopping;
      expect(
        calls.where(
          (c) => c.method == 'command' && c.arguments['name'] == 'open',
        ),
        isEmpty,
      );
      expect(player.state.sessionId, isNull);
      await player.dispose();
    },
  );
  for (final texture in [null, 'invalid', -1]) {
    test(
      'allocated native ID is released for invalid texture $texture',
      () async {
        createReply = {'playerId': 7, 'textureId': texture};
        handler = (_) async => throw PlatformException(code: 'dispose.failed');
        await expectLater(create(), failure(YlFailureCodes.protocolMismatch));
        expect(
          calls.where((c) => c.method == 'dispose').map((c) => c.arguments),
          [
            {'playerId': 7},
          ],
        );
      },
    );
  }
  test(
    'allocated native ID is released if subscription attachment throws',
    () async {
      await expectLater(
        createYlLegacyChannelPlayer(
          options: const YlPlayerOptions(),
          methods: methods,
          nativeEvents: _ThrowingListenStream(),
          platform: 'android',
          initialEngine: YlPlaybackEngine.media3,
        ),
        failure(YlFailureCodes.protocolMismatch),
      );
      expect(calls.where((c) => c.method == 'dispose'), hasLength(1));
      expect(calls.last.arguments, {'playerId': 7});
    },
  );
  test('paused SPI observer cannot prevent terminal native release', () async {
    final player = await create();
    final observer = player.states.listen((_) {});
    observer.pause();
    wire.add(snapshot(3, status: 'loading'));
    wire.addError(StateError('transport gone'));
    try {
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method == 'dispose'), hasLength(1));
      await player.dispose().timeout(const Duration(milliseconds: 100));
    } finally {
      await observer.cancel();
      await player.dispose();
    }
  });
  for (final close in [false, true]) {
    test(
      'established transport ${close ? 'close' : 'error'} releases ownership without invented state',
      () async {
        final player = await create();
        final reply = Completer<Object?>();
        handler = (call) async {
          if (call.method == 'command' && call.arguments['name'] == 'open') {
            wire.add(snapshot(3, status: 'loading', loadToken: 1));
            return {'loadToken': 1};
          }
          if (call.method == 'command') return reply.future;
          return null;
        };
        final loaded = await player.load(
          YlNetworkSource(Uri.parse('https://example.test/a')),
        );
        final before = player.state;
        final states = <YlPlayerState>[];
        final events = <YlPlayerEvent>[];
        player.states.listen(states.add);
        player.events.listen(events.add);
        final pending = expectLater(
          player.setVolume(.5).timeout(const Duration(milliseconds: 300)),
          failure(YlFailureCodes.protocolMismatch),
        );
        if (close) {
          await wire.close();
        } else {
          wire.addError(StateError('secret native details'));
        }
        await pending;
        await Future<void>.delayed(Duration.zero);
        expect(player.state, before);
        expect(states, isEmpty);
        expect(events, isEmpty);
        expect(player.textureId.value, isNull);
        await expectLater(
          player.play(loaded.sessionId),
          failure(YlFailureCodes.playerDisposed),
        );
        expect(calls.where((c) => c.method == 'dispose'), hasLength(1));
        reply.complete(null);
        await player.dispose();
      },
    );
    for (final stateFirst in [false, true]) {
      test(
        'transport ${close ? 'close' : 'error'} terminates ${stateFirst ? 'state' : 'reply'} pairing gap',
        () async {
          final player = await create();
          final reply = Completer<Object?>();
          handler = (call) async {
            if (call.method == 'command' && call.arguments['name'] == 'open') {
              if (stateFirst) {
                wire.add(snapshot(3, status: 'loading', loadToken: 1));
                return reply.future;
              }
              return {'loadToken': 1};
            }
            return null;
          };
          final loading = expectLater(
            player.load(YlNetworkSource(Uri.parse('https://example.test/a'))),
            failure(YlFailureCodes.protocolMismatch),
          );
          await Future<void>.delayed(Duration.zero);
          if (close) {
            await wire.close();
          } else {
            wire.addError(StateError('wire failed'));
          }
          await loading;
          await Future<void>.delayed(Duration.zero);
          expect(calls.where((c) => c.method == 'dispose'), hasLength(1));
          expect(player.textureId.value, isNull);
          await expectLater(
            player.setVolume(.2),
            failure(YlFailureCodes.playerDisposed),
          );
          reply.complete({'loadToken': 1});
          await player.dispose();
        },
      );
    }
  }
  test(
    'committed state without open reply times out and terminates transport',
    () async {
      final player = await create();
      final reply = Completer<Object?>();
      handler = (call) async {
        if (call.method == 'command' && call.arguments['name'] == 'open') {
          wire.add(snapshot(3, status: 'loading', loadToken: 1));
          return reply.future;
        }
        return null;
      };
      await expectLater(
        player.load(YlNetworkSource(Uri.parse('https://example.test/a'))),
        failure(YlFailureCodes.protocolMismatch),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method == 'dispose'), hasLength(1));
      reply.complete({'loadToken': 1});
      await player.dispose();
    },
  );
  test(
    'create awaits a first full capability snapshot on shared stream',
    () async {
      final peer = wire.stream.listen((_) {});
      final player = await create();
      expect(player.state.status, YlPlaybackStatus.idle);
      expect(player.capabilities.deviceProfile, 'legacy.android');
      expect(calls.last.arguments['name'], 'requestState');
      await player.dispose();
      await peer.cancel();
    },
  );
  test('missing initial state times out and disposes', () async {
    handler = (_) async => null;
    await expectLater(create(), failure(YlFailureCodes.protocolMismatch));
    expect(calls.last.method, 'dispose');
  });
  test('invalid protocol rejects and disposes', () async {
    handler = (call) async {
      wire.add({...snapshot(0), 'protocolVersion': 2});
      return null;
    };
    await expectLater(create(), failure(YlFailureCodes.protocolMismatch));
    expect(calls.last.method, 'dispose');
  });
  test('first full state must contain its capability snapshot', () async {
    handler = (call) async {
      if (call.method == 'command') {
        wire.add({
          ...snapshot(0),
          'state': {'status': 'idle', 'engine': 'media3'},
        });
      }
      return null;
    };
    await expectLater(create(), failure(YlFailureCodes.protocolMismatch));
    expect(calls.last.method, 'dispose');
  });
  test(
    'mismatched successful open reply terminates damaged transport',
    () async {
      final player = await create();
      handler = (call) async {
        if (call.method == 'command' && call.arguments['name'] == 'open') {
          wire.add(snapshot(3, status: 'loading', loadToken: 1));
          return {'loadToken': 999};
        }
        return null;
      };
      await expectLater(
        player.load(YlNetworkSource(Uri.parse('https://example.test/a'))),
        failure(YlFailureCodes.protocolMismatch),
      );
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        player.setVolume(.5),
        failure(YlFailureCodes.playerDisposed),
      );
      expect(calls.any((call) => call.method == 'dispose'), isTrue);
      await player.dispose();
    },
  );
  test(
    'two player identities share events without consuming each other snapshots',
    () async {
      var nextId = 6;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methods, (call) async {
            calls.add(call);
            if (call.method == 'create') {
              return {'playerId': ++nextId, 'textureId': nextId + 100};
            }
            if (call.method == 'command' &&
                call.arguments['name'] == 'requestState') {
              wire.add({
                ...snapshot(0),
                'playerId': call.arguments['playerId'],
              });
            }
            return null;
          });
      final first = await create();
      final second = await create();
      wire.add({...snapshot(3, status: 'playing'), 'playerId': 8});
      expect(first.state.status, YlPlaybackStatus.idle);
      expect(
        second.state.sessionId,
        const YlPlaybackSessionId('legacy:android:8:3'),
      );
      await first.dispose();
      wire.add({...snapshot(3, status: 'paused'), 'playerId': 8});
      expect(second.state.status, YlPlaybackStatus.paused);
      await second.dispose();
    },
  );
  test('pluginManaged is rejected without native create', () async {
    await expectLater(
      create(
        options: const YlPlayerOptions(
          audioPolicy: YlAudioPolicy.pluginManagedMediaPlayback,
        ),
      ),
      failure(YlFailureCodes.policyUnsupported),
    );
    expect(calls, isEmpty);
  });
  for (final stateFirst in [true, false]) {
    test(
      'load waits for reply and correlated state: stateFirst=$stateFirst',
      () async {
        final player = await create();
        final reply = Completer<Object?>();
        handler = (call) =>
            call.method == 'command' && call.arguments['name'] == 'open'
            ? reply.future
            : Future.value();
        final loading = player.load(
          YlNetworkSource(Uri.parse('https://example.test/video.mp4')),
        );
        var completed = false;
        loading.then((_) => completed = true);
        await Future<void>.delayed(Duration.zero);
        if (stateFirst) {
          wire.add(snapshot(3, status: 'loading', loadToken: 1));
        } else {
          reply.complete({'loadToken': 1});
        }
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);
        if (stateFirst) {
          reply.complete({'loadToken': 1});
        } else {
          wire.add(snapshot(3, status: 'loading', loadToken: 1));
        }
        final result = await loading;
        expect(
          result.sessionId,
          const YlPlaybackSessionId('legacy:android:7:3'),
        );
        await player.play(result.sessionId);
        await player.dispose();
      },
    );
  }
  test(
    'older committed state and reply cannot satisfy newer load token',
    () async {
      final player = await create();
      final replies = <int, Completer<Object?>>{};
      handler = (call) async {
        if (call.method == 'command' && call.arguments['name'] == 'open') {
          final token =
              call.arguments['arguments']['source']['loadToken'] as int;
          final reply = Completer<Object?>();
          replies[token] = reply;
          return reply.future;
        }
        return null;
      };
      final first = player.load(
        YlNetworkSource(Uri.parse('https://example.test/a')),
      );
      final cancelled = expectLater(
        first,
        failure(YlFailureCodes.loadCancelled),
      );
      await Future<void>.delayed(Duration.zero);
      final next = player.load(
        YlNetworkSource(Uri.parse('https://example.test/b')),
      );
      await Future<void>.delayed(Duration.zero);
      await cancelled;
      var completed = false;
      next.then((_) => completed = true);
      replies[2]!.complete({'loadToken': 2});
      wire.add(snapshot(3, status: 'loading', loadToken: 1));
      replies[1]!.complete({'loadToken': 1});
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      wire.add(snapshot(4, status: 'loading', loadToken: 2));
      expect(
        (await next).sessionId,
        const YlPlaybackSessionId('legacy:android:7:4'),
      );
      await player.dispose();
    },
  );
  test('preparation does not inherit the transport pairing timeout', () async {
    final player = await create();
    final reply = Completer<Object?>();
    handler = (call) =>
        call.arguments['name'] == 'open' ? reply.future : Future.value();
    var finished = false;
    final load = player.load(
      YlNetworkSource(Uri.parse('https://example.test/a')),
    );
    final observed = load.then<Object?>(
      (value) {
        finished = true;
        return value;
      },
      onError: (Object error) {
        finished = true;
        return error;
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(finished, isFalse);
    wire.add(snapshot(3, status: 'loading', loadToken: 1));
    reply.complete({'loadToken': 1});
    expect(await observed, isA<YlPlatformLoadResult>());
    await player.dispose();
  });
  test(
    'missing state after successful reply terminates damaged transport',
    () async {
      final player = await create();
      handler = (call) async =>
          call.arguments['name'] == 'open' ? {'loadToken': 1} : null;
      await expectLater(
        player.load(YlNetworkSource(Uri.parse('https://example.test/a'))),
        failure(YlFailureCodes.protocolMismatch),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls.any((call) => call.method == 'dispose'), isTrue);
      final before = player.state;
      wire.add(snapshot(3, status: 'loading', loadToken: 1));
      expect(player.state, before);
      await player.dispose();
    },
  );
  test(
    'new strict-incompatible load still cancels the older native candidate',
    () async {
      final player = await create();
      final reply = Completer<Object?>();
      handler = (call) async =>
          call.arguments['name'] == 'open' ? reply.future : null;
      final first = player.load(
        YlNetworkSource(Uri.parse('https://example.test/a')),
      );
      final cancelled = expectLater(
        first,
        failure(YlFailureCodes.loadCancelled),
      );
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        player.load(
          YlNetworkSource(Uri.parse('https://example.test/b')),
          options: const YlLoadOptions(
            decoderPolicyOverride: YlDecoderPolicy.hardwareRequired,
          ),
        ),
        failure(YlFailureCodes.policyUnsupported),
      );
      await cancelled;
      expect(
        calls
            .where(
              (call) =>
                  call.method == 'command' &&
                  call.arguments['name'] == 'cancelOpen',
            )
            .single
            .arguments['arguments']['loadToken'],
        1,
      );
      reply.complete({'loadToken': 1});
      await player.dispose();
    },
  );
  test('strict policies assess incompatible and never open', () async {
    final player = await create();
    final source = YlNetworkSource(Uri.parse('https://example.test/a'));
    for (final options in [
      const YlLoadOptions(
        decoderPolicyOverride: YlDecoderPolicy.hardwareRequired,
      ),
      const YlLoadOptions(
        bufferStrategy: YlBufferStrategy.bounded(
          minDuration: Duration.zero,
          maxDuration: Duration(seconds: 1),
          maxManagedBytes: 10,
        ),
      ),
    ]) {
      expect(
        (await player.assess(source, options: options)).outcome,
        YlSourceAssessmentOutcome.incompatible,
      );
      await expectLater(
        player.load(source, options: options),
        failure(YlFailureCodes.policyUnsupported),
      );
    }
    final managed = YlNetworkSource(
      source.uri,
      networkPolicy: const YlNetworkPolicy.managed(),
    );
    await expectLater(
      player.load(managed),
      failure(YlFailureCodes.policyUnsupported),
    );
    expect(
      calls.where(
        (c) => c.method == 'command' && c.arguments['name'] == 'open',
      ),
      isEmpty,
    );
    await player.dispose();
  });
  test(
    'native fallback activation marker does not terminate the channel',
    () async {
      final player = await create();
      final events = <YlPlayerEvent>[];
      player.events.listen(events.add);
      wire.add(snapshot(3, status: 'playing'));
      wire.add({'playerId': 7, 'type': 'fallbackActivated'});
      expect(events, isEmpty);
      wire.add(snapshot(3, status: 'playing', engine: 'nativeFallback'));
      wire.add({
        'playerId': 7,
        'type': 'stateDelta',
        'protocolVersion': 1,
        'generation': 3,
        'delta': {'positionMs': 20},
      });
      await Future<void>.delayed(Duration.zero);
      expect(player.state.timeline.position, const Duration(milliseconds: 20));
      expect(events.single, isA<YlPlaybackEngineChangedEvent>());
      await player.dispose();
    },
  );
  test('stale state and events ignored; current events correlated', () async {
    final player = await create();
    wire.add(snapshot(3, status: 'playing'));
    final events = <YlPlayerEvent>[];
    player.events.listen(events.add);
    final revision = player.state.revision;
    wire.add(snapshot(2, status: 'playing'));
    wire.add({'playerId': 7, 'type': 'firstFrame', 'generation': 2});
    expect(player.state.revision, revision);
    wire.add({'playerId': 7, 'type': 'firstFrame'});
    wire.add({
      'playerId': 7,
      'type': 'retry',
      'attempt': 1,
      'delayMs': 10,
      'error': {'code': 'network.failed'},
    });
    wire.add({
      'playerId': 7,
      'type': 'error',
      'error': {'code': 'network.failed'},
    });
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(3));
    expect(events.every((e) => e.sessionId == player.state.sessionId), isTrue);
    await player.dispose();
  });
  test(
    'command failure is safe and never changes authoritative state',
    () async {
      final player = await create();
      wire.add(snapshot(3, status: 'playing'));
      final before = player.state;
      handler = (_) async => throw PlatformException(
        code: 'broken',
        message: 'https://secret.test/?token=supersecret',
        details: {'platformDiagnostic': 'supersecret'},
      );
      await expectLater(
        player.play(before.sessionId!),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.toString(),
            'safe',
            isNot(contains('supersecret')),
          ),
        ),
      );
      expect(player.state, before);
      await player.dispose();
    },
  );
  test(
    'stop clears session only at authoritative idle; dispose is identical',
    () async {
      final player = await create();
      wire.add(snapshot(3, status: 'playing'));
      final id = player.state.sessionId;
      await player.stop();
      expect(player.state.sessionId, id);
      wire.add(snapshot(4));
      expect(player.state.sessionId, isNull);
      await expectLater(player.play(id!), failure(YlFailureCodes.sessionStale));
      final first = player.dispose();
      expect(identical(first, player.dispose()), isTrue);
      await first;
    },
  );
}

final class _ThrowingListenStream extends Stream<Object?> {
  @override
  StreamSubscription<Object?> listen(
    void Function(Object?)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => throw StateError('listen failed');
}
