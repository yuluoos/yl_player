import 'package:flutter/foundation.dart';

import '../model/capabilities.dart';
import '../model/identifiers.dart';
import '../model/live_playback.dart';
import '../model/player_event.dart';
import '../model/player_state.dart';
import '../model/source_assessment.dart';
import '../model/subtitles.dart';
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

/// Optional SPI for backends that can enforce one exact video track.
abstract interface class YlVideoTrackSelectionPlatformPlayer {
  Future<void> selectVideoTrack(YlPlaybackSessionId sessionId, String? trackId);
}

/// Optional subtitle SPI. Each method requires its matching capability.
/// Success acknowledges a committed command, not first subtitle presentation.
/// Implementations own resource cancellation and same-session command ordering.
abstract interface class YlSubtitlePlatformPlayer {
  Future<void> replaceExternalSubtitles(
    YlPlaybackSessionId sessionId,
    List<YlExternalSubtitle> subtitles,
  );
  Future<void> selectSubtitleTrack(
    YlPlaybackSessionId sessionId,
    String? trackId,
  );
  Future<void> setSubtitleOffset(
    YlPlaybackSessionId sessionId,
    Duration offset,
  );
}

/// Optional DRM configuration admission, not evidence of DRM/security support.
/// Implement only when config v1 is consumed explicitly by assess/load and a
/// protected session path is implemented. Per-source capability checks remain required.
abstract interface class YlPlatformDrmSourceSupport {
  int get drmContractVersion;
}

/// Optional runtime live-mode SPI; requires the operation and session mode gates.
/// Implementations serialize mode commits with session commands and own rollback,
/// cancellation, resource budgets and same-mode idempotence. Success occurs only
/// after the matching committed snapshot crosses the state barrier, even when a
/// subsequent command already changed the latest mode. A property setter or a
/// native reply alone is not an ACK. Failed candidates preserve the prior mode,
/// or publish session failure if safe rollback is impossible. Never reset retry
/// budgets, relax fixed/caps/hardware/bounded policies or change playback intent.
abstract interface class YlLivePlaybackPlatformPlayer {
  Future<void> setLivePlaybackMode(
    YlPlaybackSessionId sessionId,
    YlLivePlaybackMode mode,
  );
}
