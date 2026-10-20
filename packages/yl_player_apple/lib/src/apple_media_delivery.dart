import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'apple_codec.dart';
import 'pigeon/yl_player_apple.g.dart';

/// 独立资源通道，不改变本地播放会话或 AirPlay 输出路由。
final class AppleMediaDeliveryChannel {
  AppleMediaDeliveryChannel(String suffix)
    : _requests = BasicMessageChannel<Object?>(
        'dev.ylplayer.delivery.$suffix',
        ApplePlayerHostApi.pigeonChannelCodec,
      ),
      _events = BasicMessageChannel<Object?>(
        'dev.ylplayer.delivery.events.$suffix',
        ApplePlayerHostApi.pigeonChannelCodec,
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
  final BasicMessageChannel<Object?> _requests;
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
    AppleAssessRequest? request,
  ]) async {
    final reply = await _requests.send({
      'method': method,
      'id': id,
      'request': ?request,
    });
    if (reply == null) {
      throw AppleCodec.problem(
        YlFailureCodes.policyUnsupported,
        scope: YlFailureScope.command,
      );
    }
    if (reply is! Map ||
        reply.containsKey('value') == reply.containsKey('error')) {
      throw AppleCodec.problem(YlFailureCodes.protocolMismatch);
    }
    if (reply['error'] case final AppleFailureMessage error) {
      throw YlPlayerException(AppleCodec.failure(error));
    }
    if (reply.containsKey('error')) {
      throw AppleCodec.problem(YlFailureCodes.protocolMismatch);
    }
    return reply['value'];
  }

  YlMediaDeliveryPreparation prepare(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) {
    if (_closed) throw AppleCodec.problem(YlFailureCodes.playerDisposed);
    final request = AppleAssessRequest(
      source: AppleCodec.source(source),
      options: AppleCodec.loadOptions(options),
    );
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
        throw AppleCodec.problem(YlFailureCodes.protocolMismatch);
      }
      final previous = _pending;
      if (previous != null) unawaited(previous.cancel());
      _pending = pending;
      pending.started = true;
      unawaited(_prepare(pending, admission.request));
    } catch (error) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(AppleCodec.exception(error));
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
    AppleAssessRequest request,
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
        throw AppleCodec.problem(YlFailureCodes.protocolMismatch);
      }
      final uri = Uri.tryParse(value['uri'] as String);
      if (uri == null ||
          uri.scheme != 'http' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment) {
        throw AppleCodec.problem(YlFailureCodes.protocolMismatch);
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
        pending.completer.completeError(AppleCodec.exception(error));
      }
      await _release(pending.id);
    }
  }

  Future<void> _release(String id) async {
    try {
      await _send('release', id).timeout(const Duration(seconds: 5));
    } catch (_) {
      /* Native player disposal is the final cleanup boundary. */
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final admitting = _admitting;
    if (admitting != null) unawaited(admitting.pending.cancel());
    final queued = _queuedAdmission;
    if (queued != null) unawaited(queued.pending.cancel());
    _queuedAdmission = null;
    final pending = _pending;
    if (pending != null) unawaited(pending.cancel());
    final lease = _lease;
    if (lease != null) unawaited(lease.dispose());
    _lease = null;
    _events.setMessageHandler(null);
  }
}

final class _Admission {
  _Admission(this.pending, this.request);
  final _Preparation pending;
  final AppleAssessRequest request;
}

final class _Preparation implements YlMediaDeliveryPreparation {
  _Preparation(this.owner, this.id);
  final AppleMediaDeliveryChannel owner;
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
      AppleCodec.problem(
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
  final AppleMediaDeliveryChannel owner;
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
    if (message['status'] == 'failed' &&
        message['failure'] is AppleFailureMessage) {
      final failure = message['failure'] as AppleFailureMessage;
      _state.value = YlMediaDeliveryState(
        status: YlMediaDeliveryStatus.failed,
        failure: AppleCodec.failure(failure),
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
