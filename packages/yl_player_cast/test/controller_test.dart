import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_cast/yl_player_cast.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'support/fake_cast.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const device = YlCastDevice(id: 'one', providerId: 'fake', name: 'TV');
  final source = YlNetworkSource(Uri.parse('https://media.invalid/a.mp4'));
  test(
    'injected delivery works without a player and remains caller owned',
    () async {
      final mediaDelivery = FakeDeliveryProvider();
      final provider = FakeProvider();
      final controller = YlCastController(
        providers: [provider],
        mediaDelivery: mediaDelivery,
      );
      final source = YlNetworkSource(
        Uri.parse('rtmps://live.invalid/app/stream'),
      );
      expect(
        (await controller.assess(device, source)).support,
        YlCastSupport.supported,
      );
      await controller.cast(device, source);
      expect(controller.state.value.hostedMedia, isTrue);
      expect(provider.session.request!.uri, mediaDelivery.lease.uri);
      await controller.dispose();
      expect(mediaDelivery.lease.disposed, isTrue);
      expect(mediaDelivery.disposed, isFalse);
    },
  );
  test(
    'controller disposal cancels injected pending preparation without owning provider',
    () async {
      final delivery = FakeDeliveryProvider()..pending = DelayedPreparation();
      final controller = YlCastController(
        providers: [FakeProvider()],
        mediaDelivery: delivery,
      );
      final result = controller.cast(
        device,
        YlNetworkSource(Uri.parse('rtmps://live.invalid/app/stream')),
      );
      final failed = expectLater(result, throwsA(isA<YlCastException>()));
      await delivery.pending!.started.future;
      await controller.dispose();
      await failed;
      expect(delivery.pending!.cancelled, isTrue);
      expect(delivery.disposed, isFalse);
    },
  );
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
}
