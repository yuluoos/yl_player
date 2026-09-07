import 'package:flutter/foundation.dart';

import 'capabilities.dart';
import 'failure.dart';
import 'identifiers.dart';
import 'media_track.dart';
import 'playback_metrics.dart';
import 'timeline.dart';
import 'value_helpers.dart';
import 'video_geometry.dart';

const _absent = Object();

/// Immutable PlayerState value; validate at publication boundaries.
final class YlPlayerState {
  YlPlayerState({
    this.revision = 0,
    this.sessionId,
    this.status = YlPlaybackStatus.idle,
    this.timeline = const YlTimeline(),
    this.videoGeometry,
    List<YlMediaTrack> audioTracks = const [],
    List<YlMediaTrack> videoTracks = const [],
    this.engine = YlPlaybackEngine.unknown,
    this.decoderMode = YlDecoderMode.unknown,
    this.decoderIdentity,
    this.metrics = const YlPlaybackMetrics(),
    this.failure,
  }) : audioTracks = List.unmodifiable(audioTracks),
       videoTracks = List.unmodifiable(videoTracks);

  final int revision;

  final YlPlaybackSessionId? sessionId;

  final YlPlaybackStatus status;

  final YlTimeline timeline;

  final YlVideoGeometry? videoGeometry;

  final List<YlMediaTrack> audioTracks;

  final List<YlMediaTrack> videoTracks;

  final YlPlaybackEngine engine;

  final YlDecoderMode decoderMode;

  final String? decoderIdentity;

  final YlPlaybackMetrics metrics;

  final YlFailure? failure;

  /// Omitted fields are preserved; explicit null clears nullable fields.
  YlPlayerState copyWith({
    int? revision,
    Object? sessionId = _absent,
    YlPlaybackStatus? status,
    YlTimeline? timeline,
    Object? videoGeometry = _absent,
    List<YlMediaTrack>? audioTracks,
    List<YlMediaTrack>? videoTracks,
    YlPlaybackEngine? engine,
    YlDecoderMode? decoderMode,
    Object? decoderIdentity = _absent,
    YlPlaybackMetrics? metrics,
    Object? failure = _absent,
  }) => YlPlayerState(
    revision: revision ?? this.revision,
    sessionId: identical(sessionId, _absent)
        ? this.sessionId
        : ylNullableValue<YlPlaybackSessionId>(sessionId),
    status: status ?? this.status,
    timeline: timeline ?? this.timeline,
    videoGeometry: identical(videoGeometry, _absent)
        ? this.videoGeometry
        : ylNullableValue<YlVideoGeometry>(videoGeometry),
    audioTracks: audioTracks ?? this.audioTracks,
    videoTracks: videoTracks ?? this.videoTracks,
    engine: engine ?? this.engine,
    decoderMode: decoderMode ?? this.decoderMode,
    decoderIdentity: identical(decoderIdentity, _absent)
        ? this.decoderIdentity
        : ylNullableValue<String>(decoderIdentity),
    metrics: metrics ?? this.metrics,
    failure: identical(failure, _absent)
        ? this.failure
        : ylNullableValue<YlFailure>(failure),
  );

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        revision == other.revision &&
        sessionId == other.sessionId &&
        status == other.status &&
        timeline == other.timeline &&
        videoGeometry == other.videoGeometry &&
        listEquals(audioTracks, other.audioTracks) &&
        listEquals(videoTracks, other.videoTracks) &&
        engine == other.engine &&
        decoderMode == other.decoderMode &&
        decoderIdentity == other.decoderIdentity &&
        metrics == other.metrics &&
        failure == other.failure,
  );

  @override
  int get hashCode => Object.hashAll([
    revision,
    sessionId,
    status,
    timeline,
    videoGeometry,
    Object.hashAll(audioTracks),
    Object.hashAll(videoTracks),
    engine,
    decoderMode,
    decoderIdentity,
    metrics,
    failure,
  ]);

  @override
  String toString() =>
      'YlPlayerState(revision: $revision, sessionId: $sessionId, status: $status, timeline: $timeline, videoGeometry: $videoGeometry, audioTracks: $audioTracks, videoTracks: $videoTracks, engine: $engine, decoderMode: $decoderMode, decoderIdentity: <redacted>, metrics: $metrics, failure: $failure)';
}
