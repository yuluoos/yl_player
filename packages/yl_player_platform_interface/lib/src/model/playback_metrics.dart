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
        reconnectCount == other.reconnectCount,
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
  ]);

  @override
  String toString() =>
      'YlPlaybackMetrics(loadToReady: $loadToReady, loadToFirstFrame: $loadToFirstFrame, rebufferCount: $rebufferCount, rebufferDuration: $rebufferDuration, droppedVideoFrames: $droppedVideoFrames, audioUnderruns: $audioUnderruns, estimatedBitrate: $estimatedBitrate, managedBufferedDuration: $managedBufferedDuration, managedBufferedBytes: $managedBufferedBytes, liveOffset: $liveOffset, reconnectCount: $reconnectCount)';
}
