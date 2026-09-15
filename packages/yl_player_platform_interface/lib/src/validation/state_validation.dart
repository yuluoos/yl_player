import '../model/capabilities.dart';
import '../model/failure.dart';
import '../model/identifiers.dart';
import '../model/media_track.dart';
import '../model/playback_metrics.dart';
import '../model/player_event.dart';
import '../model/player_state.dart';
import '../model/source_assessment.dart';
import '../model/timeline.dart';
import '../model/video_geometry.dart';

const _maxSigned64 = 0x7fffffffffffffff;
final _safeMetadata = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
final _safeVideoMime = RegExp(r'^video/[a-z0-9][a-z0-9._+-]{0,121}$');

void validateYlPlayerCapabilities(YlPlayerCapabilities capabilities) {
  _metadata(capabilities.deviceProfile);
  for (final codec in capabilities.hardwareVideoCodecs) {
    final legacy = _safeMetadata.firstMatch(codec);
    final mime = _safeVideoMime.firstMatch(codec);
    if ((legacy == null || legacy.end != codec.length) &&
        (mime == null || mime.end != codec.length)) {
      throw ArgumentError('Capability codec metadata is invalid.');
    }
  }
  for (final limit in [
    capabilities.maxConcurrentVideoDecoders,
    capabilities.maxWidth,
    capabilities.maxHeight,
  ]) {
    if (limit != null) _integer(limit, positive: true);
  }
}

void validateYlSourceAssessment(YlSourceAssessment assessment) {
  if ((assessment.outcome == YlSourceAssessmentOutcome.incompatible) !=
      (assessment.rejection != null)) {
    throw ArgumentError(
      'Rejection must be present exactly for incompatibility.',
    );
  }
}

/// Validate before native-to-domain decoding and before controller publication.
/// Constructors remain const, so correctness never depends on Dart assertions.
void validateYlPixelSize(YlPixelSize size) {
  if (!size.width.isFinite ||
      !size.height.isFinite ||
      size.width <= 0 ||
      size.height <= 0) {
    throw ArgumentError('Pixel dimensions must be finite and positive.');
  }
}

void validateYlVideoGeometry(YlVideoGeometry geometry) {
  validateYlPixelSize(geometry.encodedSize);
  validateYlPixelSize(geometry.displaySize);
  final par = geometry.pixelAspectRatio;
  final adjustedWidth = geometry.displaySize.width * par;
  final ratio = geometry.displayAspectRatio;
  if (!par.isFinite ||
      par <= 0 ||
      !adjustedWidth.isFinite ||
      adjustedWidth <= 0 ||
      !ratio.isFinite ||
      ratio <= 0 ||
      !const [0, 90, 180, 270].contains(geometry.rotationDegrees)) {
    throw ArgumentError(
      'Video geometry must have a valid aspect and rotation.',
    );
  }
}

void validateYlDvrWindow(YlDvrWindow window) {
  _duration(window.start);
  _duration(window.end);
  if (window.end < window.start) {
    throw ArgumentError('DVR window endpoints must be ordered.');
  }
}

/// Raw native negative live offsets must be clamped to zero by the adapter
/// before constructing these domain values. Other negative times are invalid.
void validateYlTimeline(YlTimeline timeline) {
  for (final time in [
    timeline.position,
    timeline.bufferedPosition,
    timeline.duration,
    timeline.liveOffset,
  ]) {
    if (time != null) _duration(time);
  }
  final window = timeline.dvrWindow;
  if (window != null) validateYlDvrWindow(window);
}

void validateYlPlaybackMetrics(YlPlaybackMetrics metrics) {
  for (final duration in [
    metrics.loadToReady,
    metrics.loadToFirstFrame,
    metrics.rebufferDuration,
    metrics.managedBufferedDuration,
    metrics.liveOffset,
    metrics.mediaClockPosition,
  ]) {
    if (duration != null) _duration(duration);
  }
  for (final count in [
    metrics.rebufferCount,
    metrics.droppedVideoFrames,
    metrics.audioUnderruns,
    metrics.estimatedBitrate,
    metrics.managedBufferedBytes,
    metrics.reconnectCount,
  ]) {
    if (count != null) _integer(count);
  }
}

void validateYlMediaTrack(YlMediaTrack track) {
  if (track.id.isEmpty) throw ArgumentError('Track ID must not be empty.');
  for (final label in [track.label, track.language, track.codec]) {
    if (label != null && label.isEmpty) {
      throw ArgumentError('Unknown track metadata must be null.');
    }
  }
  for (final size in [track.bitrate, track.width, track.height]) {
    if (size != null) _integer(size, positive: true);
  }
}

/// Validates a complete snapshot at the controller/native acceptance boundary.
/// Ordering against previous revisions and callback sessions belongs to the
/// controller, since a single immutable snapshot cannot establish chronology.
void validateYlPlayerState(YlPlayerState state) {
  _integer(state.revision);
  final sessionId = state.sessionId;
  if (sessionId != null) validateYlPlaybackSessionId(sessionId);
  if (state.status == YlPlaybackStatus.idle && sessionId != null ||
      state.status != YlPlaybackStatus.idle &&
          sessionId == null &&
          !(state.status == YlPlaybackStatus.failed &&
              state.failure?.scope == YlFailureScope.player)) {
    throw ArgumentError('Playback state has an invalid session association.');
  }
  validateYlTimeline(state.timeline);
  validateYlPlaybackMetrics(state.metrics);
  final geometry = state.videoGeometry;
  if (geometry != null) validateYlVideoGeometry(geometry);
  for (final track in state.audioTracks) {
    validateYlMediaTrack(track);
    if (track.kind != YlTrackKind.audio) {
      throw ArgumentError('Audio track list contains a different track kind.');
    }
  }
  for (final track in state.videoTracks) {
    validateYlMediaTrack(track);
    if (track.kind != YlTrackKind.video) {
      throw ArgumentError('Video track list contains a different track kind.');
    }
  }
}

/// Durations use an implementation-local monotonic epoch, never wall time.
/// Adapters must check native time scalars before Duration construction to avoid
/// overflowing its microsecond storage; validation cannot recover wrapped input.
void validateYlPlayerEvent(YlPlayerEvent event) {
  validateYlPlaybackSessionId(event.sessionId);
  _integer(event.revision);
  _duration(event.occurredAt);
  switch (event) {
    case YlRetryScheduledEvent():
      _integer(event.retryIndex, positive: true);
      _duration(event.delay);
    case YlFirstFrameEvent():
    case YlPlaybackEngineChangedEvent():
    case YlPlaybackFailedEvent():
      break;
  }
}

void _metadata(String value) {
  final match = _safeMetadata.firstMatch(value);
  if (match == null || match.end != value.length) {
    throw ArgumentError('Capability metadata must be a safe identifier.');
  }
}

void _integer(int value, {bool positive = false}) {
  if (value < (positive ? 1 : 0) || value > _maxSigned64) {
    throw ArgumentError('Value must fit the nonnegative signed64 range.');
  }
}

void _duration(Duration value) {
  if (value.isNegative) {
    throw ArgumentError('Time must be nonnegative.');
  }
}
