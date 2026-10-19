import 'dart:async';
import 'live_mode_barrier.dart';

import 'package:flutter/foundation.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'apple_airplay.dart';
import 'apple_callbacks.dart';
import 'apple_codec.dart';
import 'apple_drm.dart';
import 'apple_transport.dart';
import 'pigeon/yl_player_apple.g.dart';

/// Owns one native identity, its callback reducer and in-flight operations.
final class ApplePlayer
    implements
        YlPlatformPlayer,
        YlAirPlayPlatformPlayer,
        YlNetworkTrafficPlatformPlayer,
        YlLivePlaybackPlatformPlayer,
        YlPlatformDrmSourceSupport,
        YlPlatformDrmLicenseTransport,
        YlPlatformProtectedVideoSurfaceProvider,
        YlPlatformNativeVideoSurfaceProvider,
        YlVideoTrackSelectionPlatformPlayer {
  ApplePlayer._(
    this._transport,
    this._suffix,
    this._setupCallbacks,
    this.implementation,
    this.capabilities,
    int texture,
    this.nativeVideoSurface,
    YlPlayerState initial,
    int sequence,
  ) : _texture = ValueNotifier(texture) {
    _callbacks = AppleCallbacks(
      initialState: initial,
      initialSequence: sequence,
      onFullState: _receiveState,
      onNetworkBytes: (requestId, bytes) {
        if (!_disposed && _terminal == null && requestId == _trafficRequestId) {
          _latestNetworkBytes = bytes;
          _networkBytes.add(bytes);
        }
      },
      onLiveState: (snapshot) {
        final live = snapshot.livePlayback;
        if (live != null && snapshot.sessionId != null) {
          _liveModes.snapshot(
            snapshot.sessionId!,
            live.committedRequestId,
            snapshot.revision,
            YlLivePlaybackMode.values.byName(live.mode.name),
          );
        }
      },
      onDelta: _receiveDelta,
      onAcceptedState: (snapshot) {
        if (snapshot.status == YlPlaybackStatus.idle && _pending == null ||
            snapshot.status == YlPlaybackStatus.failed &&
                _currentRequestId == _trafficRequestId) {
          _resetTraffic();
        }
        _states.add(snapshot);
      },
      onEvent: _receiveEvent,
      onInvalid: () =>
          _terminate(AppleCodec.problem(YlFailureCodes.protocolMismatch)),
    );
  }

  @override
  final YlNativeVideoSurface? nativeVideoSurface;

  static const _transportDeadline = Duration(seconds: 5);

  static Future<ApplePlayer> create(
    YlPlayerOptions options, {
    required AppleFactoryTransport factory,
    required AppleTransportFactory transportForSuffix,
    required AppleCallbackSetup setupCallbacks,
    AppleDrmChannel Function(String, AppleDrmSupportMessage)? drmFactory,
    AppleAirPlayChannel Function(String)? airPlayFactory,
  }) async {
    final encoded = AppleCodec.playerOptions(options);
    final AppleCreateReply reply;
    try {
      reply = await factory.create(
        AppleCreateRequest(
          schemaMajor: AppleCodec.schemaMajor,
          options: encoded,
        ),
      );
    } catch (error) {
      throw AppleCodec.exception(error);
    }
    // Take ownership before interpreting any reply field beyond its routing key.
    final transport = transportForSuffix(reply.channelSuffix);
    ApplePlayer? player;
    try {
      if (reply.schemaMajor != AppleCodec.schemaMajor ||
          reply.spiMajor != ylPlayerSpiMajor ||
          reply.channelSuffix.isEmpty) {
        throw AppleCodec.problem(YlFailureCodes.protocolMismatch);
      }
      AppleCodec.integer(reply.textureId);
      final nativeViewType = reply.nativeViewType;
      if (nativeViewType != null && nativeViewType != 'yl_player_apple/video') {
        throw AppleCodec.problem(YlFailureCodes.protocolMismatch);
      }
      final nativeSurface = nativeViewType == null
          ? null
          : YlNativeVideoSurface(
              viewType: nativeViewType,
              platform: switch (reply.platform) {
                ApplePlatform.ios => TargetPlatform.iOS,
                ApplePlatform.macos => TargetPlatform.macOS,
              },
            );
      final initial = AppleCodec.state(reply.initialState);
      final capabilities = AppleCodec.capabilities(reply.capabilities);
      player = ApplePlayer._(
        transport,
        reply.channelSuffix,
        setupCallbacks,
        YlPlatformImplementationInfo(
          name: reply.implementationName,
          version: reply.implementationVersion,
          spiMajor: reply.spiMajor,
        ),
        capabilities,
        reply.textureId,
        nativeSurface,
        initial,
        reply.initialState.sequence,
      );
      if (reply.drmSupport case final support?) {
        if (support.contractVersion != 1 ||
            support.playerId < 0 ||
            support.platform != reply.platform) {
          throw AppleCodec.problem(YlFailureCodes.protocolMismatch);
        }
        player._drm =
            drmFactory?.call(reply.channelSuffix, support) ??
            AppleDrmChannel(reply.channelSuffix, support);
        player._drm!.onFrameReady = player._flushProtectedFrame;
        AppleDrmFlutterApi.setUp(
          player._drm,
          messageChannelSuffix: reply.channelSuffix,
        );
      }
      player._currentRequestId = reply.initialState.loadRequestId;
      setupCallbacks(reply.channelSuffix, player._callbacks);
      await player
          ._run(transport.attach)
          .timeout(
            _transportDeadline,
            onTimeout: () =>
                throw AppleCodec.problem(YlFailureCodes.protocolMismatch),
          );
      if (airPlayFactory != null) {
        player._airPlayChannel = airPlayFactory(reply.channelSuffix);
        final negotiated = await player
            ._run(
              () => player!._airPlayChannel!.negotiate(
                onState: player._receiveAirPlay,
                onError: player._terminate,
              ),
            )
            .timeout(
              _transportDeadline,
              onTimeout: () =>
                  throw AppleCodec.problem(YlFailureCodes.protocolMismatch),
            );
        if (negotiated != null) {
          player._airPlaySupported = true;
          player._routePicker = YlAirPlayRoutePickerSurface(
            platform: reply.platform == ApplePlatform.ios
                ? TargetPlatform.iOS
                : TargetPlatform.macOS,
            channelSuffix: reply.channelSuffix,
          );
          player._receiveAirPlay(negotiated);
          player._airPlay.value = const YlAirPlayState(supported: true);
        }
      }
      player._checkAlive();
      return player;
    } catch (error) {
      final failure = error is ArgumentError
          ? AppleCodec.problem(YlFailureCodes.protocolMismatch)
          : AppleCodec.exception(error);
      if (player != null) {
        await player.dispose();
      } else {
        await _release(transport);
        try {
          setupCallbacks(reply.channelSuffix, null);
        } catch (_) {
          /* Preserve the original failure. */
        }
      }
      throw failure;
    }
  }

  AppleAirPlayChannel? _airPlayChannel;
  bool _airPlaySupported = false;
  bool _airPlayCommitted = false;
  int _airPlayRevision = -1;
  YlPlaybackSessionId? _airPlayStoppedSession;
  final _airPlay = ValueNotifier(const YlAirPlayState());
  YlAirPlayRoutePickerSurface? _routePicker;
  @override
  ValueListenable<YlAirPlayState> get airPlayState => _airPlay;
  @override
  YlAirPlayRoutePickerSurface? get airPlayRoutePickerSurface => _routePicker;

  void _resetAirPlay() {
    _airPlay.value = YlAirPlayState(supported: _airPlaySupported);
  }

  void _receiveAirPlay(AppleAirPlaySnapshot snapshot) {
    if (_disposed ||
        _terminal != null ||
        snapshot.revision <= _airPlayRevision) {
      return;
    }
    _airPlayRevision = snapshot.revision;
    final next = snapshot.state;
    final session = next.sessionId;
    if (session != null && session == _airPlayStoppedSession) return;
    if (session == null) {
      _pending?.airPlaySnapshot = null;
      _resetAirPlay();
      return;
    }
    if (session == state.sessionId &&
        _airPlayCommitted &&
        state.status != YlPlaybackStatus.failed &&
        state.status != YlPlaybackStatus.idle) {
      _airPlay.value = next;
      return;
    }
    final pending = _pending;
    if (pending != null &&
        pending.sent &&
        pending.airPlay &&
        session != state.sessionId) {
      pending.airPlaySnapshot = snapshot;
    }
  }

  void _requireAirPlay() {
    _checkAlive();
    if (!_airPlaySupported) {
      throw AppleCodec.problem(
        YlFailureCodes.policyUnsupported,
        category: YlFailureCategory.unsupported,
        scope: YlFailureScope.command,
      );
    }
  }

  @override
  Future<YlSourceAssessment> assessForAirPlay(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) async {
    _requireAirPlay();
    _validateDrm(source);
    return _assess(
      AppleAssessRequest(
        source: AppleCodec.source(source),
        options: AppleCodec.loadOptions(options),
      ),
      airPlay: true,
    );
  }

  @override
  Future<YlPlatformLoadResult> loadForAirPlay(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) => _beginLoad(source, options: options, airPlay: true);

  AppleDrmChannel? _drm;
  (YlPlayerEvent, int)? _protectedFrame;
  @override
  int get drmContractVersion => _drm == null ? 0 : 1;
  @override
  void setDrmLicenseExchange(YlDrmLicenseExchange exchange) {
    _drm?.exchange = exchange;
  }

  @override
  YlProtectedVideoSurface? get protectedVideoSurface => _drm?.surface;
  @override
  Future<void> attachProtectedView(
    YlProtectedVideoSurface surface,
    int viewId,
  ) async {
    await _drm?.attach(
      surface,
      viewId,
      onFailure: (error) => _terminate(AppleCodec.exception(error)),
    );
  }

  @override
  Future<void> detachProtectedView(
    YlProtectedVideoSurface surface,
    int viewId,
  ) async {
    // Native view disposal is also an idempotent detach. Replacement may retire it first.
    try {
      await _drm?.detach(surface, viewId);
    } catch (_) {}
  }

  void _flushProtectedFrame() {
    final event = _protectedFrame;
    if (event != null && _drm?.frameReady(event.$1.sessionId.value) == true) {
      _protectedFrame = null;
      _receiveEvent(event.$1, event.$2);
    }
  }

  void _validateDrm(YlMediaSource source) {
    if (source is YlNetworkSource && source.drm != null) {
      if (_drm == null) throw ylDrmException(YlFailureCodes.drmUnsupported);
      _drm!.validate(source);
    }
  }

  final ApplePlayerTransport _transport;
  final String _suffix;
  final AppleCallbackSetup _setupCallbacks;
  @override
  final YlPlatformImplementationInfo implementation;
  @override
  final YlPlayerCapabilities capabilities;
  final ValueNotifier<int?> _texture;
  @override
  ValueListenable<int?> get textureId => _texture;
  late final AppleCallbacks _callbacks;
  @override
  YlPlayerState get state => _callbacks.state;
  final _states = StreamController<YlPlayerState>.broadcast();
  final _events = StreamController<YlPlayerEvent>.broadcast();
  @override
  Stream<YlPlayerState> get states => _states.stream;
  @override
  Stream<YlPlayerEvent> get events => _events.stream;

  final _liveModes = LiveModeBarrier();
  int _liveTransports = 0;

  final _commands = <void Function(YlPlayerException)>{};
  // Only the current snapshot can need an additional Stop fence before idle.
  // Other callbacks must prove current request/session authority at ingress.
  YlPlaybackSessionId? _stoppedSession;

  @visibleForTesting
  int get retainedSessionAuthorityCount =>
      (_currentRequestId == null ? 0 : 1) +
      (_stoppedSession == null ? 0 : 1) +
      (_pending?.states.length ?? 0) +
      (_pending?.reply == null ? 0 : 1);

  _PendingLoad? _pending;
  int _requestCounter = 0;
  String? _currentRequestId;
  String? _trafficRequestId;
  final _networkBytes = StreamController<int?>.broadcast();
  int? _latestNetworkBytes;
  @override
  Stream<int?> get networkBytesReceived => Stream.multi((listener) {
    listener.add(_latestNetworkBytes);
    final subscription = _networkBytes.stream.listen(
      listener.add,
      onError: listener.addError,
      onDone: listener.close,
    );
    listener.onCancel = subscription.cancel;
  }, isBroadcast: true);
  void _resetTraffic([String? requestId]) {
    _trafficRequestId = requestId;
    _latestNetworkBytes = null;
    _networkBytes.add(null);
  }

  YlPlayerException? _terminal;
  bool _disposed = false;
  Future<void>? _disposeFuture;

  YlPlayerException get _cancelled => AppleCodec.problem(
    YlFailureCodes.loadCancelled,
    category: YlFailureCategory.cancelled,
    scope: YlFailureScope.command,
  );
  void _checkAlive() {
    if (_terminal case final terminal?) throw terminal;
    if (_disposed) {
      throw AppleCodec.problem(
        YlFailureCodes.playerDisposed,
        category: YlFailureCategory.cancelled,
      );
    }
  }

  /// The error listener remains on the native Future after local cancellation.
  /// Removable registrations retain only currently outstanding Dart commands.
  Future<T> _run<T>(
    Future<T> Function() invoke, {
    _PendingLoad? owner,
    void Function(T)? onLateValue,
    Future<void>? cancelled,
  }) {
    _checkAlive();
    final completion = Completer<T>();
    void cancel(YlPlayerException error) {
      _commands.remove(cancel);
      owner?.commands.remove(cancel);
      if (!completion.isCompleted) completion.completeError(error);
    }

    cancelled?.then<void>(
      (_) {},
      onError: (Object error) {
        cancel(AppleCodec.exception(error));
      },
    );
    _commands.add(cancel);
    owner?.commands.add(cancel);
    Future<T>.sync(invoke).then(
      (value) {
        _commands.remove(cancel);
        owner?.commands.remove(cancel);
        if (!completion.isCompleted) {
          completion.complete(value);
        } else {
          onLateValue?.call(value);
        }
      },
      onError: (Object error, StackTrace stack) {
        _commands.remove(cancel);
        owner?.commands.remove(cancel);
        final failure = AppleCodec.exception(error);
        if (!completion.isCompleted) {
          if (failure.failure.scope == YlFailureScope.player) {
            _terminate(failure);
          }
          if (!completion.isCompleted) completion.completeError(failure);
        }
      },
    );
    return completion.future;
  }

  void _settleCommands(YlPlayerException error) {
    final pending = _commands.toList();
    _commands.clear();
    for (final cancel in pending) {
      cancel(error);
    }
  }

  @override
  Future<YlSourceAssessment> assess(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) async {
    _checkAlive();
    if (options.airPlay) return assessForAirPlay(source, options: options);
    _validateDrm(source);
    final request = AppleAssessRequest(
      source: AppleCodec.source(source),
      options: AppleCodec.loadOptions(options),
    );
    return _assess(request);
  }

  Future<YlSourceAssessment> _assess(
    AppleAssessRequest request, {
    _PendingLoad? owner,
    bool airPlay = false,
  }) async {
    final reply = await _run(
      () => airPlay
          ? _airPlayChannel!.assess(request)
          : _transport.assess(request),
      owner: owner,
    );
    try {
      return AppleCodec.assessment(reply);
    } on ArgumentError {
      final error = AppleCodec.problem(YlFailureCodes.protocolMismatch);
      _terminate(error);
      throw error;
    }
  }

  @override
  Future<YlPlatformLoadResult> load(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) => _beginLoad(source, options: options, airPlay: options.airPlay);

  Future<YlPlatformLoadResult> _beginLoad(
    YlMediaSource source, {
    required YlLoadOptions options,
    required bool airPlay,
  }) {
    try {
      _checkAlive();
      if (airPlay) _requireAirPlay();
      _validateDrm(source);
      final request = AppleLoadRequest(
        loadRequestId: 'load-${++_requestCounter}',
        source: AppleCodec.source(source),
        options: AppleCodec.loadOptions(options),
      );
      _liveModes.cancelAll(_cancelled);
      _cancelLoad(_cancelled);
      _drm?.begin(request.loadRequestId, source);
      _resetTraffic(request.loadRequestId);
      final pending = _PendingLoad(request.loadRequestId, airPlay: airPlay);
      _pending = pending;
      // The public barrier is installed before assessment begins.
      unawaited(_load(pending, request));
      return pending.completion.future;
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  Future<void> _load(_PendingLoad pending, AppleLoadRequest request) async {
    try {
      final assessment = await _assess(
        AppleAssessRequest(source: request.source, options: request.options),
        owner: pending,
        airPlay: pending.airPlay,
      );
      if (_pending != pending) return;
      if (assessment.rejection case final rejection?) {
        throw YlPlayerException(rejection);
      }
      pending.sent = true;
      final reply = await _run(
        () => pending.airPlay
            ? _airPlayChannel!.load(request)
            : _transport.load(request),
        owner: pending,
      );
      if (reply.loadRequestId != pending.requestId) {
        throw AppleCodec.problem(YlFailureCodes.protocolMismatch);
      }
      final session = AppleCodec.session(reply.sessionId);
      if (_pending != pending) return;
      if (session == state.sessionId) {
        throw AppleCodec.problem(YlFailureCodes.protocolMismatch);
      }
      if (_drm == null && reply.protectedSurface != null) {
        throw AppleCodec.problem(YlFailureCodes.protocolMismatch);
      }
      _drm?.checkReply(
        pending.requestId,
        session.value,
        reply.protectedSurface,
      );
      pending.reply = session;
      _startPairDeadline(pending);
      _completePair(pending);
    } catch (error) {
      if (_pending != pending) return;
      final failure = error is ArgumentError
          ? AppleCodec.problem(YlFailureCodes.protocolMismatch)
          : AppleCodec.exception(error);
      if (failure.failure.scope == YlFailureScope.player) {
        _terminate(failure);
      } else {
        _cancelLoad(failure);
      }
    }
  }

  void _startPairDeadline(_PendingLoad pending) {
    pending.deadline ??= Timer(_transportDeadline, () {
      if (_pending == pending) {
        _terminate(AppleCodec.problem(YlFailureCodes.protocolMismatch));
      }
    });
  }

  void _receiveState(YlPlayerState next, int sequence, String? requestId) {
    if (_disposed || _terminal != null) return;
    final session = next.sessionId;
    if (session != null && session == _stoppedSession) return;
    final pending = _pending;
    if (session != null) {
      if (session == state.sessionId) {
        if (requestId != _currentRequestId) {
          throw ArgumentError('Session request identity changed.');
        }
      } else if (pending == null ||
          !pending.sent ||
          requestId != pending.requestId) {
        return;
      }
    }
    if (!_callbacks.canAccept(next, sequence)) return;
    final buffered = pending?.states[session];
    if (buffered != null &&
        (next.revision <= buffered.$1.revision || sequence <= buffered.$2)) {
      return;
    }
    if (next.failure?.scope == YlFailureScope.player) {
      _terminate(YlPlayerException(next.failure!));
      return;
    }
    if (session == null || session == state.sessionId) {
      if (session == null) {
        _stoppedSession = null;
        _currentRequestId = null;
        _airPlayCommitted = false;
        _resetAirPlay();
      }
      _callbacks.acceptState(next, sequence);
      // A retained session may fail while an unrelated candidate is assessed
      // or paired. Only a failure attributed to this candidate cancels it.
      if (next.failure case final failure?) {
        if (pending?.requestId == requestId) {
          _cancelLoad(YlPlayerException(failure));
        }
      }
      return;
    }
    if (pending == null || !pending.sent) return;
    if (AppleCallbacks.hasReadyEvidence(next)) {
      pending.readySessions.add(session);
    }
    final snapshot = (next, sequence);
    pending.firstStates.putIfAbsent(session, () => snapshot);
    if (next.status == YlPlaybackStatus.ready ||
        next.status == YlPlaybackStatus.playing ||
        next.metrics.loadToReady != null) {
      pending.readyStates.putIfAbsent(session, () => snapshot);
    }
    pending.states[session] = snapshot;
    if (next.failure case final failure?) {
      _cancelLoad(YlPlayerException(failure));
      return;
    }
    _startPairDeadline(pending);
    _completePair(pending);
  }

  void _receiveDelta(AppleStateDeltaMessage delta) {
    final session = YlPlaybackSessionId(delta.sessionId);
    final pending = _pending;
    // Pairing installs authoritative state immediately; retained snapshots are
    // only replay evidence during the cancellable completion turn.
    final buffered = pending?.paired == true ? null : pending?.states[session];
    final base = buffered?.$1 ?? state;
    if (buffered == null &&
        !_callbacks.isNewer(delta.revision, delta.sequence)) {
      return;
    }
    if (base.sessionId != session ||
        delta.previousRevision != base.revision ||
        buffered != null && delta.sequence <= buffered.$2) {
      return;
    }
    _receiveState(
      AppleCodec.delta(base, delta),
      delta.sequence,
      buffered == null ? _currentRequestId : _pending!.requestId,
    );
  }

  void _completePair(_PendingLoad pending) {
    if (pending.paired) return;
    final session = pending.reply;
    final match = pending.states[session];
    if (session == null || match == null) return;
    if (!_callbacks.canAccept(match.$1, match.$2)) {
      _liveModes.cancelAll(_cancelled);
      _cancelLoad(_cancelled);
      return;
    }
    if (match.$1.failure case final failure?) {
      _cancelLoad(YlPlayerException(failure));
      return;
    }
    _stoppedSession = null;
    _airPlayStoppedSession = null;
    _airPlayCommitted = pending.airPlay;
    final route = pending.airPlaySnapshot;
    _airPlay.value = pending.airPlay && route?.state.sessionId == session
        ? route!.state
        : YlAirPlayState(supported: _airPlaySupported);
    _currentRequestId = pending.requestId;
    _drm?.commit(pending.requestId);
    _protectedFrame = null;
    pending.paired = true;
    pending.deadline?.cancel();
    // Retain only the first, first semantic READY and latest full snapshots.
    // Replaying their real revisions lets the public controller observe Ready
    // even when timing metrics are unknown and the final state is buffering.
    final snapshots = <int, (YlPlayerState, int)>{};
    for (final snapshot in [
      pending.firstStates[session],
      pending.readyStates[session],
      match,
    ]) {
      if (snapshot != null) snapshots[snapshot.$1.revision] = snapshot;
    }
    final ordered = snapshots.values.toList()
      ..sort((a, b) => a.$2.compareTo(b.$2));
    for (final snapshot in ordered) {
      _callbacks.acceptState(
        snapshot.$1,
        snapshot.$2,
        readyObserved:
            snapshot == match && pending.readySessions.contains(session),
      );
    }
    // Events retain their own ingress order; no combined observer ordering
    // across the two asynchronous public streams is promised.
    for (final event in pending.events) {
      _receiveEvent(event.$1, event.$2);
    }
    // Let the queued state chronology reach asynchronous stream consumers
    // before their await-load continuation reads the final backend snapshot.
    // This waits for no external observer and remains cancellable throughout.
    pending.publication = Timer(Duration.zero, () {
      if (_pending != pending) return;
      _pending = null;
      pending.completion.complete(YlPlatformLoadResult(sessionId: session));
    });
  }

  void _receiveEvent(YlPlayerEvent event, int sequence) {
    if (_disposed || _terminal != null || event.sessionId == _stoppedSession) {
      return;
    }
    if (event.sessionId != state.sessionId) {
      final pending = _pending;
      if (pending != null &&
          pending.sent &&
          (pending.reply == event.sessionId ||
              pending.states.containsKey(event.sessionId))) {
        if (event is YlPlaybackFailedEvent) {
          if (event.failure.scope == YlFailureScope.player) {
            _terminate(YlPlayerException(event.failure));
          } else {
            _cancelLoad(YlPlayerException(event.failure));
          }
        } else {
          pending.events.add((event, sequence));
        }
      }
      return;
    }
    if (event is YlFirstFrameEvent &&
        _drm?.surface?.sessionId == event.sessionId.value &&
        _drm?.frameReady(event.sessionId.value) != true) {
      _protectedFrame = (event, sequence);
      return;
    }
    if (!_callbacks.acceptEvent(event, sequence)) return;
    _events.add(event);
    if (event is YlPlaybackFailedEvent) {
      if (event.failure.scope == YlFailureScope.player) {
        _terminate(YlPlayerException(event.failure));
      } else if (_pending?.reply == event.sessionId) {
        _cancelLoad(YlPlayerException(event.failure));
      }
    }
  }

  void _cancelLoad(YlPlayerException error) {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    if (_trafficRequestId == pending.requestId) _resetTraffic();
    _drm?.cancel(pending.requestId);
    pending.deadline?.cancel();
    pending.publication?.cancel();
    if (pending.paired && pending.reply == state.sessionId) {
      _stoppedSession = pending.reply;
      _airPlayStoppedSession = pending.reply;
      _resetAirPlay();
    }
    for (final cancel in pending.commands.toList()) {
      cancel(error);
    }
    // A still-outstanding native Future may retain its cancelled owner. Release
    // invalidated snapshots now instead of retaining them until its late reply.
    pending.reply = null;
    pending.states.clear();
    pending.firstStates.clear();
    pending.readyStates.clear();
    pending.readySessions.clear();
    pending.events.clear();
    pending.airPlaySnapshot = null;
    pending.completion.completeError(error);
  }

  Future<void> _sessionCommand(
    YlPlaybackSessionId session,
    Future<void> Function() invoke,
  ) async {
    _checkAlive();
    validateYlPlaybackSessionId(session);
    if (state.sessionId != session || session == _stoppedSession) {
      throw AppleCodec.problem(
        YlFailureCodes.sessionStale,
        category: YlFailureCategory.cancelled,
        scope: YlFailureScope.command,
      );
    }
    await _run(invoke);
  }

  @override
  Future<void> play(YlPlaybackSessionId sessionId) => _sessionCommand(
    sessionId,
    () => _transport.play(AppleSessionCommand(sessionId: sessionId.value)),
  );
  @override
  Future<void> pause(YlPlaybackSessionId sessionId) => _sessionCommand(
    sessionId,
    () => _transport.pause(AppleSessionCommand(sessionId: sessionId.value)),
  );
  @override
  Future<void> seekTo(YlPlaybackSessionId sessionId, Duration position) async {
    validateYlSeekPosition(position);
    await _sessionCommand(
      sessionId,
      () => _transport.seekTo(
        AppleSeekCommand(
          sessionId: sessionId.value,
          positionMs: position.inMilliseconds,
        ),
      ),
    );
  }

  @override
  Future<void> seekToLiveEdge(YlPlaybackSessionId sessionId) => _sessionCommand(
    sessionId,
    () => _transport.seekToLiveEdge(
      AppleSessionCommand(sessionId: sessionId.value),
    ),
  );
  @override
  Future<void> setPlaybackSpeed(
    YlPlaybackSessionId sessionId,
    double speed,
  ) async {
    validateYlPlaybackSpeed(speed);
    await _sessionCommand(
      sessionId,
      () => _transport.setPlaybackSpeed(
        AppleSpeedCommand(sessionId: sessionId.value, speed: speed),
      ),
    );
  }

  @override
  Future<void> selectAudioTrack(
    YlPlaybackSessionId sessionId,
    String trackId,
  ) async {
    validateYlTrackId(trackId);
    await _sessionCommand(
      sessionId,
      () => _transport.selectAudioTrack(
        AppleTrackCommand(sessionId: sessionId.value, trackId: trackId),
      ),
    );
  }

  @override
  Future<void> selectVideoTrack(
    YlPlaybackSessionId sessionId,
    String? trackId,
  ) async {
    if (trackId != null) validateYlTrackId(trackId);
    await _sessionCommand(
      sessionId,
      () => _transport.selectVideoTrack(
        AppleVideoTrackCommand(sessionId: sessionId.value, trackId: trackId),
      ),
    );
  }

  @override
  Future<void> setVideoConstraints(
    YlPlaybackSessionId sessionId,
    YlVideoConstraints constraints,
  ) async {
    final encoded = AppleCodec.constraints(constraints);
    await _sessionCommand(
      sessionId,
      () => _transport.setVideoConstraints(
        AppleVideoConstraintsCommand(
          sessionId: sessionId.value,
          constraints: encoded,
        ),
      ),
    );
  }

  @override
  Future<void> setLivePlaybackMode(
    YlPlaybackSessionId sessionId,
    YlLivePlaybackMode mode,
  ) async {
    _checkAlive();
    validateYlPlaybackSessionId(sessionId);
    if (state.sessionId != sessionId || _stoppedSession == sessionId) {
      throw AppleCodec.problem(
        YlFailureCodes.sessionStale,
        category: YlFailureCategory.cancelled,
        scope: YlFailureScope.command,
      );
    }
    if (!capabilities.supportedOperations.contains(
          YlPlayerOperation.livePlaybackMode,
        ) ||
        state.status == YlPlaybackStatus.failed ||
        state.livePlayback?.switchableModes.contains(mode) != true) {
      throw AppleCodec.problem(
        YlFailureCodes.policyUnsupported,
        category: YlFailureCategory.unsupported,
        scope: YlFailureScope.command,
      );
    }
    if (_liveTransports >= 32) {
      throw AppleCodec.problem(
        YlFailureCodes.resourceExhausted,
        category: YlFailureCategory.resource,
        scope: YlFailureScope.command,
      );
    }
    final request = _liveModes.begin(sessionId.value, mode, state.revision);
    _liveTransports++;
    unawaited(
      _run(
        () => _transport
            .setLivePlaybackMode(
              AppleLivePlaybackModeCommand(
                sessionId: sessionId.value,
                requestId: request.id,
                mode: AppleLivePlaybackMode.values.byName(mode.name),
              ),
            )
            .whenComplete(() {
              _liveTransports--;
            }),
        cancelled: request.future,
      ).then(
        (reply) {
          _liveModes.reply(
            request.id,
            reply.sessionId,
            reply.requestId,
            reply.committedRevision,
          );
        },
        onError: (Object error) {
          _liveModes.fail(request.id, error);
        },
      ),
    );
    await request.future;
  }

  @override
  Future<void> setVolume(double volume) async {
    _checkAlive();
    validateYlVolume(volume);
    await _run(() => _transport.setVolume(volume));
  }

  @override
  Future<void> stop() async {
    _checkAlive();
    final captured = state.sessionId;
    _resetTraffic();
    _liveModes.cancelAll(_cancelled);
    _cancelLoad(_cancelled);
    _drm?.stop();
    _protectedFrame = null;
    await _run(_transport.stop);
    // Only the accepted Stop's captured identity is fenced; idle is authoritative.
    if (captured != null && captured == state.sessionId) {
      _stoppedSession = captured;
      _airPlayStoppedSession = captured;
      _resetAirPlay();
    }
  }

  void _terminate(YlPlayerException error) {
    if (_terminal != null || _disposed) return;
    _terminal = error;
    _resetTraffic();
    final revisionExhausted = state.revision == 0x7fffffffffffffff;
    _callbacks.state = state.copyWith(
      revision: revisionExhausted ? state.revision : state.revision + 1,
      status: YlPlaybackStatus.failed,
      failure: error.failure,
    );
    _states.add(state);
    if (revisionExhausted) {
      // No higher valid revision exists. Stream termination still settles
      // revision-filtering consumers immediately, before native release.
      unawaited(_states.close());
      unawaited(_events.close());
    }
    _cancelLoad(error);
    _liveModes.cancelAll(error);
    _settleCommands(error);
    unawaited(dispose());
  }

  static Future<void> _release(ApplePlayerTransport transport) async {
    try {
      await Future<void>.sync(transport.dispose).timeout(_transportDeadline);
    } catch (_) {
      /* Cleanup is bounded best effort. */
    }
  }

  @override
  Future<void> dispose() {
    if (_disposeFuture case final result?) return result;
    _disposed = true;
    _airPlayChannel?.close();
    _airPlaySupported = false;
    _routePicker = null;
    _resetAirPlay();
    _resetTraffic();
    _drm?.close();
    _protectedFrame = null;
    _callbacks.close();
    final error =
        _terminal ??
        AppleCodec.problem(
          YlFailureCodes.playerDisposed,
          category: YlFailureCategory.cancelled,
        );
    _cancelLoad(error);
    _liveModes.cancelAll(error);
    _settleCommands(error);
    _currentRequestId = null;
    _stoppedSession = null;
    return _disposeFuture = _dispose();
  }

  Future<void> _dispose() async {
    await _release(_transport);
    try {
      _setupCallbacks(_suffix, null);
      if (_drm != null) {
        AppleDrmFlutterApi.setUp(null, messageChannelSuffix: _suffix);
      }
    } catch (_) {
      /* Never strand owned Dart resources. */
    }
    // Closing paused broadcast streams may wait for outside observers forever.
    unawaited(_states.close());
    unawaited(_events.close());
    unawaited(_networkBytes.close());
    _texture.value = null;
    _texture.dispose();
  }
}

final class _PendingLoad {
  _PendingLoad(this.requestId, {required this.airPlay});
  final bool airPlay;
  AppleAirPlaySnapshot? airPlaySnapshot;
  final String requestId;
  final commands = <void Function(YlPlayerException)>{};
  final completion = Completer<YlPlatformLoadResult>();
  bool sent = false;
  bool paired = false;
  YlPlaybackSessionId? reply;
  final states = <YlPlaybackSessionId, (YlPlayerState, int)>{};
  final firstStates = <YlPlaybackSessionId, (YlPlayerState, int)>{};
  final readyStates = <YlPlaybackSessionId, (YlPlayerState, int)>{};
  final events = <(YlPlayerEvent, int)>[];
  final readySessions = <YlPlaybackSessionId>{};
  Timer? deadline;
  Timer? publication;
}
