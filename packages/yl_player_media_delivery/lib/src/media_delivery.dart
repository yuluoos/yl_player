import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'wire_codec.dart';

/// 独立交付服务；不会创建播放器或改变本地播放、AirPlay 路由。
final class YlMediaDelivery implements YlMediaDeliveryProvider {
  YlMediaDelivery._(String owner)
    : _requests = MethodChannel('dev.ylplayer.media_delivery.$owner'),
      _events = BasicMessageChannel<Object?>(
        'dev.ylplayer.media_delivery.events.$owner',
        const StandardMessageCodec(),
      ) {
    _events.setMessageHandler((message) async {
      if (_closed) return null;
      if (message is Map && message['id'] is String) {
        final id = message['id'] as String;
        if (_lease?.id == id) _lease!._event(message);
        if (_pending?.id == id) _pending!.earlyEvent = message;
      }
      return null;
    });
  }

  /// 创建独立原生所有者。未安装插件或非 Apple 平台返回 policy.unsupported。
  static Future<YlMediaDelivery> create() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.macOS)) {
      throw DeliveryCodec.problem(
        YlFailureCodes.policyUnsupported,
        category: YlFailureCategory.unsupported,
      );
    }
    try {
      final owner = await const MethodChannel(
        'dev.ylplayer.media_delivery',
      ).invokeMethod<Object?>('create');
      if (owner is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(owner)) {
        throw DeliveryCodec.problem(YlFailureCodes.protocolMismatch);
      }
      return YlMediaDelivery._(owner);
    } catch (error) {
      throw DeliveryCodec.exception(error);
    }
  }

  final MethodChannel _requests;
  final BasicMessageChannel<Object?> _events;
  int _serial = 0;
  bool _closed = false;
  _Preparation? _pending;
  _Admission? _admitting;
  _Admission? _queuedAdmission;
  _Lease? _lease;

  Future<Object?> _send(
    String method,
    String id, [
    Map<String, Object?>? request,
  ]) async {
    try {
      return await _requests.invokeMethod<Object?>(method, {
        'id': id,
        ...?request,
      });
    } catch (error) {
      throw DeliveryCodec.exception(error);
    }
  }

  @override
  YlMediaDeliveryPreparation prepareMediaDelivery(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) {
    if (_closed) throw DeliveryCodec.problem(YlFailureCodes.playerDisposed);
    final request = DeliveryCodec.request(source, options);
    final pending = _Preparation(this, 'd${++_serial}');
    final admission = _Admission(pending, request);
    if (_admitting == null) {
      _startAdmission(admission);
    } else {
      // Bound admission backlog without disturbing the admitted producer.
      final queued = _queuedAdmission;
      if (queued != null) unawaited(queued.pending.cancel());
      _queuedAdmission = admission;
    }
    return pending;
  }

  void _startAdmission(_Admission admission) {
    _admitting = admission;
    unawaited(_admit(admission));
  }

  Future<void> _admit(_Admission admission) async {
    final pending = admission.pending;
    try {
      // Native admission is network-free and uses the same validation as prepare.
      final admitted = await _send(
        'admit',
        pending.id,
        admission.request,
      ).timeout(const Duration(seconds: 5));
      if (_closed || pending.cancelled) return;
      if (admitted != true) {
        throw DeliveryCodec.problem(YlFailureCodes.protocolMismatch);
      }
      final previous = _pending;
      if (previous != null) unawaited(previous.cancel());
      _pending = pending;
      pending.started = true;
      unawaited(_prepare(pending, admission.request));
    } catch (error) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(DeliveryCodec.exception(error));
      }
    } finally {
      _admitting = null;
      final next = _queuedAdmission;
      _queuedAdmission = null;
      if (!_closed && next != null && !next.pending.cancelled) {
        _startAdmission(next);
      }
    }
  }

  Future<void> _prepare(
    _Preparation pending,
    Map<String, Object?> request,
  ) async {
    try {
      final value = await _send('prepare', pending.id, request);
      if (_closed || pending.cancelled || _pending != pending) {
        await _release(pending.id);
        return;
      }
      if (value is! Map ||
          value['id'] != pending.id ||
          value['uri'] is! String ||
          value['contentType'] != 'application/vnd.apple.mpegurl' ||
          value['isLive'] != true) {
        throw DeliveryCodec.problem(YlFailureCodes.protocolMismatch);
      }
      final uri = Uri.tryParse(value['uri'] as String);
      if (uri == null ||
          uri.scheme != 'http' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment) {
        throw DeliveryCodec.problem(YlFailureCodes.protocolMismatch);
      }
      final lease = _Lease(this, pending.id, uri);
      _lease?._close();
      _lease = lease;
      _pending = null;
      if (pending.earlyEvent case final event?) lease._event(event);
      pending.completer.complete(lease);
    } catch (error) {
      if (_pending == pending) _pending = null;
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(DeliveryCodec.exception(error));
      }
      await _release(pending.id);
    }
  }

  Future<void> _release(String id) async {
    try {
      await _send('release', id).timeout(const Duration(seconds: 5));
    } on Object catch (_) {
      /* Native owner disposal is the final cleanup boundary. */
    }
  }

  Future<void>? _disposal;
  @override
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _closed = true;
    final cleanup = <Future<void>>[];
    final admitting = _admitting;
    if (admitting != null) cleanup.add(admitting.pending.cancel());
    final queued = _queuedAdmission;
    if (queued != null) cleanup.add(queued.pending.cancel());
    _queuedAdmission = null;
    final pending = _pending;
    if (pending != null) cleanup.add(pending.cancel());
    final lease = _lease;
    if (lease != null) cleanup.add(lease.dispose());
    _lease = null;
    _events.setMessageHandler(null);
    try {
      await Future.wait(cleanup);
    } finally {
      try {
        await _requests.invokeMethod<void>('dispose');
      } catch (error) {
        throw DeliveryCodec.exception(error);
      }
    }
  }
}

final class _Admission {
  _Admission(this.pending, this.request);
  final _Preparation pending;
  final Map<String, Object?> request;
}

final class _Preparation implements YlMediaDeliveryPreparation {
  _Preparation(this.owner, this.id);
  final YlMediaDelivery owner;
  final String id;
  final completer = Completer<YlMediaDeliveryLease>();
  bool cancelled = false;
  bool started = false;
  Map? earlyEvent;
  Future<void>? _cancellation;
  @override
  Future<YlMediaDeliveryLease> get result => completer.future;
  @override
  Future<void> cancel() {
    if (_cancellation case final result?) return result;
    if (completer.isCompleted) return Future.value();
    cancelled = true;
    completer.completeError(
      DeliveryCodec.problem(
        YlFailureCodes.loadCancelled,
        category: YlFailureCategory.cancelled,
        scope: YlFailureScope.command,
      ),
    );
    if (owner._pending == this) owner._pending = null;
    if (owner._queuedAdmission?.pending == this) owner._queuedAdmission = null;
    return _cancellation = started ? owner._release(id) : Future.value();
  }
}

final class _Lease implements YlMediaDeliveryLease {
  _Lease(this.owner, this.id, this.uri);
  final YlMediaDelivery owner;
  final String id;
  @override
  final Uri uri;
  @override
  String get contentType => 'application/vnd.apple.mpegurl';
  @override
  bool get isLive => true;
  final _state = ValueNotifier(
    const YlMediaDeliveryState(status: YlMediaDeliveryStatus.ready),
  );
  @override
  ValueListenable<YlMediaDeliveryState> get state => _state;
  Future<void>? _disposal;
  void _event(Map message) {
    if (_state.value.status != YlMediaDeliveryStatus.ready) return;
    if (message['status'] == 'closed') {
      _close();
      return;
    }
    if (message['status'] == 'failed' && message['failure'] is Map) {
      final failure = message['failure'] as Map;
      _state.value = YlMediaDeliveryState(
        status: YlMediaDeliveryStatus.failed,
        failure: DeliveryCodec.failure(failure),
      );
    }
  }

  void _close() {
    _state.value = const YlMediaDeliveryState(
      status: YlMediaDeliveryStatus.closed,
    );
  }

  @override
  Future<void> dispose() {
    if (_disposal case final result?) return result;
    _close();
    if (owner._lease == this) owner._lease = null;
    return _disposal = owner._release(id);
  }
}
