import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_cast/yl_player_cast.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import '../../yl_player/test/support/fake_player_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const device = YlCastDevice(id: 'one', providerId: 'fake', name: 'TV');
  final source = YlNetworkSource(Uri.parse('https://media.invalid/a.mp4'));
  test(
    'discovery exposes asynchronous failure and clears it on retry',
    () async {
      final provider = FakeProvider();
      final controller = YlCastController(providers: [provider]);
      addTearDown(controller.dispose);
      expect(controller.discovery.value['fake']!.scanning, isFalse);
      await controller.startDiscovery();
      expect(controller.discovery.value['fake']!.scanning, isTrue);
      provider.discovery.value = const YlCastDiscoveryState(
        failureCode: 'cast.discovery_unavailable',
      );
      expect(
        controller.discovery.value['fake']!.failureCode,
        'cast.discovery_unavailable',
      );
      await controller.startDiscovery();
      expect(controller.discovery.value['fake']!.failureCode, isNull);
      await controller.stopDiscovery();
      expect(controller.discovery.value['fake']!.scanning, isFalse);
      expect(() => controller.discovery.value.clear(), throwsUnsupportedError);
    },
  );
  test('snapshot capabilities follow the active session', () async {
    final provider = FakeProvider();
    final controller = YlCastController(providers: [provider]);
    addTearDown(controller.dispose);
    expect(controller.state.value.capabilities, isNull);
    await controller.cast(device, source);
    expect(controller.state.value.capabilities!.pause, isTrue);
    provider.session.capabilities = const YlCastCapabilities(
      volume: true,
      canDetachKeepingPlayback: false,
    );
    provider.session.state.value = const YlCastPlaybackState(
      status: YlCastPlaybackStatus.playing,
    );
    expect(controller.state.value.capabilities!.pause, isFalse);
    expect(controller.state.value.capabilities!.volume, isTrue);
    expect(controller.state.value.canDetachKeepingPlayback, isFalse);
    await controller.stop();
    expect(controller.state.value.capabilities, isNull);
  });
  test('unknown format capability rejects before connection', () async {
    final provider = FakeProvider()..support = YlCastSupport.unknown;
    final controller = YlCastController(providers: [provider]);
    await expectLater(
      controller.cast(device, source),
      throwsA(isA<YlCastException>()),
    );
    expect(provider.connections, 0);
    await controller.dispose();
  });
  test('credentials never become receiver request metadata', () async {
    final provider = FakeProvider();
    final controller = YlCastController(providers: [provider]);
    final protected = YlNetworkSource(
      source.uri,
      request: YlHttpRequest(credentials: {'Authorization': 'secret'}),
    );
    await expectLater(
      controller.cast(device, protected),
      throwsA(
        isA<YlCastException>().having(
          (e) => e.code,
          'code',
          'cast.headers_unsupported',
        ),
      ),
    );
    expect(provider.connections, 0);
    await controller.dispose();
  });
  test(
    'commands are serialized; dispose releases only owned session',
    () async {
      final provider = FakeProvider();
      final controller = YlCastController(providers: [provider]);
      await controller.cast(device, source);
      final session = provider.session;
      session.pauseGate = Completer<void>();
      final pause = controller.pause();
      final play = controller.play();
      await Future<void>.delayed(Duration.zero);
      expect(session.commands, ['load', 'play', 'pause']);
      session.pauseGate!.complete();
      await Future.wait([pause, play]);
      expect(session.commands.last, 'play');
      await controller.dispose();
      expect(session.commands.sublist(session.commands.length - 2), [
        'stop',
        'dispose',
      ]);
      expect(provider.disposed, isTrue);
    },
  );
  test('cancelled load cannot publish a late session', () async {
    final provider = FakeProvider();
    provider.session.loadGate = Completer<void>();
    final controller = YlCastController(providers: [provider]);
    final started = controller.cast(device, source);
    final rejected = expectLater(started, throwsA(isA<YlCastException>()));
    await provider.session.loadStarted.future;
    await controller.cancelPending();
    provider.session.loadGate!.complete();
    await rejected;
    expect(controller.state.value.device, isNull);
    expect(provider.session.commands, ['load', 'stop', 'dispose']);
    await controller.dispose();
  });
  test(
    'direct URL detach releases control without stopping receiver',
    () async {
      final provider = FakeProvider();
      final controller = YlCastController(providers: [provider]);
      await controller.cast(device, source);
      await controller.disconnect(keepPlaying: true);
      expect(provider.session.commands, [
        'load',
        'play',
        'disconnect',
        'dispose',
      ]);
      expect(controller.state.value.device, isNull);
      await controller.dispose();
    },
  );
  test('remote load failure does not pause or dispose local player', () async {
    final backend = FakePlatformPlayer();
    final player = await YlPlayerController.create(
      platform: FakePlayerPlatform(backend),
    );
    final loading = player.load(source);
    backend.commit(const YlPlaybackSessionId('local'));
    final local = await loading;
    backend.emit(status: YlPlaybackStatus.playing);
    final provider = FakeProvider();
    provider.session.loadError = const YlCastException('cast.remote_failure');
    final controller = YlCastController(providers: [provider], player: player);
    await expectLater(
      controller.cast(
        device,
        source,
        handoff: YlCastHandoff(session: local, source: source),
      ),
      throwsA(isA<YlCastException>()),
    );
    expect(backend.calls.where((call) => call == 'pause'), isEmpty);
    expect(backend.disposeCount, 0);
    await controller.dispose();
    expect(backend.disposeCount, 0);
    await player.dispose();
  });
  test(
    'handoff pauses only after load acknowledgement and rolls back cancelled play',
    () async {
      final backend = FakePlatformPlayer();
      final player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
      );
      final loading = player.load(source);
      backend.commit(const YlPlaybackSessionId('local'));
      final local = await loading;
      backend.emit(status: YlPlaybackStatus.playing);
      final provider = FakeProvider();
      provider.session.loadGate = Completer<void>();
      provider.session.playGate = Completer<void>();
      final controller = YlCastController(
        providers: [provider],
        player: player,
      );
      final casting = controller.cast(
        device,
        source,
        handoff: YlCastHandoff(session: local, source: source),
      );
      final rejected = expectLater(casting, throwsA(isA<YlCastException>()));
      await provider.session.loadStarted.future;
      expect(backend.calls, isNot(contains('pause')));
      provider.session.loadGate!.complete();
      await provider.session.playStarted.future;
      expect(backend.calls, contains('pause'));
      await controller.cancelPending();
      provider.session.playGate!.complete();
      await rejected;
      expect(backend.calls.last, 'play');
      await controller.dispose();
      await player.dispose();
    },
  );
  test(
    'AirPlay activation rejects cast and external route conflict is observable',
    () async {
      final backend = CastPlayer();
      final player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
      );
      final loading = player.load(source);
      backend.commit(const YlPlaybackSessionId('local'));
      await loading;
      final provider = FakeProvider();
      final controller = YlCastController(
        providers: [provider],
        player: player,
      );
      backend.airPlayState.value = const YlAirPlayState(
        supported: true,
        enabled: true,
        active: true,
        sessionId: YlPlaybackSessionId('local'),
      );
      await expectLater(
        controller.cast(device, source),
        throwsA(
          isA<YlCastException>().having(
            (e) => e.code,
            'code',
            'cast.route_conflict',
          ),
        ),
      );
      expect(provider.connections, 0);
      backend.airPlayState.value = const YlAirPlayState(supported: true);
      await controller.cast(device, source);
      backend.airPlayState.value = const YlAirPlayState(
        supported: true,
        enabled: true,
        active: true,
        sessionId: YlPlaybackSessionId('local'),
      );
      expect(controller.state.value.routeConflict, isTrue);
      expect(provider.session.commands, isNot(contains('stop')));
      await controller.dispose();
      await player.dispose();
    },
  );
  test('hosted lease cannot detach and is released on stop', () async {
    final backend = CastPlayer();
    final player = await YlPlayerController.create(
      platform: FakePlayerPlatform(backend),
    );
    final provider = FakeProvider();
    final controller = YlCastController(providers: [provider], player: player);
    await controller.cast(
      device,
      YlNetworkSource(Uri.parse('rtmps://live.invalid/app/stream')),
    );
    expect(controller.state.value.hostedMedia, isTrue);
    expect(controller.state.value.capabilities!.seek, isFalse);
    expect(
      controller.state.value.capabilities!.canDetachKeepingPlayback,
      isFalse,
    );
    expect(controller.state.value.canDetachKeepingPlayback, isFalse);
    expect(provider.session.request!.requiresHlsFmp4, isTrue);
    await expectLater(
      controller.disconnect(keepPlaying: true),
      throwsA(
        isA<YlCastException>().having(
          (e) => e.code,
          'code',
          'cast.detach_unsupported',
        ),
      ),
    );
    expect(backend.lease.disposed, isFalse);
    await controller.stop();
    expect(backend.lease.disposed, isTrue);
    await controller.dispose();
    await player.dispose();
  });
  test('lease terminal failure stops receiver and releases media', () async {
    final backend = CastPlayer();
    final player = await YlPlayerController.create(
      platform: FakePlayerPlatform(backend),
    );
    final provider = FakeProvider();
    final controller = YlCastController(providers: [provider], player: player);
    await controller.cast(
      device,
      YlNetworkSource(Uri.parse('rtmps://live.invalid/app/stream')),
    );
    backend.lease.state.value = const YlMediaDeliveryState(
      status: YlMediaDeliveryStatus.failed,
    );
    await Future<void>.delayed(Duration.zero);
    expect(provider.session.commands, contains('stop'));
    expect(backend.lease.disposed, isTrue);
    expect(controller.state.value.failureCode, 'cast.delivery_failed');
    await controller.dispose();
    await player.dispose();
  });
  test('queued discovery cancelled in same tick never starts', () async {
    final provider = FakeProvider();
    final controller = YlCastController(providers: [provider]);
    final start = controller.startDiscovery();
    await controller.stopDiscovery();
    await start;
    expect(provider.discoveryStarts, 0);
    await controller.dispose();
  });
  test('failed Stop clears snapshot and still disposes session', () async {
    final provider = FakeProvider();
    final controller = YlCastController(providers: [provider]);
    await controller.cast(device, source);
    provider.session.stopError = const YlCastException('cast.network');
    await expectLater(controller.stop(), throwsA(isA<YlCastException>()));
    expect(controller.state.value.device, isNull);
    expect(provider.session.commands.last, 'dispose');
    await controller.dispose();
  });
  test('backend without delivery is rejected during assessment', () async {
    final player = await YlPlayerController.create(
      platform: FakePlayerPlatform(FakePlatformPlayer()),
    );
    final provider = FakeProvider();
    final controller = YlCastController(providers: [provider], player: player);
    final result = await controller.assess(
      device,
      YlNetworkSource(Uri.parse('rtmps://live.invalid/app/stream')),
    );
    expect(result.support, YlCastSupport.unsupported);
    expect(result.reason, 'cast.delivery_unavailable');
    expect(provider.connections, 0);
    await controller.dispose();
    await player.dispose();
  });
  for (final live in [false, true]) {
    test(
      'return local uses observed position but no live seek ($live)',
      () async {
        final backend = CastPlayer();
        final player = await YlPlayerController.create(
          platform: FakePlayerPlatform(backend),
        );
        final loading = player.load(source);
        backend.commit(const YlPlaybackSessionId('local'));
        final local = await loading;
        backend.emitState(
          backend.state.copyWith(
            revision: backend.state.revision + 1,
            status: YlPlaybackStatus.playing,
            timeline: YlTimeline(
              isLive: live,
              position: const Duration(seconds: 10),
              bufferedPosition: const Duration(seconds: 10),
            ),
          ),
        );
        final provider = FakeProvider();
        final controller = YlCastController(
          providers: [provider],
          player: player,
        );
        await controller.cast(
          device,
          source,
          handoff: YlCastHandoff(session: local, source: source),
        );
        expect(provider.session.request!.isLive, live);
        provider.session.state.value = const YlCastPlaybackState(
          status: YlCastPlaybackStatus.playing,
          position: Duration(seconds: 80),
        );
        final returning = controller.returnToLocal();
        await Future<void>.delayed(Duration.zero);
        expect(
          backend.lastOptions!.startPosition,
          live ? null : const Duration(seconds: 80),
        );
        expect(backend.lastOptions!.autoplay, isTrue);
        backend.commit(const YlPlaybackSessionId('returned'));
        await returning;
        expect(provider.session.commands, contains('stop'));
        await controller.dispose();
        await player.dispose();
      },
    );
  }
  test(
    'return local never overwrites externally replaced player session',
    () async {
      final backend = CastPlayer();
      final player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
      );
      final loading = player.load(source);
      backend.commit(const YlPlaybackSessionId('local'));
      final local = await loading;
      final provider = FakeProvider();
      final controller = YlCastController(
        providers: [provider],
        player: player,
      );
      await controller.cast(
        device,
        source,
        handoff: YlCastHandoff(session: local, source: source),
      );
      final external = player.load(source);
      backend.commit(const YlPlaybackSessionId('external'));
      await external;
      await expectLater(
        controller.returnToLocal(),
        throwsA(
          isA<YlCastException>().having(
            (e) => e.code,
            'code',
            'cast.local_session_stale',
          ),
        ),
      );
      expect(backend.loads.length, 2);
      expect(provider.session.commands, isNot(contains('stop')));
      await controller.dispose();
      await player.dispose();
    },
  );
  test('cancelled AirPlay load retires its late owned session', () async {
    final backend = CastPlayer();
    final player = await YlPlayerController.create(
      platform: FakePlayerPlatform(backend),
    );
    final controller = YlCastController(providers: [], player: player);
    final loading = controller.loadAirPlay(source);
    final rejected = expectLater(loading, throwsA(isA<YlCastException>()));
    await Future<void>.delayed(Duration.zero);
    await controller.cancelPending();
    backend.commit(const YlPlaybackSessionId('late'));
    await rejected;
    expect(backend.calls, contains('stop'));
    await controller.dispose();
    expect(backend.disposeCount, 0);
    await player.dispose();
  });
  for (final interrupt in ['replace', 'cancel', 'dispose', 'airplay']) {
    test('return local rechecks $interrupt after remote stop', () async {
      final backend = CastPlayer();
      final player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
      );
      final loading = player.load(source);
      backend.commit(const YlPlaybackSessionId('local'));
      final local = await loading;
      final provider = FakeProvider();
      final controller = YlCastController(
        providers: [provider],
        player: player,
      );
      addTearDown(() async {
        await controller.dispose();
        await player.dispose();
      });
      await controller.cast(
        device,
        source,
        handoff: YlCastHandoff(session: local, source: source),
      );
      provider.session.stopGate = Completer<void>();
      final returning = controller.returnToLocal();
      final rejected = expectLater(returning, throwsA(isA<YlCastException>()));
      await provider.session.stopStarted.future;
      Future<void>? disposal;
      switch (interrupt) {
        case 'replace':
          final replacement = player.load(source);
          backend.commit(const YlPlaybackSessionId('external'));
          await replacement;
        case 'cancel':
          await controller.cancelPending();
        case 'dispose':
          disposal = controller.dispose();
        case 'airplay':
          backend.airPlayState.value = const YlAirPlayState(
            supported: true,
            enabled: true,
            active: true,
            sessionId: YlPlaybackSessionId('local'),
          );
      }
      final before = backend.loads.length;
      backend.autoCommit = true;
      provider.session.stopGate!.complete();
      await rejected;
      expect(backend.loads.length, before);
      await disposal;
    });
  }
  for (final dispose in [false, true]) {
    test('return local cancels late local commit (dispose=$dispose)', () async {
      final backend = CastPlayer();
      final player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
      );
      final loading = player.load(source);
      backend.commit(const YlPlaybackSessionId('local'));
      final local = await loading;
      final provider = FakeProvider();
      final controller = YlCastController(
        providers: [provider],
        player: player,
      );
      addTearDown(() async {
        await controller.dispose();
        await player.dispose();
      });
      await controller.cast(
        device,
        source,
        handoff: YlCastHandoff(session: local, source: source),
      );
      final returning = controller.returnToLocal();
      final rejected = expectLater(returning, throwsA(isA<YlCastException>()));
      await Future<void>.delayed(Duration.zero);
      expect(backend.loads, hasLength(2));
      Future<void>? disposal;
      if (dispose) {
        disposal = controller.dispose();
      } else {
        await controller.cancelPending();
      }
      backend.commit(const YlPlaybackSessionId('returned'));
      await rejected;
      expect(backend.calls, contains('stop'));
      await disposal;
    });
  }
  for (final replaceExternally in [false, true]) {
    test(
      'AirPlay disposal respects owned identity (replace=$replaceExternally)',
      () async {
        final backend = CastPlayer();
        final player = await YlPlayerController.create(
          platform: FakePlayerPlatform(backend),
        );
        final controller = YlCastController(providers: [], player: player);
        final airPlay = controller.loadAirPlay(source);
        await Future<void>.delayed(Duration.zero);
        backend.commit(const YlPlaybackSessionId('owned'));
        await airPlay;
        if (replaceExternally) {
          final external = player.load(source);
          backend.commit(const YlPlaybackSessionId('external'));
          await external;
        }
        await controller.dispose();
        expect(backend.calls.contains('stop'), !replaceExternally);
        expect(backend.disposeCount, 0);
        await player.dispose();
      },
    );
  }
}

class FakeProvider implements YlCastProvider {
  final session = FakeSession();
  YlCastSupport support = YlCastSupport.supported;
  int connections = 0;
  int discoveryStarts = 0;
  bool disposed = false;
  @override
  String get id => 'fake';
  @override
  final ValueNotifier<List<YlCastDevice>> devices = ValueNotifier([]);
  @override
  final ValueNotifier<YlCastDiscoveryState> discovery = ValueNotifier(
    const YlCastDiscoveryState(),
  );
  @override
  Future<YlCastAssessment> assess(
    YlCastDevice device,
    YlCastRequest request,
  ) async => YlCastAssessment(support);
  @override
  Future<YlCastRemoteSession> connect(YlCastDevice device) async {
    connections++;
    return session;
  }

  @override
  Future<void> startDiscovery() async {
    discoveryStarts++;
    discovery.value = const YlCastDiscoveryState(scanning: true);
  }

  @override
  Future<void> stopDiscovery() async {
    discovery.value = const YlCastDiscoveryState();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    devices.dispose();
    discovery.dispose();
  }
}

class FakeSession implements YlCastRemoteSession {
  final commands = <String>[];
  Completer<void>? loadGate;
  Completer<void>? pauseGate;
  Completer<void>? playGate;
  Completer<void>? stopGate;
  final stopStarted = Completer<void>();
  Object? loadError;
  Object? stopError;
  YlCastRequest? request;
  final loadStarted = Completer<void>();
  final playStarted = Completer<void>();
  @override
  final device = const YlCastDevice(id: 'one', providerId: 'fake', name: 'TV');
  @override
  YlCastCapabilities capabilities = const YlCastCapabilities(
    pause: true,
    seek: true,
    volume: true,
    mute: true,
  );
  @override
  final ValueNotifier<YlCastPlaybackState> state = ValueNotifier(
    const YlCastPlaybackState(),
  );
  @override
  Future<void> load(YlCastRequest request) async {
    this.request = request;
    commands.add('load');
    loadStarted.complete();
    await loadGate?.future;
    if (loadError != null) throw loadError!;
  }

  @override
  Future<void> play() async {
    commands.add('play');
    if (!playStarted.isCompleted) playStarted.complete();
    await playGate?.future;
  }

  @override
  Future<void> pause() async {
    commands.add('pause');
    await pauseGate?.future;
  }

  @override
  Future<void> stop() async {
    commands.add('stop');
    if (!stopStarted.isCompleted) stopStarted.complete();
    await stopGate?.future;
    if (stopError != null) throw stopError!;
  }

  @override
  Future<void> seek(Duration position) async {
    commands.add('seek');
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> disconnect() async {
    commands.add('disconnect');
  }

  @override
  Future<void> dispose() async {
    commands.add('dispose');
    state.dispose();
  }
}

class CastPlayer extends FakePlatformPlayer
    implements YlAirPlayPlatformPlayer, YlMediaDeliveryPlatformPlayer {
  final lease = FakeLease();
  YlLoadOptions? lastOptions;
  bool autoCommit = false;
  @override
  Future<YlPlatformLoadResult> load(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) {
    lastOptions = options;
    final result = super.load(source, options: options);
    if (autoCommit) commit(const YlPlaybackSessionId('automatic'));
    return result;
  }

  @override
  final ValueNotifier<YlAirPlayState> airPlayState = ValueNotifier(
    const YlAirPlayState(supported: true),
  );
  @override
  YlAirPlayRoutePickerSurface? get airPlayRoutePickerSurface => null;
  @override
  Future<YlSourceAssessment> assessForAirPlay(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) => assess(source, options: options);
  @override
  Future<YlPlatformLoadResult> loadForAirPlay(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) => load(source, options: options);
  @override
  YlMediaDeliveryPreparation prepareMediaDelivery(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) => FakePreparation(lease);
}

class FakePreparation implements YlMediaDeliveryPreparation {
  FakePreparation(this.lease);
  final FakeLease lease;
  @override
  Future<YlMediaDeliveryLease> get result async => lease;
  @override
  Future<void> cancel() async {}
}

class FakeLease implements YlMediaDeliveryLease {
  bool disposed = false;
  @override
  final Uri uri = Uri.parse('http://192.168.1.2:1234/token/live.m3u8');
  @override
  String get contentType => 'application/vnd.apple.mpegurl';
  @override
  bool get isLive => true;
  @override
  final ValueNotifier<YlMediaDeliveryState> state = ValueNotifier(
    const YlMediaDeliveryState(status: YlMediaDeliveryStatus.ready),
  );
  @override
  Future<void> dispose() async {
    disposed = true;
    state.dispose();
  }
}
