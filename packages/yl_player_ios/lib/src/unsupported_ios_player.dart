import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

/// Compile-safe shell replaced by the AVPlayer implementation milestone.
final class UnsupportedIosPlayer implements YlPlatformPlayer {
  final ValueNotifier<int?> _textureId = ValueNotifier<int?>(null);
  final StreamController<YlPlayerState> _states =
      StreamController<YlPlayerState>.broadcast(sync: true);
  final StreamController<YlPlayerEvent> _events =
      StreamController<YlPlayerEvent>.broadcast(sync: true);
  YlPlayerState _state = YlPlayerState();
  bool _disposed = false;

  static const YlPlayerError _unsupportedError = YlPlayerError(
    category: YlPlayerErrorCategory.internal,
    code: 'ios.not_implemented',
    message: 'The iOS AVPlayer backend has not been implemented yet.',
  );

  @override
  Stream<YlPlayerEvent> get events => _events.stream;

  @override
  YlPlayerState get state => _state;

  @override
  Stream<YlPlayerState> get states => _states.stream;

  @override
  ValueListenable<int?> get textureId => _textureId;

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _state = _state.copyWith(status: YlPlaybackStatus.disposed, error: null);
    _states.add(_state);
    await _states.close();
    await _events.close();
    _textureId.dispose();
  }

  @override
  Future<void> open(YlMediaSource source) => _fail();

  @override
  Future<void> pause() => _fail();

  @override
  Future<void> play() => _fail();

  @override
  Future<void> seekTo(Duration position) => _fail();

  @override
  Future<void> seekToLiveEdge() => _fail();

  @override
  Future<void> selectAudioTrack(String trackId) => _fail();

  @override
  Future<void> setPlaybackSpeed(double speed) => _fail();

  @override
  Future<void> setQualityConstraint(YlQualityConstraint constraint) => _fail();

  @override
  Future<void> setVolume(double volume) => _fail();

  Future<void> _fail() {
    if (_disposed) {
      return Future<void>.error(
        StateError('The iOS platform player has been disposed.'),
      );
    }
    _state = _state.copyWith(
      status: YlPlaybackStatus.error,
      error: _unsupportedError,
    );
    _states.add(_state);
    _events.add(const YlErrorEvent(_unsupportedError));
    return Future<void>.error(_unsupportedError);
  }
}
