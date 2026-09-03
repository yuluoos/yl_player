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
}
