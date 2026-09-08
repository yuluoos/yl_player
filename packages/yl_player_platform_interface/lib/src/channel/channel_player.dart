import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../yl_player_platform_interface.dart';
import 'channel_codec.dart';

/// Temporary bridge. Unversioned legacy events can only be associated with the
/// currently accepted source; typed transports will replace this limitation.
final class _LegacyChannelPlayer implements YlPlatformPlayer {
  _LegacyChannelPlayer({
    required this.playerId,
    required int texture,
    required this.methods,
    required Stream<Object?> nativeEvents,
    required this.platform,
    required this.initialEngine,
    required this.options,
    required this.transportTimeout,
  }) : _texture = ValueNotifier(texture) {
    _subscription = nativeEvents.listen(
      _accept,
      onError: (Object _) => _protocolFailure(),
      onDone: _protocolFailure,
    );
    if (_disposed) {
      unawaited(_subscription!.cancel().catchError((Object _) {}));
    }
  }
  final int playerId;
  final MethodChannel methods;
  final String platform;
  final YlPlaybackEngine initialEngine;
  final YlPlayerOptions options;
  final Duration transportTimeout;
  final ValueNotifier<int?> _texture;
  StreamSubscription<Object?>? _subscription;
  final _pendingCommands = <Completer<void>>{};
  @visibleForTesting
  int get debugPendingCommandCount => _pendingCommands.length;
  YlPlayerException? _terminalError;
  final _states = StreamController<YlPlayerState>.broadcast(sync: true);
  final _events = StreamController<YlPlayerEvent>.broadcast(sync: true);
  final _initial = Completer<void>();
  final _clock = Stopwatch()..start();
  YlPlayerState _state = YlPlayerState();
  late YlPlayerCapabilities _capabilities;
  int? _generation;
  int _serial = 0;
  _LoadBarrier? _load;
  bool _disposed = false;
  bool _firstFrame = false;
  Future<void>? _disposeFuture;
  @override
  YlPlatformImplementationInfo get implementation =>
      YlPlatformImplementationInfo(
        name: 'legacy.$platform',
        version: '0.2.0-dev',
        spiMajor: ylPlayerSpiMajor,
      );
  @override
  YlPlayerCapabilities get capabilities => _capabilities;
  @override
  ValueListenable<int?> get textureId => _texture;
  @override
  YlPlayerState get state => _state;
  @override
  Stream<YlPlayerState> get states => _states.stream;
  @override
  Stream<YlPlayerEvent> get events => _events.stream;
  void _check() {
    if (_disposed) throw legacyException(YlFailureCodes.playerDisposed);
  }

  void _checkSession(YlPlaybackSessionId id) {
    _check();
    if (id != state.sessionId ||
        state.status == YlPlaybackStatus.idle ||
        state.status == YlPlaybackStatus.failed) {
      throw legacyException(YlFailureCodes.sessionStale);
    }
  }

  @override
  Future<YlSourceAssessment> assess(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) async {
    _check();
    validateYlSource(source);
    validateYlLoadOptions(options);
    final strict =
        options.bufferStrategy.kind == YlBufferStrategyKind.bounded ||
        (options.decoderPolicyOverride ?? this.options.decoderPolicy) ==
            YlDecoderPolicy.hardwareRequired ||
        source is YlNetworkSource &&
            source.networkPolicy.kind == YlNetworkPolicyKind.managed;
    final credentialsUnsupported =
        source is YlNetworkSource &&
        source.request.credentials.isNotEmpty &&
        (platform == 'android' || !_isHls(source));
    if (strict ||
        credentialsUnsupported ||
        source is YlAndroidContentSource && platform != 'android') {
      return YlSourceAssessment(
        outcome: YlSourceAssessmentOutcome.incompatible,
        rejection: legacyException(YlFailureCodes.policyUnsupported).failure,
      );
    }
    return YlSourceAssessment(
      outcome: YlSourceAssessmentOutcome.requiresInspection,
      limitations: const [
        YlLimitationId.sourceRequiresInspection,
        YlLimitationId.decoderModeUnknown,
        YlLimitationId.networkSystemStackOpaque,
      ],
    );
  }

  bool _isHls(YlNetworkSource source) =>
      source.format == YlMediaFormat.hls ||
      source.format == YlMediaFormat.automatic &&
          source.uri.path.toLowerCase().endsWith('.m3u8');
  @override
  Future<YlPlatformLoadResult> load(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) async {
    _check();
    validateYlSource(source);
    validateYlLoadOptions(options);
    final serial = ++_serial;
    _cancelLoad();
    final assessment = await assess(source, options: options);
    if (serial != _serial) throw legacyException(YlFailureCodes.loadCancelled);
    if (assessment.rejection case final rejection?) {
      throw YlPlayerException(rejection);
    }
    _check();
    final barrier = _LoadBarrier(serial);
    _load = barrier;
    // Attach the observer before native callbacks can reject the barrier.
    unawaited(
      barrier.result.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
    unawaited(_open(barrier, source, options));
    try {
      return await barrier.result.future;
    } finally {
      barrier.pairingTimer?.cancel();
      if (identical(_load, barrier)) _load = null;
    }
  }

  Future<void> _open(
    _LoadBarrier barrier,
    YlMediaSource source,
    YlLoadOptions options,
  ) async {
    try {
      final reply = await methods.invokeMapMethod<String, Object?>('command', {
        'playerId': playerId,
        'name': 'open',
        'arguments': {
          'source': {
            ...encodeYlSource(source),
            'loadOptions': encodeYlLoadOptions(options),
            'loadToken': barrier.serial,
          },
        },
      });
      if (!identical(_load, barrier) || _disposed) return;
      if (reply?['loadToken'] != barrier.serial) {
        _protocolFailure();
        unawaited(dispose());
        return;
      }
      barrier.replied = true;
      _completeLoad();
    } catch (error) {
      if (!barrier.result.isCompleted) {
        barrier.result.completeError(
          error is PlatformException
              ? decodeYlPlatformException(error)
              : error is YlPlayerException
              ? error
              : legacyException(YlFailureCodes.platformFailure),
        );
      }
    }
  }

  void _completeLoad() {
    final load = _load;
    if (load != null &&
        !load.result.isCompleted &&
        (load.replied || load.session != null)) {
      load.pairingTimer ??= Timer(transportTimeout, () {
        if (!identical(_load, load) || load.result.isCompleted || _disposed) {
          return;
        }
        load.result.completeError(
          legacyException(YlFailureCodes.protocolMismatch),
        );
        // One half proves a possible native commit. End the damaged transport,
        // rather than pretending this was a pre-commit source rejection.
        unawaited(dispose());
      });
    }
    if (load != null &&
        load.replied &&
        load.session != null &&
        !load.result.isCompleted) {
      if (load.session != state.sessionId) {
        load.result.completeError(
          legacyException(YlFailureCodes.loadCancelled),
        );
      } else {
        load.result.complete(YlPlatformLoadResult(sessionId: load.session!));
      }
    }
  }

  void _cancelLoad() {
    final load = _load;
    _load = null;
    if (load != null && !load.result.isCompleted) {
      load.pairingTimer?.cancel();
      load.result.completeError(legacyException(YlFailureCodes.loadCancelled));
      if (!_disposed) {
        unawaited(
          _command('cancelOpen', {
            'loadToken': load.serial,
          }).then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        );
      }
    }
  }

  @override
  Future<void> play(YlPlaybackSessionId id) => _sessionCommand(id, 'play');
  @override
  Future<void> pause(YlPlaybackSessionId id) => _sessionCommand(id, 'pause');
  @override
  Future<void> seekTo(YlPlaybackSessionId id, Duration position) {
    validateYlSeekPosition(position);
    return _sessionCommand(id, 'seekTo', {
      'positionMs': position.inMilliseconds,
    });
  }

  @override
  Future<void> seekToLiveEdge(YlPlaybackSessionId id) =>
      _sessionCommand(id, 'seekToLiveEdge');
  @override
  Future<void> setPlaybackSpeed(YlPlaybackSessionId id, double speed) {
    validateYlPlaybackSpeed(speed);
    return _sessionCommand(id, 'setPlaybackSpeed', {'speed': speed});
  }

  @override
  Future<void> selectAudioTrack(YlPlaybackSessionId id, String trackId) {
    validateYlTrackId(trackId);
    return _sessionCommand(id, 'selectAudioTrack', {'trackId': trackId});
  }

  @override
  Future<void> setVideoConstraints(
    YlPlaybackSessionId id,
    YlVideoConstraints constraints,
  ) {
    validateYlVideoConstraints(constraints);
    return _sessionCommand(id, 'setQualityConstraint', {
      'constraint': encodeYlVideoConstraints(constraints),
    });
  }

  @override
  Future<void> setVolume(double volume) {
    validateYlVolume(volume);
    return _command('setVolume', {'volume': volume});
  }

  @override
  Future<void> stop() {
    _check();
    ++_serial;
    _cancelLoad();
    return _command('stop');
  }

  Future<void> _sessionCommand(
    YlPlaybackSessionId id,
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    _checkSession(id);
    await _command(name, args);
  }

  Future<void> _command(
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    _check();
    final pending = Completer<void>();
    _pendingCommands.add(pending);
    try {
      unawaited(
        methods
            .invokeMethod<void>('command', {
              'playerId': playerId,
              'name': name,
              'arguments': args,
            })
            .then<void>(
              (_) {
                if (!pending.isCompleted) pending.complete();
              },
              onError: (Object error, StackTrace stack) {
                if (!pending.isCompleted) pending.completeError(error, stack);
              },
            ),
      );
      await pending.future;
    } on PlatformException catch (e) {
      throw decodeYlPlatformException(e);
    } on MissingPluginException {
      throw legacyException(YlFailureCodes.platformUnavailable);
    } finally {
      _pendingCommands.remove(pending);
    }
  }

  void _accept(Object? value) {
    if (_disposed || value is! Map || value['playerId'] != playerId) return;
    final map = ylStringMap(value);
    try {
      if (map['type'] == 'fallbackActivated' ||
          map['type'] == 'tracksChanged' ||
          map['type'] == 'fallback') {
        return;
      }
      if (map['type'] == 'state' || map['type'] == 'stateDelta') {
        final generation = ylWireInt(map['generation']);
        if (map['protocolVersion'] != 1 || generation == null) {
          _protocolFailure();
          return;
        }
        if (_generation != null && generation < _generation!) return;
        final previous = _state;
        if (map['type'] == 'stateDelta') {
          if (generation != _generation) return;
          if (map['delta'] is! Map) {
            _protocolFailure();
            return;
          }
          _state = mergeYlStateDelta(
            _state,
            map['delta'],
            revision: _state.revision + 1,
          );
        } else {
          if (map['state'] is! Map) {
            _protocolFailure();
            return;
          }
          final raw = ylStringMap(map['state']);
          if (!_initial.isCompleted) {
            _capabilities = decodeYlCapabilities(
              raw['capabilities'],
              platform: platform,
              initialEngine: initialEngine,
            );
          }
          _state = decodeYlState(
            raw,
            sessionId: YlPlaybackSessionId(
              'legacy:$platform:$playerId:$generation',
            ),
            revision: _state.revision + 1,
          );
          _generation = generation;
          if (previous.sessionId != state.sessionId) _firstFrame = false;
          if (!_initial.isCompleted) _initial.complete();
          if (_load case final load?
              when map['loadToken'] == load.serial && state.sessionId != null) {
            load.session = state.sessionId;
          }
        }
        _states.add(state);
        if (previous.sessionId == state.sessionId &&
            state.sessionId != null &&
            previous.engine != state.engine) {
          _events.add(
            YlPlaybackEngineChangedEvent(
              sessionId: state.sessionId!,
              revision: state.revision,
              occurredAt: _clock.elapsed,
              previousEngine: previous.engine,
              engine: state.engine,
            ),
          );
        }
        _completeLoad();
        return;
      }
      if (state.sessionId == null ||
          map['generation'] != null && map['generation'] != _generation) {
        return;
      }
      final id = state.sessionId!;
      final event = switch (map['type']) {
        'firstFrame' when !_firstFrame => YlFirstFrameEvent(
          sessionId: id,
          revision: state.revision,
          occurredAt: _clock.elapsed,
        ),
        'error' => YlPlaybackFailedEvent(
          sessionId: id,
          revision: state.revision,
          occurredAt: _clock.elapsed,
          failure: decodeYlFailure(map['error']),
        ),
        'retry' => YlRetryScheduledEvent(
          sessionId: id,
          revision: state.revision,
          occurredAt: _clock.elapsed,
          retryIndex: ylWireInt(map['attempt']) ?? 1,
          delay: Duration(milliseconds: ylWireInt(map['delayMs']) ?? 0),
          failure: decodeYlFailure(map['error']),
        ),
        _ => null,
      };
      if (event != null) {
        validateYlPlayerEvent(event);
        if (event is YlFirstFrameEvent) _firstFrame = true;
        _events.add(event);
      }
    } catch (_) {
      _protocolFailure();
    }
  }

  void _protocolFailure() {
    if (_disposed) return;
    final error = legacyException(
      YlFailureCodes.protocolMismatch,
      scope: YlFailureScope.player,
    );
    if (!_initial.isCompleted) _initial.completeError(error);
    final load = _load;
    if (load != null && !load.result.isCompleted) {
      load.result.completeError(error);
    }
    // Closing the SPI streams signals terminal lifecycle loss to the owner;
    // it does not fabricate an authoritative native failure snapshot/event.
    _terminalError = error;
    unawaited(dispose());
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose();
  Future<void> _dispose() async {
    _disposed = true;
    ++_serial;
    final error =
        _terminalError ?? legacyException(YlFailureCodes.playerDisposed);
    for (final pending in _pendingCommands) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pendingCommands.clear();
    _cancelLoad();
    _texture.value = null;
    try {
      await _subscription?.cancel();
    } catch (_) {
      /* still release native ownership */
    }
    // External paused observers must not delay owned resource release.
    unawaited(_states.close());
    unawaited(_events.close());
    try {
      await methods.invokeMethod<void>('dispose', {'playerId': playerId});
    } catch (_) {
      /* best effort */
    }
    _texture.dispose();
  }
}

final class _LoadBarrier {
  _LoadBarrier(this.serial);
  final int serial;
  final result = Completer<YlPlatformLoadResult>();
  bool replied = false;
  Timer? pairingTimer;
  YlPlaybackSessionId? session;
}

Future<YlPlatformPlayer> createYlLegacyChannelPlayer({
  required YlPlayerOptions options,
  required MethodChannel methods,
  required Stream<Object?> nativeEvents,
  required String platform,
  required YlPlaybackEngine initialEngine,
  Duration transportTimeout = const Duration(seconds: 30),
}) async {
  validateYlPlayerOptions(options);
  if (options.audioPolicy == YlAudioPolicy.pluginManagedMediaPlayback) {
    throw legacyException(
      YlFailureCodes.policyUnsupported,
      scope: YlFailureScope.player,
    );
  }
  _LegacyChannelPlayer? player;
  int? allocatedId;
  try {
    final response = await methods
        .invokeMapMethod<String, Object?>('create', {
          'configuration': encodeYlOptions(options),
        })
        .timeout(transportTimeout);
    final id = allocatedId = ylWireInt(response?['playerId']);
    final texture = ylWireInt(response?['textureId']);
    if (id == null || texture == null) {
      throw legacyException(
        YlFailureCodes.protocolMismatch,
        scope: YlFailureScope.player,
      );
    }
    player = _LegacyChannelPlayer(
      playerId: id,
      texture: texture,
      methods: methods,
      nativeEvents: nativeEvents,
      platform: platform,
      initialEngine: initialEngine,
      options: options,
      transportTimeout: transportTimeout,
    );
    // Observe first, because requestState may synchronously emit then fail.
    unawaited(
      player._initial.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
    await Future.wait([
      player._command('requestState'),
      player._initial.future,
    ]).timeout(transportTimeout);
    return player;
  } catch (error) {
    if (player != null) {
      try {
        await player.dispose();
      } catch (_) {
        /* preserve creation error */
      }
    } else if (allocatedId != null) {
      try {
        await methods.invokeMethod<void>('dispose', {'playerId': allocatedId});
      } catch (_) {
        /* preserve creation error */
      }
    }
    if (error is YlPlayerException) rethrow;
    if (error is PlatformException) throw decodeYlPlatformException(error);
    throw legacyException(
      YlFailureCodes.protocolMismatch,
      scope: YlFailureScope.player,
    );
  }
}
