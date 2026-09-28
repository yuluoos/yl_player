import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'pigeon/yl_player_apple.g.dart';

/// Player-local license ownership. All payloads stay off state/diagnostic streams.
final class AppleDrmChannel implements AppleDrmFlutterApi {
  AppleDrmChannel(String suffix, this.support, {AppleDrmHostApi? host})
    : _host = host ?? AppleDrmHostApi(messageChannelSuffix: suffix);
  final AppleDrmSupportMessage support;
  TargetPlatform get platform => support.platform == ApplePlatform.ios
      ? TargetPlatform.iOS
      : TargetPlatform.macOS;
  final AppleDrmHostApi _host;
  YlDrmLicenseExchange? exchange;
  void Function()? onFrameReady;
  final _contexts = <String, _DrmContext>{};
  final _requests = <String, (AppleDrmExchangeId, Completer<void>)>{};
  YlProtectedVideoSurface? surface;
  int? _viewId, _ackRevision, _frameRevision;
  bool _closed = false;
  Object? _attachAttempt;

  void validate(YlMediaSource source) {
    if (source is! YlNetworkSource || source.drm == null) return;
    validateYlDrmPlatform(source.drm!, platform);
    if (_closed ||
        support.contractVersion != 1 ||
        !support.schemeAvailable ||
        exchange == null) {
      throw ylDrmException(YlFailureCodes.drmUnsupported);
    }
  }

  void begin(String requestId, YlMediaSource source) {
    validate(source);
    if (source is YlNetworkSource && source.drm != null) {
      _contexts[requestId] = _DrmContext(source.drm!.license);
    }
  }

  YlProtectedVideoSurface decode(AppleProtectedSurfaceMessage wire) {
    if (wire.playerId != support.playerId ||
        wire.surfaceId < 0 ||
        wire.generation < 0 ||
        wire.surfaceId > 0x7fffffffffffffff ||
        wire.generation > 0x7fffffffffffffff) {
      throw ylDrmException(YlFailureCodes.protocolMismatch);
    }
    validateYlPlaybackSessionId(YlPlaybackSessionId(wire.sessionId));
    return YlProtectedVideoSurface(
      playerId: wire.playerId,
      surfaceId: wire.surfaceId,
      sessionId: wire.sessionId,
      generation: wire.generation,
      viewType: 'yl_player_apple/protected_video',
      platform: platform,
    );
  }

  void checkReply(
    String requestId,
    String session,
    AppleProtectedSurfaceMessage? wire,
  ) {
    final context = _contexts[requestId];
    if (context == null && wire == null) return;
    if (context == null || wire == null) {
      throw ylDrmException(YlFailureCodes.protocolMismatch);
    }
    final value = decode(wire);
    if (session != value.sessionId ||
        context.identity != null && context.identity != value) {
      throw ylDrmException(YlFailureCodes.protocolMismatch);
    }
    context.identity = value;
  }

  void commit(String requestId) {
    _attachAttempt = null;
    surface = _contexts[requestId]?.identity;
    _viewId = null;
    _ackRevision = null;
    _frameRevision = null;
    for (final id in _contexts.keys.toList()) {
      if (id != requestId) cancel(id);
    }
  }

  void cancel(String requestId) {
    final context = _contexts.remove(requestId);
    if (context != null && (surface == null || context.identity != surface)) {
      unawaited(
        Future.sync(
          () => _host.cancelProtectedLoad(requestId),
        ).catchError((Object _) {}),
      );
    }
    for (final request in _requests.values.toList()) {
      if (request.$1.loadRequestId == requestId && !request.$2.isCompleted) {
        request.$2.complete();
      }
    }
  }

  void stop() {
    _attachAttempt = null;
    for (final id in _contexts.keys.toList()) {
      cancel(id);
    }
    surface = null;
    _viewId = null;
    _ackRevision = null;
    _frameRevision = null;
  }

  void close() {
    _closed = true;
    stop();
  }

  @override
  Future<AppleDrmLicenseReply> exchangeLicense(
    AppleDrmLicenseRequest request,
  ) async {
    final id = request.id;
    Completer<void>? cancellation;
    try {
      final context = _contexts[id.loadRequestId];
      if (_closed ||
          context == null ||
          id.surface.playerId != support.playerId ||
          id.epoch < 1 ||
          id.requestId < 1 ||
          id.exchangeId.isEmpty ||
          id.exchangeId.length > 128 ||
          context.seen.contains(id.exchangeId)) {
        throw ylDrmException(YlFailureCodes.loadCancelled);
      }
      final identity = decode(id.surface);
      if (context.identity != null && context.identity != identity) {
        throw ylDrmException(YlFailureCodes.loadCancelled);
      }
      if (_requests.length >= 4 || context.seen.length >= 4096) {
        throw ylDrmException(YlFailureCodes.resourceExhausted);
      }
      if (request.challenge.isEmpty) {
        throw ylDrmException(YlFailureCodes.drmConfigInvalid);
      }
      if (request.challenge.length > 1024 * 1024) {
        throw ylDrmException(YlFailureCodes.drmPayloadTooLarge);
      }
      context.identity = identity;
      context.seen.add(id.exchangeId);
      cancellation = Completer<void>();
      _requests[id.exchangeId] = (id, cancellation);
      final handler = exchange;
      if (handler == null) throw ylDrmException(YlFailureCodes.drmUnsupported);
      final response = await Future.any<YlDrmBytes>([
        Future.sync(
          () => handler(
            context.endpoint,
            YlDrmBytes(request.challenge),
            cancellation!.future,
          ),
        ),
        cancellation.future.then(
          (_) => throw ylDrmException(YlFailureCodes.loadCancelled),
        ),
      ]);
      if (_closed ||
          _contexts[id.loadRequestId] != context ||
          cancellation.isCompleted) {
        throw ylDrmException(YlFailureCodes.loadCancelled);
      }
      if (response.length == 0) {
        throw ylDrmException(YlFailureCodes.drmLicenseResponseInvalid);
      }
      return AppleDrmLicenseReply(id: id, response: response.bytes);
    } catch (error) {
      final code =
          error is YlPlayerException &&
              _licenseFailures.contains(error.failure.code)
          ? error.failure.code
          : YlFailureCodes.drmLicenseFailed;
      return AppleDrmLicenseReply(id: id, failureCode: code);
    } finally {
      request.challenge.fillRange(0, request.challenge.length, 0);
      if (cancellation != null) {
        _requests.remove(id.exchangeId);
        if (!cancellation.isCompleted) cancellation.complete();
      }
    }
  }

  @override
  void cancelLicense(AppleDrmExchangeId id) {
    final pending = _requests[id.exchangeId];
    if (pending != null && _sameId(pending.$1, id) && !pending.$2.isCompleted) {
      pending.$2.complete();
    }
  }

  bool _sameId(AppleDrmExchangeId a, AppleDrmExchangeId b) =>
      a.loadRequestId == b.loadRequestId &&
      a.exchangeId == b.exchangeId &&
      a.epoch == b.epoch &&
      a.requestId == b.requestId &&
      a.surface.playerId == b.surface.playerId &&
      a.surface.surfaceId == b.surface.surfaceId &&
      a.surface.sessionId == b.surface.sessionId &&
      a.surface.generation == b.surface.generation;
  AppleProtectedSurfaceMessage _wire(YlProtectedVideoSurface value) =>
      AppleProtectedSurfaceMessage(
        playerId: value.playerId,
        surfaceId: value.surfaceId,
        sessionId: value.sessionId,
        generation: value.generation,
      );
  Future<void> attach(
    YlProtectedVideoSurface value,
    int viewId, {
    void Function(Object error)? onFailure,
  }) async {
    if (_closed || value != surface || viewId < 0) {
      throw ylDrmException(YlFailureCodes.sessionStale);
    }
    final attempt = Object();
    _attachAttempt = attempt;
    bool isCurrent() =>
        !_closed &&
        value == surface &&
        _viewId == viewId &&
        identical(_attachAttempt, attempt);
    _viewId = viewId;
    _ackRevision = null;
    _frameRevision = null;
    try {
      final ack = await _host
          .attachProtectedView(
            AppleProtectedViewCommand(surface: _wire(value), viewId: viewId),
          )
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () =>
                throw ylDrmException(YlFailureCodes.drmProtectionInsufficient),
          );
      if (!isCurrent()) return;
      if (!ack.attached ||
          ack.viewId != viewId ||
          decode(ack.surface) != value ||
          ack.revision < 1) {
        throw ylDrmException(YlFailureCodes.protocolMismatch);
      }
      final frame = _frameRevision;
      _ackRevision = frame != null && frame > ack.revision
          ? frame
          : ack.revision;
      if (frameReady(value.sessionId)) onFrameReady?.call();
    } catch (error) {
      if (!isCurrent()) return;
      // Publish while ownership is still checked; an async caller's catch may
      // resume after a new session commits.
      onFailure?.call(error);
      rethrow;
    }
  }

  Future<void> detach(YlProtectedVideoSurface value, int viewId) async {
    if (value == surface && _viewId == viewId) {
      _attachAttempt = null;
      _viewId = null;
      _ackRevision = null;
      _frameRevision = null;
    }
    if (_closed) return;
    final ack = await _host.detachProtectedView(
      AppleProtectedViewCommand(surface: _wire(value), viewId: viewId),
    );
    if (ack.attached || ack.viewId != viewId || decode(ack.surface) != value) {
      throw ylDrmException(YlFailureCodes.protocolMismatch);
    }
  }

  @override
  void onProtectedFrame(AppleProtectedViewAck frame) {
    if (_closed ||
        !frame.attached ||
        frame.viewId != _viewId ||
        frame.revision < 1) {
      return;
    }
    try {
      if (decode(frame.surface) != surface) return;
    } catch (_) {
      return;
    }
    if (frame.revision < (_ackRevision ?? 0) ||
        frame.revision < (_frameRevision ?? 0)) {
      return;
    }
    _frameRevision = frame.revision;
    // Holder recreation/background resume advances native revision without remounting Flutter.
    if (_ackRevision != null && frame.revision >= _ackRevision!) {
      _ackRevision = frame.revision;
    }
    if (surface != null && frameReady(surface!.sessionId)) onFrameReady?.call();
  }

  bool frameReady(String sessionId) =>
      surface?.sessionId == sessionId &&
      _ackRevision != null &&
      _frameRevision == _ackRevision;
  static const _licenseFailures = {
    YlFailureCodes.loadCancelled,
    YlFailureCodes.resourceExhausted,
    YlFailureCodes.drmConfigInvalid,
    YlFailureCodes.drmUnsupported,
    YlFailureCodes.drmLicenseDenied,
    YlFailureCodes.drmLicenseRedirectRejected,
    YlFailureCodes.drmLicenseTimeout,
    YlFailureCodes.drmLicenseFailed,
    YlFailureCodes.drmLicenseResponseInvalid,
    YlFailureCodes.drmPayloadTooLarge,
  };
}

final class _DrmContext {
  _DrmContext(this.endpoint);
  final YlDrmLicenseEndpoint endpoint;
  YlProtectedVideoSurface? identity;
  final seen = <String>{};
}
