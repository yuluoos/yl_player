import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

final class FakePlayerPlatform extends YlPlayerPlatform {
  FakePlayerPlatform(this.player);

  final FakePlatformPlayer player;
  int createCount = 0;
  YlPlayerConfiguration? configuration;
  Object? createError;

  @override
  Future<YlPlatformPlayer> createPlayer(
    YlPlayerConfiguration configuration,
  ) async {
    createCount += 1;
    this.configuration = configuration;
    final error = createError;
    if (error != null) {
      throw error;
    }
    return player;
  }
}

final class FakePlatformPlayer implements YlPlatformPlayer {
  final ValueNotifier<int?> textureIdNotifier = ValueNotifier<int?>(null);
  final StreamController<YlPlayerState> stateController =
      StreamController<YlPlayerState>.broadcast(sync: true);
  final StreamController<YlPlayerEvent> eventController =
      StreamController<YlPlayerEvent>.broadcast(sync: true);

  YlPlayerState currentState = YlPlayerState();
  YlMediaSource? openedSource;
  final List<String> calls = <String>[];
  Duration? seekPosition;
  double? playbackSpeed;
  double? volume;
  String? audioTrackId;
  YlQualityConstraint? qualityConstraint;
  YlPlayerError? playError;
  bool emitPlayErrorBeforeThrow = false;
  Object? disposeError;
  int disposeCount = 0;
  bool _disposed = false;

  @override
  Stream<YlPlayerEvent> get events => eventController.stream;

  @override
  YlPlayerState get state => currentState;

  @override
  Stream<YlPlayerState> get states => stateController.stream;

  @override
  ValueListenable<int?> get textureId => textureIdNotifier;

  void emitEvent(YlPlayerEvent event) {
    if (!_disposed) {
      eventController.add(event);
    }
  }

  void emitState(YlPlayerState state) {
    if (!_disposed) {
      currentState = state;
      stateController.add(state);
    }
  }

  void setTextureId(int? value) {
    if (!_disposed) {
      textureIdNotifier.value = value;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    disposeCount += 1;
    final error = disposeError;
    if (error != null) {
      _disposed = false;
      throw error;
    }
    await stateController.close();
    await eventController.close();
    textureIdNotifier.dispose();
  }

  @override
  Future<void> open(YlMediaSource source) async {
    calls.add('open');
    openedSource = source;
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
  }

  @override
  Future<void> play() async {
    calls.add('play');
    final error = playError;
    if (error != null) {
      if (emitPlayErrorBeforeThrow) {
        emitState(
          currentState.copyWith(status: YlPlaybackStatus.error, error: error),
        );
        emitEvent(YlErrorEvent(error));
      }
      throw error;
    }
  }

  @override
  Future<void> seekTo(Duration position) async {
    calls.add('seekTo');
    seekPosition = position;
  }

  @override
  Future<void> seekToLiveEdge() async {
    calls.add('seekToLiveEdge');
  }

  @override
  Future<void> selectAudioTrack(String trackId) async {
    calls.add('selectAudioTrack');
    audioTrackId = trackId;
  }

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    calls.add('setPlaybackSpeed');
    playbackSpeed = speed;
  }

  @override
  Future<void> setQualityConstraint(YlQualityConstraint constraint) async {
    calls.add('setQualityConstraint');
    qualityConstraint = constraint;
  }

  @override
  Future<void> setVolume(double volume) async {
    calls.add('setVolume');
    this.volume = volume;
  }
}
