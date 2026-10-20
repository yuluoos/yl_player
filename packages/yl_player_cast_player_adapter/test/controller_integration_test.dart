import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_cast/yl_player_cast.dart';
import 'package:yl_player_cast_player_adapter/yl_player_cast_player_adapter.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import '../../yl_player/test/support/fake_player_platform.dart';
import '../../yl_player_cast/test/support/fake_cast.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const device = YlCastDevice(id: 'one', providerId: 'fake', name: 'TV');
  final source = YlNetworkSource(Uri.parse('https://media.invalid/a.mp4'));
  test(
    'injected provider takes precedence over player compatibility',
    () async {
      final backend = CastPlayer();
      final player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
      );
      final delivery = FakeDeliveryProvider();
      final controller = YlCastController(
        providers: [FakeProvider()],
        player: YlPlayerCastAdapter(player),
        mediaDelivery: delivery,
      );
      await controller.cast(
        device,
        YlNetworkSource(Uri.parse('rtmps://live.invalid/app/stream')),
      );
      await controller.dispose();
      expect(delivery.lease.disposed, isTrue);
      expect(backend.lease.disposed, isFalse);
      expect(delivery.disposed, isFalse);
      await player.dispose();
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
    final controller = YlCastController(
      providers: [provider],
      player: YlPlayerCastAdapter(player),
    );
    await expectLater(
      controller.cast(
        device,
        source,
        handoff: YlCastHandoff(
          session: YlPlayerCastSessionAdapter(local),
          source: source,
        ),
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
        player: YlPlayerCastAdapter(player),
      );
      final casting = controller.cast(
        device,
        source,
        handoff: YlCastHandoff(
          session: YlPlayerCastSessionAdapter(local),
          source: source,
        ),
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
        player: YlPlayerCastAdapter(player),
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
    final controller = YlCastController(
      providers: [provider],
      player: YlPlayerCastAdapter(player),
    );
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
    final controller = YlCastController(
      providers: [provider],
      player: YlPlayerCastAdapter(player),
    );
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
  test('backend without delivery is rejected during assessment', () async {
    final player = await YlPlayerController.create(
      platform: FakePlayerPlatform(FakePlatformPlayer()),
    );
    final provider = FakeProvider();
    final controller = YlCastController(
      providers: [provider],
      player: YlPlayerCastAdapter(player),
    );
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
          player: YlPlayerCastAdapter(player),
        );
        await controller.cast(
          device,
          source,
          handoff: YlCastHandoff(
            session: YlPlayerCastSessionAdapter(local),
            source: source,
          ),
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
        player: YlPlayerCastAdapter(player),
      );
      await controller.cast(
        device,
        source,
        handoff: YlCastHandoff(
          session: YlPlayerCastSessionAdapter(local),
          source: source,
        ),
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
    final controller = YlCastController(
      providers: [],
      player: YlPlayerCastAdapter(player),
    );
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
        player: YlPlayerCastAdapter(player),
      );
      addTearDown(() async {
        await controller.dispose();
        await player.dispose();
      });
      await controller.cast(
        device,
        source,
        handoff: YlCastHandoff(
          session: YlPlayerCastSessionAdapter(local),
          source: source,
        ),
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
        player: YlPlayerCastAdapter(player),
      );
      addTearDown(() async {
        await controller.dispose();
        await player.dispose();
      });
      await controller.cast(
        device,
        source,
        handoff: YlCastHandoff(
          session: YlPlayerCastSessionAdapter(local),
          source: source,
        ),
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
        final controller = YlCastController(
          providers: [],
          player: YlPlayerCastAdapter(player),
        );
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
