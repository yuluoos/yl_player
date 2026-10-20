import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps Android Wi-Fi multicast reception enabled while casting needs it.
///
/// Each successful [acquire] must be balanced by [release]. Overlapping
/// discovery and remote sessions share one native reference per instance.
/// [dispose] releases that reference regardless of the local reference count.
/// Other platforms need no Android lock and perform no platform calls.
///
/// Operations run in order. Android permission and platform failures propagate
/// to the caller; failed releases retain ownership and can be retried.
class YlCastMulticastLock {
  static const _channel = MethodChannel('dev.ylplayer.cast/multicast');
  final bool _isAndroid =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  Future<void> _tail = Future<void>.value();
  Future<void>? _disposal;
  int _references = 0;
  bool _closing = false;

  /// Adds a reference, acquiring the native lock for the first reference.
  Future<void> acquire() {
    if (_closing) {
      return Future<void>.error(StateError('Multicast lock is disposed.'));
    }
    return _enqueue(() async {
      if (_references == 0 && _isAndroid) {
        await _channel.invokeMethod<void>('acquire');
      }
      _references++;
    });
  }

  /// Removes a reference. Releasing an unheld or disposed lock is harmless.
  Future<void> release() => _enqueue(() async {
    if (_references == 0) return;
    if (_references == 1 && _isAndroid) {
      await _channel.invokeMethod<void>('release');
    }
    _references--;
  });

  /// Closes acquisition and releases all references after queued operations.
  ///
  /// Repeated calls share the same pending cleanup. If native cleanup fails,
  /// calling [dispose] again retries it without reopening acquisition.
  Future<void> dispose() {
    _closing = true;
    return _disposal ??= _enqueue(() async {
      try {
        if (_references > 0 && _isAndroid) {
          await _channel.invokeMethod<void>('release');
        }
        _references = 0;
      } catch (_) {
        _disposal = null;
        rethrow;
      }
    });
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
