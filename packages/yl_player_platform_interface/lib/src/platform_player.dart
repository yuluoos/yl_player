import 'package:flutter/foundation.dart';

import 'configuration.dart';
import 'media_source.dart';
import 'player_event.dart';
import 'player_state.dart';

/// Contract implemented by one native player instance.
abstract interface class YlPlatformPlayer {
  ValueListenable<int?> get textureId;

  YlPlayerState get state;

  Stream<YlPlayerState> get states;

  Stream<YlPlayerEvent> get events;

  Future<void> open(YlMediaSource source);

  Future<void> play();

  Future<void> pause();

  Future<void> seekTo(Duration position);

  Future<void> seekToLiveEdge();

  Future<void> setPlaybackSpeed(double speed);

  Future<void> setVolume(double volume);

  Future<void> selectAudioTrack(String trackId);

  Future<void> setQualityConstraint(YlQualityConstraint constraint);

  Future<void> dispose();
}
