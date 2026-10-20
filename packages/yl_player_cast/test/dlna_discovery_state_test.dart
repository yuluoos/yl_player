import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_cast/src/dlna/provider.dart';
import 'package:yl_player_cast/src/models.dart';

import 'dlna_loopback_test.dart' show until;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  YlDlnaNetworkConfig network({Duration? duration, InternetAddress? bind}) =>
      YlDlnaNetworkConfig(
        ssdpAddress: InternetAddress.loopbackIPv4,
        bindAddress: bind ?? InternetAddress.loopbackIPv4,
        discoveryDuration: duration ?? const Duration(seconds: 10),
      );

  test(
    'start, manual stop, timed stop and disposal publish activity',
    () async {
      final provider = YlDlnaProvider(
        network: network(duration: const Duration(milliseconds: 100)),
      );
      final states = <YlCastDiscoveryState>[];
      provider.discovery.addListener(
        () => states.add(provider.discovery.value),
      );
      expect(provider.discovery.value.scanning, isFalse);
      await provider.startDiscovery();
      expect(provider.discovery.value.scanning, isTrue);
      await provider.stopDiscovery();
      expect(provider.discovery.value.scanning, isFalse);
      await provider.startDiscovery();
      await until(() => !provider.discovery.value.scanning);
      expect(provider.discovery.value.failureCode, isNull);
      await provider.startDiscovery();
      await provider.dispose();
      expect(states.last.scanning, isFalse);
      expect(states.where((state) => state.scanning), hasLength(3));
    },
  );

  test('bind failure publishes a redacted failure and ends activity', () async {
    final provider = YlDlnaProvider(
      network: network(bind: InternetAddress('192.0.2.1')),
    );
    addTearDown(provider.dispose);
    await expectLater(
      provider.startDiscovery(),
      throwsA(isA<YlCastException>()),
    );
    expect(provider.discovery.value.scanning, isFalse);
    expect(provider.discovery.value.failureCode, 'cast.discovery_failed');
  });

  test(
    'Android permission failure is observable and retry clears it',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel('dev.ylplayer.cast/multicast');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var attempts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'acquire' && attempts++ == 0) {
          throw PlatformException(
            code: 'cast.multicast_permission',
            message: 'private native detail',
          );
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final provider = YlDlnaProvider(network: network());
      addTearDown(provider.dispose);
      await expectLater(
        provider.startDiscovery(),
        throwsA(isA<YlCastException>()),
      );
      expect(provider.discovery.value.scanning, isFalse);
      expect(
        provider.discovery.value.failureCode,
        'cast.network_permission_denied',
      );
      await provider.startDiscovery();
      expect(provider.discovery.value.scanning, isTrue);
      expect(provider.discovery.value.failureCode, isNull);
    },
  );

  test(
    'late UDP permission failure publishes after start and retry clears it',
    () async {
      late ErrorSocket socket;
      final provider = YlDlnaProvider(
        network: network(),
        bindDiscoverySocket: (address, port) async {
          return socket = ErrorSocket(
            await RawDatagramSocket.bind(address, port),
          );
        },
      );
      addTearDown(provider.dispose);
      final failures = <String?>[];
      provider.discovery.addListener(
        () => failures.add(provider.discovery.value.failureCode),
      );
      await provider.startDiscovery();
      expect(provider.discovery.value.scanning, isTrue);
      socket.events.addError(
        const SocketException(
          'private socket detail',
          osError: OSError('private', 13),
        ),
      );
      await until(() => provider.discovery.value.failureCode != null);
      expect(provider.discovery.value.scanning, isFalse);
      expect(
        provider.discovery.value.failureCode,
        'cast.network_permission_denied',
      );
      expect(
        provider.discoveryError.value?.code,
        'cast.network_permission_denied',
      );
      expect(socket.closed, isTrue);
      await provider.startDiscovery();
      expect(provider.discovery.value.scanning, isTrue);
      expect(provider.discovery.value.failureCode, isNull);
      expect(failures, contains('cast.network_permission_denied'));
    },
  );
}

// Keep the real bind/send/receive lifecycle; only the OS event stream gains an
// injectable error, which loopback sockets cannot reliably produce on demand.
class ErrorSocket extends Stream<RawSocketEvent> implements RawDatagramSocket {
  ErrorSocket(this.socket) {
    subscription = socket.listen(events.add, onError: events.addError);
  }
  final RawDatagramSocket socket;
  final events = StreamController<RawSocketEvent>();
  late final StreamSubscription<RawSocketEvent> subscription;
  bool closed = false;
  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => events.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  set writeEventsEnabled(bool enabled) => socket.writeEventsEnabled = enabled;
  @override
  Datagram? receive() => socket.receive();
  @override
  int send(List<int> buffer, InternetAddress address, int port) =>
      socket.send(buffer, address, port);
  @override
  void close() {
    if (closed) return;
    closed = true;
    socket.close();
    unawaited(subscription.cancel());
    unawaited(events.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
