import 'package:flutter/foundation.dart';

import '../model/capabilities.dart';
import '../model/identifiers.dart';
import '../model/player_event.dart';
import '../model/player_state.dart';
import '../model/source_assessment.dart';
import '../options/load_options.dart';
import '../options/video_constraints.dart';
import '../source/media_source.dart';
import 'platform_implementation_info.dart';
import 'platform_load_result.dart';

/// Handwritten v2 SPI. Session commands reject replaced/stopped identities;
/// volume is player-scoped. State revisions increase across session changes.
/// State/event streams are authoritative and dispose is idempotent.
abstract interface class YlPlatformPlayer {
  YlPlatformImplementationInfo get implementation;
  YlPlayerCapabilities get capabilities;
  ValueListenable<int?> get textureId;
  YlPlayerState get state;
  Stream<YlPlayerState> get states;
  Stream<YlPlayerEvent> get events;
  Future<YlSourceAssessment> assess(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  });

  /// Returns only after the commit/state barrier documented by the result.
  Future<YlPlatformLoadResult> load(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  });
  Future<void> play(YlPlaybackSessionId sessionId);
  Future<void> pause(YlPlaybackSessionId sessionId);
  Future<void> seekTo(YlPlaybackSessionId sessionId, Duration position);
  Future<void> seekToLiveEdge(YlPlaybackSessionId sessionId);
  Future<void> setPlaybackSpeed(YlPlaybackSessionId sessionId, double speed);
  Future<void> selectAudioTrack(YlPlaybackSessionId sessionId, String trackId);
  Future<void> setVideoConstraints(
    YlPlaybackSessionId sessionId,
    YlVideoConstraints constraints,
  );
  Future<void> setVolume(double volume);
  Future<void> stop();
  Future<void> dispose();
}
