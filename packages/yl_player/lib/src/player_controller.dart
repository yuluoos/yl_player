import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

/// App-facing controller for one native player instance.
final class YlPlayerController {
  YlPlayerController({
    YlPlayerConfiguration configuration = const YlPlayerConfiguration(),
    YlPlayerPlatform? platform,
  }) : _backendCreation = _createBackend(
         configuration,
         platform ?? YlPlayerPlatform.instance,
       );

  final Future<YlPlatformPlayer> _backendCreation;
  final StreamController<YlPlayerState> _stateController =
      StreamController<YlPlayerState>.broadcast(sync: true);
  final StreamController<YlPlayerEvent> _eventController =
      StreamController<YlPlayerEvent>.broadcast(sync: true);
  final ValueNotifier<int?> _textureId = ValueNotifier<int?>(null);

  YlPlayerState _state = YlPlayerState();
  Future<YlPlatformPlayer>? _connectedBackend;
  StreamSubscription<YlPlayerState>? _stateSubscription;
  StreamSubscription<YlPlayerEvent>? _eventSubscription;
  YlPlatformPlayer? _backend;
  YlPlayerError? _creationError;
  Future<void>? _disposeFuture;
  bool _isDisposed = false;

  /// Latest immutable native-player state.
  YlPlayerState get state => _state;

  /// Semantic state changes and throttled position updates.
  Stream<YlPlayerState> get states => _stateController.stream;

  /// Discrete playback events.
  Stream<YlPlayerEvent> get events => _eventController.stream;

  /// Native texture ID used by the texture-only player view.
  ValueListenable<int?> get textureId {
    if (!_isDisposed) {
      unawaited(_connectForTexture());
    }
    return _textureId;
  }

  List<YlMediaTrack> get audioTracks => _state.audioTracks;

  List<YlMediaTrack> get videoTracks => _state.videoTracks;

  YlPlayerCapabilities? get capabilities => _state.capabilities;

  YlPlaybackMetrics get metrics => _state.metrics;

  Future<void> open(YlMediaSource source) =>
      _run((backend) => backend.open(source));

  Future<void> play() => _run((backend) => backend.play());

  Future<void> pause() => _run((backend) => backend.pause());

  Future<void> seekTo(Duration position) {
    validateYlSeekPosition(position);
    return _run((backend) => backend.seekTo(position));
  }

  Future<void> seekToLiveEdge() => _run((backend) => backend.seekToLiveEdge());

  Future<void> setPlaybackSpeed(double speed) {
    validateYlPlaybackSpeed(speed);
    return _run((backend) => backend.setPlaybackSpeed(speed));
  }

  Future<void> setVolume(double volume) {
    validateYlVolume(volume);
    return _run((backend) => backend.setVolume(volume));
  }

  Future<void> selectAudioTrack(String trackId) =>
      _run((backend) => backend.selectAudioTrack(trackId));

  Future<void> setQualityConstraint(YlQualityConstraint constraint) {
    validateYlQualityConstraint(constraint);
    return _run((backend) => backend.setQualityConstraint(constraint));
  }

  /// Releases native and Dart resources. Repeated calls share one completion.
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) {
      return existing;
    }
    _isDisposed = true;
    return _disposeFuture = _performDispose();
  }

  Future<YlPlatformPlayer> _connect() async {
    final backend = await _backendCreation;
    _backend = backend;
    if (_isDisposed) {
      return backend;
    }

    _state = backend.state;
    _textureId.value = backend.textureId.value;
    backend.textureId.addListener(_handleTextureChanged);
    _stateSubscription = backend.states.listen(_handleState);
    _eventSubscription = backend.events.listen(_handleEvent);
    return backend;
  }

  Future<void> _connectForTexture() async {
    try {
      await _getBackend();
    } on Object catch (error) {
      _reportCreationError(error);
    }
  }

  Future<YlPlatformPlayer> _getBackend() => _connectedBackend ??= _connect();

  Future<YlPlatformPlayer> _getBackendForCommand() async {
    try {
      return await _getBackend();
    } on Object catch (error) {
      throw _reportCreationError(error);
    }
  }

  void _handleEvent(YlPlayerEvent event) {
    if (!_isDisposed && !_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  void _handleState(YlPlayerState state) {
    if (_isDisposed || _stateController.isClosed) {
      return;
    }
    _state = state;
    _stateController.add(state);
  }

  void _handleTextureChanged() {
    if (!_isDisposed) {
      _textureId.value = _backend?.textureId.value;
    }
  }

  Future<void> _performDispose() async {
    YlPlatformPlayer? backend;
    try {
      backend = await _getBackend();
    } on Object {
      backend = null;
    }

    backend?.textureId.removeListener(_handleTextureChanged);
    await _stateSubscription?.cancel();
    await _eventSubscription?.cancel();
    try {
      await backend?.dispose();
    } on Object {
      // Disposal is terminal and best-effort. Keep closing the controller's
      // streams and notifier even if a platform teardown reports failure.
    }

    _state = _state.copyWith(status: YlPlaybackStatus.disposed, error: null);
    if (!_stateController.isClosed) {
      _stateController.add(_state);
    }
    await _stateController.close();
    await _eventController.close();
    _textureId.dispose();
  }

  void _reportError(YlPlayerError error) {
    if (_isDisposed) {
      return;
    }
    _state = _state.copyWith(status: YlPlaybackStatus.error, error: error);
    _stateController.add(_state);
    _eventController.add(YlErrorEvent(error));
  }

  YlPlayerError _reportCreationError(Object error) {
    final existing = _creationError;
    if (existing != null) {
      return existing;
    }
    final playerError = error is YlPlayerError
        ? error
        : YlPlayerError(
            category: YlPlayerErrorCategory.internal,
            code: 'platform.create_failed',
            message: 'The platform player could not be created.',
            platformDiagnostic: error.toString(),
          );
    _creationError = playerError;
    _reportError(playerError);
    return playerError;
  }

  Future<void> _run(
    Future<void> Function(YlPlatformPlayer backend) command,
  ) async {
    if (_isDisposed) {
      throw StateError('YlPlayerController has been disposed.');
    }

    final backend = await _getBackendForCommand();
    if (_isDisposed) {
      throw StateError('YlPlayerController has been disposed.');
    }
    await command(backend);
  }

  static Future<YlPlatformPlayer> _createBackend(
    YlPlayerConfiguration configuration,
    YlPlayerPlatform platform,
  ) {
    validateYlPlayerConfiguration(configuration);
    return platform.createPlayer(configuration);
  }
}
