import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'license_timing.dart';
import 'license_stub.dart' if (dart.library.io) 'license_io.dart' as backend;

/// Idempotent cancellation for one request or a group of requests. Listeners are
/// removed after completion; cancellation cannot publish a late license result.
final class YlDrmCancellationToken {
  bool _cancelled = false;
  final _listeners = <void Function()>{};
  bool get isCancelled => _cancelled;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final callbacks = _listeners.toList();
    _listeners.clear();
    for (final callback in callbacks) {
      callback();
    }
  }

  /// Internal transport subscription; returns a removal function.
  void Function() listen(void Function() callback) {
    if (_cancelled) {
      callback();
      return () {};
    }
    _listeners.add(callback);
    return () {
      _listeners.remove(callback);
    };
  }

  @override
  String toString() => 'YlDrmCancellationToken(cancelled: $_cancelled)';
}

/// Bounded raw binary license POST client, independent of media GET policy.
/// This does not decrypt content or install licenses into a native DRM session.
final class YlDrmLicenseClient {
  final _timingOwner = currentLicenseTimingTrace;
  final _active = <YlDrmCancellationToken>{};
  bool _closed = false;
  Future<YlDrmBytes> send(
    YlDrmLicenseEndpoint endpoint,
    YlDrmBytes challenge, {
    YlDrmCancellationToken? cancellation,
  }) async {
    if (_closed || (cancellation?.isCancelled ?? false)) {
      throw ylDrmException(YlFailureCodes.loadCancelled);
    }
    if (challenge.length == 0) {
      throw ylDrmException(YlFailureCodes.drmConfigInvalid);
    }
    if (challenge.length > 1024 * 1024) {
      throw ylDrmException(YlFailureCodes.drmPayloadTooLarge);
    }
    if (_active.length >= 4) {
      throw ylDrmException(YlFailureCodes.resourceExhausted);
    }
    final token = YlDrmCancellationToken();
    final remove = cancellation?.listen(token.cancel);
    _active.add(token);
    try {
      return await timeLicenseTransport(
        () => backend.sendLicense(endpoint, challenge, token),
        owner: _timingOwner,
      );
    } finally {
      remove?.call();
      _active.remove(token);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final token in _active.toList()) {
      token.cancel();
    }
  }

  @override
  String toString() => 'YlDrmLicenseClient(<redacted>)';
}
