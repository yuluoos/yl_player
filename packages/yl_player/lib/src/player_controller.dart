import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
part 'playback_session.dart';

/// Explicitly owns one native player and its replaceable playback sessions.
final class YlPlayerController implements Listenable {
  YlPlayerController._(this._backend)
    : _state = _backend.state,
      _texture = ValueNotifier(_backend.textureId.value);
  static Future<YlPlayerController> create({
    YlPlayerOptions options = const YlPlayerOptions(),
    YlPlayerPlatform? platform,
  }) async {
    validateYlPlayerOptions(options);
    final backend = await (platform ?? YlPlayerPlatform.instance).createPlayer(
      options,
    );
    YlPlayerController? player;
    try {
      if (backend.implementation.spiMajor != ylPlayerSpiMajor) {
        throw _exception(YlFailureCodes.platformIncompatible);
      }
      validateYlPlayerCapabilities(backend.capabilities);
      validateYlPlayerState(backend.state);
      player = YlPlayerController._(backend);
      player._stateSubscription = backend.states.listen(player._acceptState);
      player._eventSubscription = backend.events.listen(player._acceptEvent);
      backend.textureId.addListener(player._updateTexture);
      // A synchronous backend may publish while subscriptions attach.
      player._acceptState(backend.state);
      player._record(player.state);
      return player;
    } catch (_) {
      if (player != null) {
        await player.dispose();
      } else {
        try {
          await backend.dispose();
        } catch (_) {}
      }
      rethrow;
    }
  }

  final YlPlatformPlayer _backend;
  final _notifier = _PlayerNotifier();
  final ValueNotifier<int?> _texture;
  final _states = StreamController<YlPlayerState>.broadcast(sync: true);
  final _events = StreamController<YlPlayerEvent>.broadcast(sync: true);
  StreamSubscription<YlPlayerState>? _stateSubscription;
  StreamSubscription<YlPlayerEvent>? _eventSubscription;
  YlPlayerState _state;
  _Milestones? _milestones;
  YlPlaybackSessionId? _stoppedSession;
  Completer<YlPlaybackSession>? _pendingLoad;
  int _loadSerial = 0;
  bool _disposed = false;
  Future<void>? _disposeFuture;
  String get implementationName => _backend.implementation.name;
  String get implementationVersion => _backend.implementation.version;
  YlPlayerCapabilities get capabilities => _backend.capabilities;
  YlPlayerState get state => _state;
  ValueListenable<int?> get textureId => _texture;
  Stream<YlPlayerState> get states => _states.stream;
  Stream<YlPlayerEvent> get events => _events.stream;
  @override
  void addListener(VoidCallback listener) => _notifier.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      _notifier.removeListener(listener);
  void _check() {
    if (_disposed) throw _exception(YlFailureCodes.playerDisposed);
  }

  void _checkSession(YlPlaybackSessionId id) {
    _check();
    if (_stoppedSession == id ||
        state.sessionId != id ||
        state.status == YlPlaybackStatus.idle ||
        state.status == YlPlaybackStatus.failed) {
      throw _exception(YlFailureCodes.sessionStale);
    }
  }

  Future<YlSourceAssessment> assess(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) async {
    _check();
    validateYlSource(source);
    validateYlLoadOptions(options);
    final result = await _backend.assess(source, options: options);
    _check();
    validateYlSourceAssessment(result);
    return result;
  }

  Future<YlPlaybackSession> load(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) {
    try {
      _check();
      validateYlSource(source);
      validateYlLoadOptions(options);
      _cancelLoad();
      final serial = ++_loadSerial;
      final completer = Completer<YlPlaybackSession>();
      _pendingLoad = completer;
      unawaited(_performLoad(serial, completer, source, options));
      return completer.future;
    } catch (e, stack) {
      return Future.error(e, stack);
    }
  }

  Future<void> _performLoad(
    int serial,
    Completer<YlPlaybackSession> result,
    YlMediaSource source,
    YlLoadOptions options,
  ) async {
    try {
      final committed = await _backend.load(source, options: options);
      if (_disposed || serial != _loadSerial || result.isCompleted) return;
      _acceptState(_backend.state);
      if (state.sessionId != committed.sessionId) {
        throw _exception(YlFailureCodes.protocolMismatch);
      }
      _record(state);
      final milestones = _milestones!;
      result.complete(
        YlPlaybackSession._(
          this,
          committed.sessionId,
          milestones.ready.future,
          milestones.firstFrame.future,
        ),
      );
    } catch (error, stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    } finally {
      if (identical(_pendingLoad, result)) _pendingLoad = null;
    }
  }

  void _cancelLoad([String code = YlFailureCodes.loadCancelled]) {
    _loadSerial++;
    final pending = _pendingLoad;
    _pendingLoad = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(_exception(code));
    }
  }

  void _updateTexture() {
    if (!_disposed) _texture.value = _backend.textureId.value;
  }

  void _acceptState(YlPlayerState next) {
    if (_disposed || next.revision <= state.revision) return;
    validateYlPlayerState(next);
    _state = next;
    _record(next);
    _notifier.notify();
    _states.add(next);
  }

  void _record(YlPlayerState next) {
    if (next.sessionId != null && next.sessionId == _stoppedSession) return;
    if (_milestones?.id != next.sessionId) {
      _milestones?.fail(_exception(YlFailureCodes.sessionStale));
      _milestones = next.sessionId == null
          ? null
          : _Milestones(next.sessionId!);
    }
    final milestones = _milestones;
    if (milestones == null) return;
    if (next.status == YlPlaybackStatus.ready ||
        next.status == YlPlaybackStatus.playing ||
        next.metrics.loadToReady != null) {
      milestones.completeReady();
    }
    if (next.status == YlPlaybackStatus.failed) {
      milestones.fail(
        YlPlayerException(
          next.failure ?? _exception(YlFailureCodes.platformFailure).failure,
        ),
      );
    }
  }

  void _acceptEvent(YlPlayerEvent event) {
    if (_disposed ||
        event.sessionId != state.sessionId ||
        event.sessionId == _stoppedSession) {
      return;
    }
    validateYlPlayerEvent(event);
    if (event is YlFirstFrameEvent) _milestones?.completeFirstFrame();
    _events.add(event);
  }

  Future<void> setVolume(double volume) async {
    _check();
    validateYlVolume(volume);
    await _backend.setVolume(volume);
  }

  Future<void> stop() async {
    _check();
    _cancelLoad();
    final sessionId = state.sessionId;
    await _backend.stop();
    if (state.sessionId == sessionId) {
      _stoppedSession = sessionId;
      _milestones?.fail(_exception(YlFailureCodes.sessionStale));
      _milestones = null;
    }
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();
  Future<void> _dispose() async {
    _disposed = true;
    _cancelLoad(YlFailureCodes.playerDisposed);
    _milestones?.fail(_exception(YlFailureCodes.playerDisposed));
    _milestones = null;
    await _stateSubscription?.cancel();
    await _eventSubscription?.cancel();
    _backend.textureId.removeListener(_updateTexture);
    try {
      await _backend.dispose();
    } catch (_) {
      /* Native cleanup is best effort. */
    }
    _texture.value = null;
    await _states.close();
    await _events.close();
    _notifier.dispose();
  }
}

YlPlayerException _exception(String code) => YlPlayerException(
  YlFailure(
    category: code == YlFailureCodes.loadCancelled
        ? YlFailureCategory.cancelled
        : YlFailureCategory.platform,
    code: code,
    message: 'Playback operation failed.',
    retryable: false,
    scope: YlFailureScope.command,
    diagnosticId: 'dart-lifecycle',
  ),
);

final class _Milestones {
  _Milestones(this.id) {
    // Observe the same published futures without replacing their errors.
    unawaited(
      ready.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    unawaited(
      firstFrame.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
  }
  final YlPlaybackSessionId id;
  final ready = Completer<void>();
  final firstFrame = Completer<void>();
  void completeReady() {
    if (!ready.isCompleted) ready.complete();
  }

  void completeFirstFrame() {
    if (!firstFrame.isCompleted) firstFrame.complete();
  }

  void fail(YlPlayerException error) {
    if (!ready.isCompleted) ready.completeError(error);
    if (!firstFrame.isCompleted) firstFrame.completeError(error);
  }
}

final class _PlayerNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}
