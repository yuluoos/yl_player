import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models.dart';
import '../multicast.dart';
import '../provider.dart';
import 'description.dart';
import 'discovery.dart';
import 'session.dart';

export 'discovery.dart' show YlDlnaNetworkConfig;

/// Optional UPnP AV renderer discovery and control. A provider owns at most one
/// controlling session; replacing it disconnects the old control connection.
class YlDlnaProvider implements YlCastProvider {
  YlDlnaProvider({
    YlDlnaNetworkConfig? network,
    Set<String> verifiedHlsFmp4DeviceIds = const {},
    YlCastMulticastLock? multicastLock,
    @visibleForTesting
    Future<RawDatagramSocket> Function(InternetAddress, int)?
    bindDiscoverySocket,
  }) : network = network ?? YlDlnaNetworkConfig(),
       verifiedHlsFmp4DeviceIds = Set.unmodifiable(verifiedHlsFmp4DeviceIds),
       _lock = multicastLock ?? YlCastMulticastLock() {
    _discovery = DlnaDiscovery(
      this.network,
      (descriptions) {
        if (_disposed) return;
        _descriptions = {
          for (final description in descriptions)
            description.device.id: description,
        };
        _devices.value = List.unmodifiable(descriptions.map((d) => d.device));
      },
      (error) {
        _reportFailure(error);
        unawaited(
          stopDiscovery().catchError((Object error) {
            _reportFailure(discoveryFailure(error));
          }),
        );
      },
      bindSocket: bindDiscoverySocket,
    );
  }
  final YlDlnaNetworkConfig network;

  /// Host-verified receiver compatibility; HLS MIME support alone cannot prove
  /// that a receiver decodes fragmented MP4 segments.
  final Set<String> verifiedHlsFmp4DeviceIds;
  final YlCastMulticastLock _lock;
  late final DlnaDiscovery _discovery;
  final _discoveryFailure = ValueNotifier<YlCastException?>(null);
  final _discoveryState = ValueNotifier(const YlCastDiscoveryState());
  @override
  ValueListenable<YlCastDiscoveryState> get discovery => _discoveryState;

  /// Asynchronous UDP failures, including OS permission errors, remain visible
  /// instead of being interpreted as an empty network. Synchronous errors also
  /// fail [startDiscovery].
  ValueListenable<YlCastException?> get discoveryError => _discoveryFailure;
  final _devices = ValueNotifier<List<YlCastDevice>>([]);
  Map<String, DlnaDescription> _descriptions = {};
  DlnaSession? _session;
  Timer? _scanTimer;
  bool _disposed = false;
  bool _scanning = false;
  int _generation = 0;
  Future<void> _lifecycle = Future.value();
  @override
  String get id => 'dlna';
  @override
  ValueListenable<List<YlCastDevice>> get devices => _devices;

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _lifecycle.then((_) => operation());
    _lifecycle = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void _check() {
    if (_disposed) throw const YlCastException('cast.disposed');
  }

  void _reportFailure(YlCastException failure) {
    if (_disposed) return;
    _discoveryFailure.value = failure;
    _discoveryState.value = YlCastDiscoveryState(failureCode: failure.code);
  }

  @override
  Future<void> startDiscovery() => _serial(() async {
    _check();
    await _stop();
    _discoveryFailure.value = null;
    _discoveryState.value = const YlCastDiscoveryState(scanning: true);
    try {
      await _lock.acquire();
      _scanning = true;
      final generation = ++_generation;
      await _discovery.start();
      _scanTimer = Timer(network.discoveryDuration, () {
        if (generation == _generation) {
          unawaited(
            stopDiscovery().catchError((Object error) {
              _reportFailure(discoveryFailure(error));
            }),
          );
        }
      });
    } on Object catch (error) {
      final failure = discoveryFailure(error);
      _reportFailure(failure);
      await _stop();
      throw failure;
    }
  });
  Future<void> _stop() async {
    _generation++;
    _scanTimer?.cancel();
    _scanTimer = null;
    _discovery.stop();
    if (_discoveryState.value.scanning) {
      _discoveryState.value = YlCastDiscoveryState(
        failureCode: _discoveryState.value.failureCode,
      );
    }
    if (_scanning) {
      await _lock.release();
      _scanning = false;
    }
  }

  @override
  Future<void> stopDiscovery() => _serial(_stop);
  DlnaDescription _description(YlCastDevice device) {
    _check();
    final description = _descriptions[device.id];
    if (device.providerId != id || description == null) {
      throw const YlCastException('cast.device_unavailable');
    }
    return description;
  }

  @override
  Future<YlCastAssessment> assess(
    YlCastDevice device,
    YlCastRequest request,
  ) async => _description(
    device,
  ).assess(request, fmp4Verified: verifiedHlsFmp4DeviceIds.contains(device.id));
  @override
  Future<YlCastRemoteSession> connect(YlCastDevice device) => _serial(() async {
    final description = _description(device);
    await _session?.dispose();
    await _lock.acquire();
    late final DlnaSession session;
    session = DlnaSession(
      description,
      network,
      () async {
        if (identical(_session, session)) _session = null;
        await _lock.release();
      },
      fmp4Verified: verifiedHlsFmp4DeviceIds.contains(device.id),
    );
    _session = session;
    return session;
  });
  @override
  Future<void> dispose() => _serial(() async {
    if (_disposed) {
      await _lock.dispose();
      return;
    }
    _disposed = true;
    Object? firstError;
    StackTrace? firstTrace;
    Future<void> cleanup(Future<void> Function() action) async {
      try {
        await action();
      } on Object catch (error, trace) {
        firstError ??= error;
        firstTrace ??= trace;
      }
    }

    await cleanup(_stop);
    _discovery.dispose();
    final session = _session;
    if (session != null) await cleanup(session.dispose);
    await cleanup(_lock.dispose);
    _devices.dispose();
    _discoveryFailure.dispose();
    _discoveryState.dispose();
    if (firstError != null) Error.throwWithStackTrace(firstError!, firstTrace!);
  });
}
