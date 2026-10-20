import 'dart:async';
import 'network_traffic.dart';
import 'drm/license_client.dart';
import 'subtitles/text_subtitle_runtime.dart';
import 'package:flutter/foundation.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
part 'playback_session.dart';

/// Explicitly owns one native player and its replaceable playback sessions.
final class YlPlayerController implements Listenable {
  YlPlayerController._(this._backend, this._textSubtitles)
    : _state = _backend.state,
      _backendRevision = _backend.state.revision,
      _texture = ValueNotifier(_backend.textureId.value),
      _networkTraffic = NetworkTrafficSampler(
        _backend is YlNetworkTrafficPlatformPlayer
            ? (_backend as YlNetworkTrafficPlatformPlayer).networkBytesReceived
            : const Stream<int?>.empty(),
      );

  /// Creates a player with one subtitle owner.
  ///
  /// [enableTextSubtitles] enables the Dart text/bitmap runtime for external
  /// resources and supported embedded tracks in file or managed HTTP(S)
  /// Matroska/WebM/MP4 sources, plus clear static DASH WebVTT/TTML tracks.
  /// DASH loads only the selected current/next subtitle segments on the media
  /// clock; later subtitle failures emit command-scoped events and video continues.
  /// External clear subtitles can overlay explicitly negotiated protected
  /// native views; protected embedded discovery remains unsupported. Subtitle
  /// image failures emit command-scoped events without terminating video.
  /// PGS/VobSub embedded tracks require Matroska.
  /// Supported Matroska tracks include bounded zlib/header stripping of blocks,
  /// CodecPrivate or both, using up to four ordered stages per track.
  /// Discover them through [YlPlaybackSession.discoverEmbeddedSubtitles].
  /// The historical option name includes bitmap subtitles; the default uses
  /// the native subtitle SPI and cannot be combined with a second owner.
  static Future<YlPlayerController> create({
    YlPlayerOptions options = const YlPlayerOptions(),
    YlPlayerPlatform? platform,
    bool enableTextSubtitles = false,
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
      if (enableTextSubtitles &&
          (kIsWeb ||
              backend is YlSubtitlePlatformPlayer ||
              backend.state.subtitles.tracks.isNotEmpty)) {
        throw _exception(YlFailureCodes.policyUnsupported);
      }
      player = YlPlayerController._(
        backend,
        enableTextSubtitles ? TextSubtitleRuntime() : null,
      );
      player._textSubtitles?.onChanged = player._subtitleWindowChanged;
      player._textSubtitles?.onFailure = player._subtitleWindowFailed;
      if (backend is YlPlatformDrmLicenseTransport) {
        (backend as YlPlatformDrmLicenseTransport).setDrmLicenseExchange(
          player._exchangeLicense,
        );
      }
      player._stateSubscription = backend.states.listen(
        player._acceptState,
        onError: (Object _) => player!._transportLost(),
        onDone: player._transportLost,
      );
      player._eventSubscription = backend.events.listen(
        player._acceptEvent,
        onError: (Object _) => player!._transportLost(),
        onDone: player._transportLost,
      );
      backend.textureId.addListener(player._updateTexture);
      player._airPlayBackend?.airPlayState.addListener(player._updateAirPlay);
      player._updateAirPlay();
      // A synchronous backend may publish while subscriptions attach.
      player._acceptState(backend.state);
      player._record(player.state);
      player._check();
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

  final _licenseClient = YlDrmLicenseClient();
  final _subtitleClock = Stopwatch()..start();
  Future<YlDrmBytes> _exchangeLicense(
    YlDrmLicenseEndpoint endpoint,
    YlDrmBytes challenge,
    Future<void> cancelled,
  ) async {
    final token = YlDrmCancellationToken();
    unawaited(cancelled.then((_) => token.cancel()));
    try {
      return await _licenseClient.send(
        endpoint,
        challenge,
        cancellation: token,
      );
    } finally {
      token.cancel();
    }
  }

  YlAirPlayPlatformPlayer? get _airPlayBackend =>
      _backend is YlAirPlayPlatformPlayer
      ? _backend as YlAirPlayPlatformPlayer
      : null;
  final _airPlay = ValueNotifier(const YlAirPlayState());

  /// Actual route state, independent of first-frame presentation.
  ValueListenable<YlAirPlayState> get airPlayState => _airPlay;
  YlAirPlayRoutePickerSurface? get airPlayRoutePickerSurface =>
      _disposed ? null : _airPlayBackend?.airPlayRoutePickerSurface;

  void _updateAirPlay() {
    if (_disposed) return;
    final next = _airPlayBackend?.airPlayState.value ?? const YlAirPlayState();
    final current =
        next.sessionId != null &&
        next.sessionId == state.sessionId &&
        next.sessionId != _stoppedSession &&
        state.status != YlPlaybackStatus.failed &&
        state.status != YlPlaybackStatus.idle;
    _airPlay.value = current ? next : YlAirPlayState(supported: next.supported);
  }

  void _checkAirPlayAdmission(YlLoadOptions options) {
    if (options.airPlay &&
        _airPlayBackend?.airPlayState.value.supported != true) {
      throw _exception(YlFailureCodes.policyUnsupported);
    }
  }

  /// Current native protected output identity; no Flutter texture is exposed.
  YlProtectedVideoSurface? get protectedVideoSurface =>
      _backend is YlPlatformProtectedVideoSurfaceProvider
      ? (_backend as YlPlatformProtectedVideoSurfaceProvider)
            .protectedVideoSurface
      : null;

  /// Attaches the exact committed native surface to a platform view.
  @internal
  Future<void> attachProtectedView(
    YlProtectedVideoSurface surface,
    int viewId,
  ) => (_backend as YlPlatformProtectedVideoSurfaceProvider)
      .attachProtectedView(surface, viewId);

  /// Detaches only this view claim; ownership stays with the native player.
  @internal
  Future<void> detachProtectedView(
    YlProtectedVideoSurface surface,
    int viewId,
  ) => (_backend as YlPlatformProtectedVideoSurfaceProvider)
      .detachProtectedView(surface, viewId);

  final NetworkTrafficSampler _networkTraffic;

  /// Actual download bytes per second for the newest requested load, including
  /// its opening phase before playback is committed. Null means unavailable;
  /// zero means an observed idle window. Sampling runs only with subscribers.
  /// This does not measure upload or estimate rate from media bitrate.
  /// Native observation cadence may be coarser (for example AVPlayer logs).
  Stream<int?> get downloadBytesPerSecond => _networkTraffic.rates;

  final YlPlatformPlayer _backend;
  final TextSubtitleRuntime? _textSubtitles;
  int _backendRevision;
  int _pendingLivePlaybackCommands = 0;
  int _subtitleSeekSerial = 0;
  bool _subtitleSeeking = false;
  bool _subtitleAwaitingPosition = false;
  bool _subtitleProtectedSource = false;
  YlMediaSource? _subtitleSource;
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
  YlPlayerCapabilities get capabilities => _textSubtitles == null
      ? _backend.capabilities
      : _backend.capabilities.copyWith(
          supportedOperations: {
            ..._backend.capabilities.supportedOperations,
            YlPlayerOperation.externalSubtitles,
            YlPlayerOperation.embeddedSubtitles,
            YlPlayerOperation.subtitleTrackSelection,
            YlPlayerOperation.subtitleOffset,
          }.toList(),
        );
  YlPlayerState get state => _state;
  bool get isCurrentFramePresented =>
      _milestones?.isFirstFramePresented ?? false;
  ValueListenable<int?> get textureId => _texture;

  /// Optional surface explicitly negotiated by the platform implementation.
  YlNativeVideoSurface? get nativeVideoSurface {
    final backend = _backend;
    return backend is YlPlatformNativeVideoSurfaceProvider
        ? (backend as YlPlatformNativeVideoSurfaceProvider).nativeVideoSurface
        : null;
  }

  Stream<YlPlayerState> get states => _states.stream;
  Stream<YlPlayerEvent> get events => _events.stream;

  /// Internal rendering projection, synchronized to authoritative media time.
  @internal
  List<TextSubtitleCue> get textSubtitleCues {
    if (_disposed ||
        _subtitleSeeking ||
        _subtitleAwaitingPosition ||
        !_subtitleOverlayAllowed ||
        ((_subtitleProtectedSource || protectedVideoSurface != null) &&
            state.videoGeometry == null) ||
        !isCurrentFramePresented ||
        _stoppedSession == state.sessionId ||
        ![
          YlPlaybackStatus.ready,
          YlPlaybackStatus.playing,
          YlPlaybackStatus.paused,
          YlPlaybackStatus.buffering,
        ].contains(state.status)) {
      return const [];
    }
    return _textSubtitles?.cuesAt(state.timeline.position) ?? const [];
  }

  bool get _subtitleOverlayAllowed {
    final surface = protectedVideoSurface;
    if (!_subtitleProtectedSource && surface == null) return true;
    return surface != null &&
        surface.supportsSubtitleOverlay &&
        surface.sessionId == state.sessionId?.value &&
        !kIsWeb &&
        surface.platform == defaultTargetPlatform;
  }

  void _checkTextSubtitleAdmission() {
    if (!_subtitleOverlayAllowed) {
      throw _exception(YlFailureCodes.policyUnsupported);
    }
  }

  bool get _canLoadSubtitleWindow =>
      !_disposed &&
      !_subtitleSeeking &&
      !_subtitleAwaitingPosition &&
      _subtitleOverlayAllowed &&
      state.sessionId != null &&
      _stoppedSession != state.sessionId &&
      [
        YlPlaybackStatus.ready,
        YlPlaybackStatus.playing,
        YlPlaybackStatus.paused,
        YlPlaybackStatus.buffering,
      ].contains(state.status);

  void _subtitleWindowChanged() {
    if (_canLoadSubtitleWindow) _notifier.notify();
  }

  void _subtitleWindowFailed(YlPlayerException error) {
    if (!_canLoadSubtitleWindow) return;
    _acceptEvent(
      YlPlaybackFailedEvent(
        sessionId: state.sessionId!,
        revision: state.revision,
        occurredAt: _subtitleClock.elapsed,
        failure: error.failure,
      ),
    );
    _notifier.notify();
  }

  void _publishSubtitles() {
    if (_disposed) return;
    _state = state.copyWith(
      revision: state.revision + 1,
      subtitles: _textSubtitles!.state,
    );
    if (_canLoadSubtitleWindow) {
      _textSubtitles.updatePosition(state.timeline.position);
    }
    _notifier.notify();
    _states.add(state);
  }

  Future<void> _seekWithSubtitles(Future<void> Function() action) async {
    if (_textSubtitles == null) {
      await action();
      return;
    }
    final serial = ++_subtitleSeekSerial;
    _textSubtitles.suspendWindow();
    _subtitleSeeking = true;
    _subtitleAwaitingPosition = false;
    _notifier.notify();
    try {
      await action();
      if (!_disposed && serial == _subtitleSeekSerial) {
        _subtitleSeeking = false;
        _subtitleAwaitingPosition = true;
      }
    } catch (_) {
      if (!_disposed && serial == _subtitleSeekSerial) {
        _subtitleSeeking = false;
        if (_canLoadSubtitleWindow) {
          _textSubtitles.updatePosition(state.timeline.position);
        }
        _notifier.notify();
      }
      rethrow;
    }
  }

  @override
  void addListener(VoidCallback listener) => _notifier.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      _notifier.removeListener(listener);
  void _check() {
    if (_disposed) throw _exception(YlFailureCodes.playerDisposed);
  }

  void _checkSession(YlPlaybackSessionId id, {bool allowFailed = false}) {
    _check();
    if (_stoppedSession == id ||
        state.sessionId != id ||
        state.status == YlPlaybackStatus.idle ||
        (!allowFailed && state.status == YlPlaybackStatus.failed)) {
      throw _exception(YlFailureCodes.sessionStale);
    }
  }

  void _checkDrmAdmission(YlMediaSource source) {
    if (source is! YlNetworkSource || source.drm == null) return;
    final backend = _backend;
    if (backend is! YlPlatformDrmSourceSupport ||
        (backend as YlPlatformDrmSourceSupport).drmContractVersion != 1) {
      throw ylDrmException(YlFailureCodes.drmUnsupported);
    }
  }

  /// 当前平台是否提供独立媒体交付能力；具体源仍需经过准备验证。
  bool get supportsMediaDelivery =>
      !_disposed && _backend is YlMediaDeliveryPlatformPlayer;

  /// 准备可被局域网接收端拉取的媒体，保持本地播放不变。
  YlMediaDeliveryPreparation prepareMediaDelivery(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) {
    _check();
    validateYlSource(source);
    validateYlLoadOptions(options);
    final backend = _backend;
    if (backend is! YlMediaDeliveryPlatformPlayer) {
      throw _exception(YlFailureCodes.policyUnsupported);
    }
    return (backend as YlMediaDeliveryPlatformPlayer).prepareMediaDelivery(
      source,
      options: options,
    );
  }

  Future<YlSourceAssessment> assess(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) async {
    _check();
    validateYlSource(source);
    _checkDrmAdmission(source);
    validateYlLoadOptions(options);
    _checkAirPlayAdmission(options);
    final result = options.airPlay
        ? await _airPlayBackend!.assessForAirPlay(source, options: options)
        : await _backend.assess(source, options: options);
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
      _checkDrmAdmission(source);
      validateYlLoadOptions(options);
      _checkAirPlayAdmission(options);
      _cancelLoad();
      _textSubtitles?.cancel();
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
      final committed = options.airPlay
          ? await _airPlayBackend!.loadForAirPlay(source, options: options)
          : await _backend.load(source, options: options);
      if (_disposed || serial != _loadSerial || result.isCompleted) return;
      _acceptState(_backend.state);
      if (state.sessionId != committed.sessionId) {
        throw _exception(YlFailureCodes.protocolMismatch);
      }
      _record(state);
      _subtitleSource = source;
      _subtitleProtectedSource =
          source is YlNetworkSource && source.drm != null;
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
    if (_disposed || next.revision <= _backendRevision) return;
    validateYlPlayerState(next);
    _backendRevision = next.revision;
    if (_textSubtitles != null) {
      if (next.sessionId != state.sessionId ||
          next.status == YlPlaybackStatus.idle) {
        _textSubtitles.reset();
        _subtitleSource = null;
        _subtitleSeekSerial++;
        _subtitleSeeking = false;
        _subtitleProtectedSource = false;
      }
      if (next.status == YlPlaybackStatus.failed ||
          next.status == YlPlaybackStatus.completed) {
        _textSubtitles.cancel();
      }
      _subtitleAwaitingPosition = false;
      _state = next.copyWith(
        revision: state.revision + 1,
        subtitles: _textSubtitles.state,
      );
    } else {
      _state = next;
    }
    _record(state);
    _updateAirPlay();
    if (_canLoadSubtitleWindow) {
      _textSubtitles?.updatePosition(state.timeline.position);
    }
    _notifier.notify();
    _states.add(state);
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
      milestones.clearFirstFramePresentation();
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
    if (_textSubtitles != null) {
      // Subtitle-only states have no native revision. Correlate each event to
      // the observable public snapshot at delivery, preserving its session and
      // original occurrence time even for a late FirstFrame milestone. Keeping
      // arbitrary historical native/public mappings would grow without bound.
      event = switch (event) {
        YlFirstFrameEvent() => YlFirstFrameEvent(
          sessionId: event.sessionId,
          revision: state.revision,
          occurredAt: event.occurredAt,
        ),
        YlRetryScheduledEvent() => YlRetryScheduledEvent(
          sessionId: event.sessionId,
          revision: state.revision,
          occurredAt: event.occurredAt,
          retryIndex: event.retryIndex,
          delay: event.delay,
          failure: event.failure,
        ),
        YlPlaybackEngineChangedEvent() => YlPlaybackEngineChangedEvent(
          sessionId: event.sessionId,
          revision: state.revision,
          occurredAt: event.occurredAt,
          previousEngine: event.previousEngine,
          engine: event.engine,
        ),
        YlPlaybackFailedEvent() => YlPlaybackFailedEvent(
          sessionId: event.sessionId,
          revision: state.revision,
          occurredAt: event.occurredAt,
          failure: event.failure,
        ),
      };
    }
    if (event is YlFirstFrameEvent &&
        (_milestones?.completeFirstFrame() ?? false)) {
      _notifier.notify();
    }
    _events.add(event);
  }

  void _transportLost() {
    if (_disposed) return;
    _cancelLoad(YlFailureCodes.protocolMismatch);
    _milestones?.fail(_exception(YlFailureCodes.protocolMismatch));
    unawaited(dispose());
  }

  Future<void> setVolume(double volume) async {
    _check();
    validateYlVolume(volume);
    await _backend.setVolume(volume);
  }

  Future<void> stop() async {
    _check();
    _cancelLoad();
    _textSubtitles?.cancel();
    final sessionId = state.sessionId;
    await _backend.stop();
    if (state.sessionId == sessionId) {
      final presentationChanged = isCurrentFramePresented;
      _stoppedSession = sessionId;
      _updateAirPlay();
      _milestones?.fail(_exception(YlFailureCodes.sessionStale));
      _milestones = null;
      if (_textSubtitles != null) {
        _textSubtitles.reset();
        _subtitleSource = null;
        _subtitleSeekSerial++;
        _subtitleSeeking = false;
        _subtitleAwaitingPosition = false;
        _publishSubtitles();
      }
      if (presentationChanged) _notifier.notify();
    }
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();
  Future<void> _dispose() async {
    _textSubtitles?.reset();
    _subtitleSource = null;
    if (_textSubtitles != null) {
      _state = state.copyWith(
        revision: state.revision + 1,
        subtitles: _textSubtitles.state,
      );
    }
    _licenseClient.close();
    _disposed = true;
    _airPlayBackend?.airPlayState.removeListener(_updateAirPlay);
    _airPlay.value = const YlAirPlayState();
    await _networkTraffic.dispose();
    _cancelLoad(YlFailureCodes.playerDisposed);
    final presentationChanged = isCurrentFramePresented;
    _milestones?.fail(_exception(YlFailureCodes.playerDisposed));
    _milestones = null;
    if (presentationChanged) _notifier.notify();
    await _stateSubscription?.cancel();
    await _eventSubscription?.cancel();
    _backend.textureId.removeListener(_updateTexture);
    try {
      await _backend.dispose();
    } catch (_) {
      /* Native cleanup is best effort. */
    }
    _texture.value = null;
    // Closing still delivers Done when external observers resume.
    unawaited(_states.close());
    unawaited(_events.close());
    _notifier.dispose();
  }
}

YlPlayerException _exception(String code) => YlPlayerException(
  YlFailure(
    category: switch (code) {
      YlFailureCodes.loadCancelled => YlFailureCategory.cancelled,
      YlFailureCodes.policyUnsupported => YlFailureCategory.unsupported,
      YlFailureCodes.resourceExhausted => YlFailureCategory.resource,
      _ => YlFailureCategory.platform,
    },
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
  bool isFirstFramePresented = false;
  void completeReady() {
    if (!ready.isCompleted) ready.complete();
  }

  bool completeFirstFrame() {
    if (isFirstFramePresented || firstFrame.isCompleted) return false;
    isFirstFramePresented = true;
    if (!firstFrame.isCompleted) firstFrame.complete();
    return true;
  }

  void clearFirstFramePresentation() => isFirstFramePresented = false;

  void fail(YlPlayerException error) {
    if (!ready.isCompleted) ready.completeError(error);
    if (!firstFrame.isCompleted) firstFrame.completeError(error);
  }
}

final class _PlayerNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}
