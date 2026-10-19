import '../model/value_helpers.dart';
import 'policies.dart';
import 'video_constraints.dart';

/// Immutable choices for one source load.
final class YlLoadOptions {
  const YlLoadOptions({
    this.autoplay = false,
    this.airPlay = false,
    this.startPosition,
    this.bufferStrategy = const YlBufferStrategy.automatic(),
    this.videoConstraints = const YlVideoConstraints(),
    this.decoderPolicyOverride,
  });

  final bool autoplay;

  /// Requires an AirPlay-capable playback path. Device selection remains manual.
  final bool airPlay;
  final Duration? startPosition;
  final YlBufferStrategy bufferStrategy;
  final YlVideoConstraints videoConstraints;
  final YlDecoderPolicy? decoderPolicyOverride;

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        autoplay == other.autoplay &&
        airPlay == other.airPlay &&
        startPosition == other.startPosition &&
        bufferStrategy == other.bufferStrategy &&
        videoConstraints == other.videoConstraints &&
        decoderPolicyOverride == other.decoderPolicyOverride,
  );

  @override
  int get hashCode => Object.hash(
    autoplay,
    airPlay,
    startPosition,
    bufferStrategy,
    videoConstraints,
    decoderPolicyOverride,
  );

  @override
  String toString() =>
      'YlLoadOptions(autoplay: $autoplay, airPlay: $airPlay, startPosition: $startPosition, '
      'bufferStrategy: $bufferStrategy, videoConstraints: $videoConstraints, '
      'decoderPolicyOverride: ${decoderPolicyOverride?.name})';
}
