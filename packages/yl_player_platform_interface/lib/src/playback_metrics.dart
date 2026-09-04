const Object _notProvided = Object();

/// Locally observable playback quality metrics.
final class YlPlaybackMetrics {
  const YlPlaybackMetrics({
    this.openDuration,
    this.firstFrameDuration,
    this.rebufferCount = 0,
    this.rebufferDuration = Duration.zero,
    this.droppedVideoFrames = 0,
    this.audioUnderruns = 0,
    this.estimatedBitrate,
    this.bufferedDuration = Duration.zero,
    this.bufferedBytes = 0,
    this.liveOffset,
    this.reconnectCount = 0,
    this.androidDeviceTier,
    this.targetBufferBytes,
    this.adaptiveDowngradeCount,
    this.surfaceRebuildCount,
    this.selectedVideoBitrate,
  });

  final Duration? openDuration;
  final Duration? firstFrameDuration;
  final int rebufferCount;
  final Duration rebufferDuration;
  final int droppedVideoFrames;
  final int audioUnderruns;
  final int? estimatedBitrate;
  final Duration bufferedDuration;
  final int bufferedBytes;
  final Duration? liveOffset;
  final int reconnectCount;
  final String? androidDeviceTier;
  final int? targetBufferBytes;
  final int? adaptiveDowngradeCount;
  final int? surfaceRebuildCount;
  final int? selectedVideoBitrate;

  YlPlaybackMetrics copyWith({
    Object? openDuration = _notProvided,
    Object? firstFrameDuration = _notProvided,
    int? rebufferCount,
    Duration? rebufferDuration,
    int? droppedVideoFrames,
    int? audioUnderruns,
    Object? estimatedBitrate = _notProvided,
    Duration? bufferedDuration,
    int? bufferedBytes,
    Object? liveOffset = _notProvided,
    int? reconnectCount,
    Object? androidDeviceTier = _notProvided,
    Object? targetBufferBytes = _notProvided,
    Object? adaptiveDowngradeCount = _notProvided,
    Object? surfaceRebuildCount = _notProvided,
    Object? selectedVideoBitrate = _notProvided,
  }) => YlPlaybackMetrics(
    openDuration: identical(openDuration, _notProvided)
        ? this.openDuration
        : openDuration as Duration?,
    firstFrameDuration: identical(firstFrameDuration, _notProvided)
        ? this.firstFrameDuration
        : firstFrameDuration as Duration?,
    rebufferCount: rebufferCount ?? this.rebufferCount,
    rebufferDuration: rebufferDuration ?? this.rebufferDuration,
    droppedVideoFrames: droppedVideoFrames ?? this.droppedVideoFrames,
    audioUnderruns: audioUnderruns ?? this.audioUnderruns,
    estimatedBitrate: identical(estimatedBitrate, _notProvided)
        ? this.estimatedBitrate
        : estimatedBitrate as int?,
    bufferedDuration: bufferedDuration ?? this.bufferedDuration,
    bufferedBytes: bufferedBytes ?? this.bufferedBytes,
    liveOffset: identical(liveOffset, _notProvided)
        ? this.liveOffset
        : liveOffset as Duration?,
    reconnectCount: reconnectCount ?? this.reconnectCount,
    androidDeviceTier: identical(androidDeviceTier, _notProvided)
        ? this.androidDeviceTier
        : androidDeviceTier as String?,
    targetBufferBytes: identical(targetBufferBytes, _notProvided)
        ? this.targetBufferBytes
        : targetBufferBytes as int?,
    adaptiveDowngradeCount: identical(adaptiveDowngradeCount, _notProvided)
        ? this.adaptiveDowngradeCount
        : adaptiveDowngradeCount as int?,
    surfaceRebuildCount: identical(surfaceRebuildCount, _notProvided)
        ? this.surfaceRebuildCount
        : surfaceRebuildCount as int?,
    selectedVideoBitrate: identical(selectedVideoBitrate, _notProvided)
        ? this.selectedVideoBitrate
        : selectedVideoBitrate as int?,
  );
}
