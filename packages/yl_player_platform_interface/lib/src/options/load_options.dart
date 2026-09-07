import '../model/value_helpers.dart';
import 'policies.dart';
import 'video_constraints.dart';

/// Immutable choices for one source load.
final class YlLoadOptions {
  const YlLoadOptions({
    this.autoplay = false,
    this.startPosition,
    this.bufferStrategy = const YlBufferStrategy.automatic(),
    this.videoConstraints = const YlVideoConstraints(),
    this.decoderPolicyOverride,
  });

  final bool autoplay;
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
        startPosition == other.startPosition &&
        bufferStrategy == other.bufferStrategy &&
        videoConstraints == other.videoConstraints &&
        decoderPolicyOverride == other.decoderPolicyOverride,
  );

  @override
  int get hashCode => Object.hash(
    autoplay,
    startPosition,
    bufferStrategy,
    videoConstraints,
    decoderPolicyOverride,
  );

  @override
  String toString() =>
      'YlLoadOptions(autoplay: $autoplay, startPosition: $startPosition, '
      'bufferStrategy: $bufferStrategy, videoConstraints: $videoConstraints, '
      'decoderPolicyOverride: ${decoderPolicyOverride?.name})';
}
