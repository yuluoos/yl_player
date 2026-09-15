import 'value_helpers.dart';

const _absent = Object();

/// Immutable PlaybackMetrics value; validate at publication boundaries.
final class YlPlaybackMetrics {
  const YlPlaybackMetrics({
    this.loadToReady,
    this.loadToFirstFrame,
    this.rebufferCount,
    this.rebufferDuration,
    this.droppedVideoFrames,
    this.audioUnderruns,
    this.estimatedBitrate,
    this.managedBufferedDuration,
    this.managedBufferedBytes,
    this.liveOffset,
    this.reconnectCount,
    this.mediaClockPosition,
  });

  final Duration? loadToReady;

  final Duration? loadToFirstFrame;

  final int? rebufferCount;

  final Duration? rebufferDuration;

  final int? droppedVideoFrames;

  final int? audioUnderruns;

  final int? estimatedBitrate;

  final Duration? managedBufferedDuration;

  final int? managedBufferedBytes;

  final Duration? liveOffset;

  final int? reconnectCount;

  /// Observed media-clock position for detecting playback progress. Unlike a
  /// live window's timeline position, this includes the window's native period
  /// offset. It may reset on seek, period change or engine restart. Never use it
  /// as a seek target. Null means the backend has no observation.
  final Duration? mediaClockPosition;

  /// Omitted fields are preserved; explicit null clears nullable fields.
  YlPlaybackMetrics copyWith({
    Object? loadToReady = _absent,
    Object? loadToFirstFrame = _absent,
    Object? rebufferCount = _absent,
    Object? rebufferDuration = _absent,
    Object? droppedVideoFrames = _absent,
    Object? audioUnderruns = _absent,
    Object? estimatedBitrate = _absent,
    Object? managedBufferedDuration = _absent,
    Object? managedBufferedBytes = _absent,
    Object? liveOffset = _absent,
    Object? reconnectCount = _absent,
    Object? mediaClockPosition = _absent,
  }) => YlPlaybackMetrics(
    loadToReady: identical(loadToReady, _absent)
        ? this.loadToReady
        : ylNullableValue<Duration>(loadToReady),
    loadToFirstFrame: identical(loadToFirstFrame, _absent)
        ? this.loadToFirstFrame
        : ylNullableValue<Duration>(loadToFirstFrame),
    rebufferCount: identical(rebufferCount, _absent)
        ? this.rebufferCount
        : ylNullableValue<int>(rebufferCount),
    rebufferDuration: identical(rebufferDuration, _absent)
        ? this.rebufferDuration
        : ylNullableValue<Duration>(rebufferDuration),
    droppedVideoFrames: identical(droppedVideoFrames, _absent)
        ? this.droppedVideoFrames
        : ylNullableValue<int>(droppedVideoFrames),
    audioUnderruns: identical(audioUnderruns, _absent)
        ? this.audioUnderruns
        : ylNullableValue<int>(audioUnderruns),
    estimatedBitrate: identical(estimatedBitrate, _absent)
        ? this.estimatedBitrate
        : ylNullableValue<int>(estimatedBitrate),
    managedBufferedDuration: identical(managedBufferedDuration, _absent)
        ? this.managedBufferedDuration
        : ylNullableValue<Duration>(managedBufferedDuration),
    managedBufferedBytes: identical(managedBufferedBytes, _absent)
        ? this.managedBufferedBytes
        : ylNullableValue<int>(managedBufferedBytes),
    liveOffset: identical(liveOffset, _absent)
        ? this.liveOffset
        : ylNullableValue<Duration>(liveOffset),
    mediaClockPosition: identical(mediaClockPosition, _absent)
        ? this.mediaClockPosition
        : ylNullableValue<Duration>(mediaClockPosition),
    reconnectCount: identical(reconnectCount, _absent)
        ? this.reconnectCount
        : ylNullableValue<int>(reconnectCount),
  );

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        loadToReady == other.loadToReady &&
        loadToFirstFrame == other.loadToFirstFrame &&
        rebufferCount == other.rebufferCount &&
        rebufferDuration == other.rebufferDuration &&
        droppedVideoFrames == other.droppedVideoFrames &&
        audioUnderruns == other.audioUnderruns &&
        estimatedBitrate == other.estimatedBitrate &&
        managedBufferedDuration == other.managedBufferedDuration &&
        managedBufferedBytes == other.managedBufferedBytes &&
        liveOffset == other.liveOffset &&
        reconnectCount == other.reconnectCount &&
        mediaClockPosition == other.mediaClockPosition,
  );

  @override
  int get hashCode => Object.hashAll([
    loadToReady,
    loadToFirstFrame,
    rebufferCount,
    rebufferDuration,
    droppedVideoFrames,
    audioUnderruns,
    estimatedBitrate,
    managedBufferedDuration,
    managedBufferedBytes,
    liveOffset,
    reconnectCount,
    mediaClockPosition,
  ]);

  @override
  String toString() =>
      'YlPlaybackMetrics(loadToReady: $loadToReady, loadToFirstFrame: $loadToFirstFrame, rebufferCount: $rebufferCount, rebufferDuration: $rebufferDuration, droppedVideoFrames: $droppedVideoFrames, audioUnderruns: $audioUnderruns, estimatedBitrate: $estimatedBitrate, managedBufferedDuration: $managedBufferedDuration, managedBufferedBytes: $managedBufferedBytes, liveOffset: $liveOffset, reconnectCount: $reconnectCount, mediaClockPosition: $mediaClockPosition)';
}
