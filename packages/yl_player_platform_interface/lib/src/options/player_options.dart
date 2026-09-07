import '../model/value_helpers.dart';
import 'policies.dart';

/// Immutable player-wide choices captured at creation. The update interval must
/// be a positive whole number of signed32 milliseconds.
final class YlPlayerOptions {
  const YlPlayerOptions({
    this.decoderPolicy = YlDecoderPolicy.hardwarePreferred,
    this.audioPolicy = YlAudioPolicy.appManaged,
    this.positionUpdateInterval = const Duration(milliseconds: 250),
  });

  final YlDecoderPolicy decoderPolicy;
  final YlAudioPolicy audioPolicy;
  final Duration positionUpdateInterval;

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        decoderPolicy == other.decoderPolicy &&
        audioPolicy == other.audioPolicy &&
        positionUpdateInterval == other.positionUpdateInterval,
  );

  @override
  int get hashCode =>
      Object.hash(decoderPolicy, audioPolicy, positionUpdateInterval);

  @override
  String toString() =>
      'YlPlayerOptions(decoderPolicy: ${decoderPolicy.name}, '
      'audioPolicy: ${audioPolicy.name}, positionUpdateInterval: $positionUpdateInterval)';
}
