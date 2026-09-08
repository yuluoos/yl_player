import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'android_callbacks.dart';
import 'android_codec.dart';
import 'android_transport.dart';
import 'pigeon/yl_player_android.g.dart';

/// Owns one native identity, its callback reducer and in-flight operations.
final class AndroidPlayer implements YlPlatformPlayer {
  AndroidPlayer._(
    this._transport,
    this._suffix,
    this._setupCallbacks,
    this.implementation,
    this.capabilities,
    int texture,
    YlPlayerState initial,
    int sequence,
  ) : _texture = ValueNotifier(texture) {
    _callbacks = AndroidCallbacks(
      initialState: initial,
      initialSequence: sequence,
      onFullState: _receiveState,
      onDelta: _receiveDelta,
      onAcceptedState: _states.add,
      onEvent: _receiveEvent,
      onInvalid: () =>
          _terminate(AndroidCodec.problem(YlFailureCodes.protocolMismatch)),
    );
  }

  static const _transportDeadline = Duration(seconds: 5);

  static Future<AndroidPlayer> create(
    YlPlayerOptions options, {
    required AndroidFactoryTransport factory,
    required AndroidTransportFactory transportForSuffix,
    required AndroidCallbackSetup setupCallbacks,
  }) async {
    final encoded = AndroidCodec.playerOptions(options);
    final AndroidCreateReply reply;
    try {
      reply = await factory.create(
        AndroidCreateRequest(
          schemaMajor: AndroidCodec.schemaMajor,
          options: encoded,
        ),
      );
    } catch (error) {
      throw AndroidCodec.exception(error);
    }
    // Take ownership before interpreting any reply field beyond its routing key.
    final transport = transportForSuffix(reply.channelSuffix);
    AndroidPlayer? player;
    try {
      if (reply.schemaMajor != AndroidCodec.schemaMajor ||
          reply.spiMajor != ylPlayerSpiMajor ||
          reply.channelSuffix.isEmpty) {
        throw AndroidCodec.problem(YlFailureCodes.protocolMismatch);
      }
      AndroidCodec.integer(reply.textureId);
      final initial = AndroidCodec.state(reply.initialState);
      final capabilities = AndroidCodec.capabilities(reply.capabilities);
      player = AndroidPlayer._(
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
        initial,
        reply.initialState.sequence,
      );
      player._currentRequestId = reply.initialState.loadRequestId;
      setupCallbacks(reply.channelSuffix, player._callbacks);
      await player
          ._run(transport.attach)
          .timeout(
            _transportDeadline,
            onTimeout: () =>
                throw AndroidCodec.problem(YlFailureCodes.protocolMismatch),
          );
      player._checkAlive();
      return player;
    } catch (error) {
      final failure = error is ArgumentError
          ? AndroidCodec.problem(YlFailureCodes.protocolMismatch)
          : AndroidCodec.exception(error);
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

  final AndroidPlayerTransport _transport;
  final String _suffix;
  final AndroidCallbackSetup _setupCallbacks;
  @override
  final YlPlatformImplementationInfo implementation;
  @override
  final YlPlayerCapabilities capabilities;
  final ValueNotifier<int?> _texture;
  @override
  ValueListenable<int?> get textureId => _texture;
  late final AndroidCallbacks _callbacks;
  @override
  YlPlayerState get state => _callbacks.state;
  final _states = StreamController<YlPlayerState>.broadcast();
  final _events = StreamController<YlPlayerEvent>.broadcast();
  @override
  Stream<YlPlayerState> get states => _states.stream;
  @override
  Stream<YlPlayerEvent> get events => _events.stream;

  final _commands = <void Function(YlPlayerException)>{};
  final _retired = <YlPlaybackSessionId>{};
  _PendingLoad? _pending;
  int _requestCounter = 0;
  String? _currentRequestId;
  YlPlayerException? _terminal;
  bool _disposed = false;
  Future<void>? _disposeFuture;

  YlPlayerException get _cancelled => AndroidCodec.problem(
    YlFailureCodes.loadCancelled,
    category: YlFailureCategory.cancelled,
    scope: YlFailureScope.command,
  );
  void _checkAlive() {
    if (_terminal case final terminal?) throw terminal;
    if (_disposed) {
      throw AndroidCodec.problem(
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
  }) {
    _checkAlive();
    final completion = Completer<T>();
    void cancel(YlPlayerException error) {
      _commands.remove(cancel);
      owner?.commands.remove(cancel);
      if (!completion.isCompleted) completion.completeError(error);
    }

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
        final failure = AndroidCodec.exception(error);
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
    final request = AndroidAssessRequest(
      source: AndroidCodec.source(source),
      options: AndroidCodec.loadOptions(options),
    );
    return _assess(request);
  }

  Future<YlSourceAssessment> _assess(
    AndroidAssessRequest request, {
    _PendingLoad? owner,
  }) async {
    final reply = await _run(() => _transport.assess(request), owner: owner);
    try {
      return AndroidCodec.assessment(reply);
    } on ArgumentError {
      final error = AndroidCodec.problem(YlFailureCodes.protocolMismatch);
      _terminate(error);
      throw error;
    }
  }

  @override
  Future<YlPlatformLoadResult> load(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) {
    try {
      _checkAlive();
      final request = AndroidLoadRequest(
        loadRequestId: 'load-${++_requestCounter}',
        source: AndroidCodec.source(source),
        options: AndroidCodec.loadOptions(options),
      );
      _cancelLoad(_cancelled);
      final pending = _PendingLoad(request.loadRequestId);
      _pending = pending;
      // The public barrier is installed before assessment begins.
      unawaited(_load(pending, request));
      return pending.completion.future;
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  Future<void> _load(_PendingLoad pending, AndroidLoadRequest request) async {
    try {
      final assessment = await _assess(
        AndroidAssessRequest(source: request.source, options: request.options),
        owner: pending,
      );
      if (_pending != pending) return;
      if (assessment.rejection case final rejection?) {
        throw YlPlayerException(rejection);
      }
      pending.sent = true;
      final reply = await _run(
        () => _transport.load(request),
        owner: pending,
        onLateValue: (reply) {
          // An observed late reply only retires its identity, never revives it.
          if (reply.loadRequestId == pending.requestId &&
              reply.sessionId.isNotEmpty) {
            _retired.add(YlPlaybackSessionId(reply.sessionId));
          }
        },
      );
      if (reply.loadRequestId != pending.requestId) {
        throw AndroidCodec.problem(YlFailureCodes.protocolMismatch);
      }
      final session = AndroidCodec.session(reply.sessionId);
      if (_pending != pending) {
        _retired.add(session);
        return;
      }
      if (_retired.contains(session) || session == state.sessionId) {
        throw AndroidCodec.problem(YlFailureCodes.protocolMismatch);
      }
      pending.reply = session;
      _startPairDeadline(pending);
      _completePair(pending);
    } catch (error) {
      if (_pending != pending) return;
      final failure = error is ArgumentError
          ? AndroidCodec.problem(YlFailureCodes.protocolMismatch)
          : AndroidCodec.exception(error);
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
        _terminate(AndroidCodec.problem(YlFailureCodes.protocolMismatch));
      }
    });
  }

  void _receiveState(YlPlayerState next, int sequence, String? requestId) {
    if (_disposed || _terminal != null) return;
    final session = next.sessionId;
    if (session != null && _retired.contains(session)) return;
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
        if (state.sessionId case final previous?) _retired.add(previous);
        _currentRequestId = null;
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
    if (AndroidCallbacks.hasReadyEvidence(next)) {
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

  void _receiveDelta(AndroidStateDeltaMessage delta) {
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
      AndroidCodec.delta(base, delta),
      delta.sequence,
      buffered == null ? _currentRequestId : _pending!.requestId,
    );
  }

  void _completePair(_PendingLoad pending) {
    if (pending.paired) return;
    final session = pending.reply;
    final match = pending.states[session];
    if (session == null || match == null) return;
    if (_retired.contains(session) ||
        !_callbacks.canAccept(match.$1, match.$2)) {
      _cancelLoad(_cancelled);
      return;
    }
    if (match.$1.failure case final failure?) {
      _cancelLoad(YlPlayerException(failure));
      return;
    }
    final previous = state.sessionId;
    if (previous != null) _retired.add(previous);
    _currentRequestId = pending.requestId;
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
    if (_disposed || _terminal != null || _retired.contains(event.sessionId)) {
      return;
    }
    if (event.sessionId != state.sessionId) {
      final pending = _pending;
      if (pending != null &&
          pending.sent &&
          (pending.reply == event.sessionId ||
              pending.states.containsKey(event.sessionId))) {
        if (event is YlPlaybackFailedEvent) {
          _retired.add(event.sessionId);
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
    pending.deadline?.cancel();
    pending.publication?.cancel();
    _retired.addAll(pending.states.keys);
    if (pending.reply case final reply?) _retired.add(reply);
    for (final cancel in pending.commands.toList()) {
      cancel(error);
    }
    pending.completion.completeError(error);
  }

  Future<void> _sessionCommand(
    YlPlaybackSessionId session,
    Future<void> Function() invoke,
  ) async {
    _checkAlive();
    validateYlPlaybackSessionId(session);
    if (state.sessionId != session || _retired.contains(session)) {
      throw AndroidCodec.problem(
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
    () => _transport.play(AndroidSessionCommand(sessionId: sessionId.value)),
  );
  @override
  Future<void> pause(YlPlaybackSessionId sessionId) => _sessionCommand(
    sessionId,
    () => _transport.pause(AndroidSessionCommand(sessionId: sessionId.value)),
  );
  @override
  Future<void> seekTo(YlPlaybackSessionId sessionId, Duration position) async {
    validateYlSeekPosition(position);
    await _sessionCommand(
      sessionId,
      () => _transport.seekTo(
        AndroidSeekCommand(
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
      AndroidSessionCommand(sessionId: sessionId.value),
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
        AndroidSpeedCommand(sessionId: sessionId.value, speed: speed),
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
        AndroidTrackCommand(sessionId: sessionId.value, trackId: trackId),
      ),
    );
  }

  @override
  Future<void> setVideoConstraints(
    YlPlaybackSessionId sessionId,
    YlVideoConstraints constraints,
  ) async {
    final encoded = AndroidCodec.constraints(constraints);
    await _sessionCommand(
      sessionId,
      () => _transport.setVideoConstraints(
        AndroidVideoConstraintsCommand(
          sessionId: sessionId.value,
          constraints: encoded,
        ),
      ),
    );
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
    _cancelLoad(_cancelled);
    await _run(_transport.stop);
    // Only the accepted Stop's captured identity is fenced; idle is authoritative.
    if (captured != null) _retired.add(captured);
  }

  void _terminate(YlPlayerException error) {
    if (_terminal != null || _disposed) return;
    _terminal = error;
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
    _settleCommands(error);
    unawaited(dispose());
  }

  static Future<void> _release(AndroidPlayerTransport transport) async {
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
    _callbacks.closed = true;
    final error =
        _terminal ??
        AndroidCodec.problem(
          YlFailureCodes.playerDisposed,
          category: YlFailureCategory.cancelled,
        );
    _cancelLoad(error);
    _settleCommands(error);
    return _disposeFuture = _dispose();
  }

  Future<void> _dispose() async {
    await _release(_transport);
    try {
      _setupCallbacks(_suffix, null);
    } catch (_) {
      /* Never strand owned Dart resources. */
    }
    // Closing paused broadcast streams may wait for outside observers forever.
    unawaited(_states.close());
    unawaited(_events.close());
    _texture.value = null;
    _texture.dispose();
  }
}

final class _PendingLoad {
  _PendingLoad(this.requestId);
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
