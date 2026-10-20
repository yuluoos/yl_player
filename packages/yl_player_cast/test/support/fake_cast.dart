import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:yl_player_cast/yl_player_cast.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

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

class FakeDeliveryProvider implements YlMediaDeliveryProvider {
  DelayedPreparation? pending;
  final lease = FakeLease();
  bool disposed = false;
  @override
  YlMediaDeliveryPreparation prepareMediaDelivery(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) => pending ?? FakePreparation(lease);
  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class DelayedPreparation implements YlMediaDeliveryPreparation {
  final started = Completer<void>();
  final completer = Completer<YlMediaDeliveryLease>();
  bool cancelled = false;
  @override
  Future<YlMediaDeliveryLease> get result {
    if (!started.isCompleted) started.complete();
    return completer.future;
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    if (!completer.isCompleted) {
      completer.completeError(const YlCastException('cast.cancelled'));
    }
  }
}
