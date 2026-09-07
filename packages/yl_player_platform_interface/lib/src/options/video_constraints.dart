import '../model/value_helpers.dart';

const _absent = Object();

/// Optional positive signed32 adaptive-video limits; null is unconstrained.
final class YlVideoConstraints {
  const YlVideoConstraints({this.maxWidth, this.maxHeight, this.maxBitrate});

  final int? maxWidth;
  final int? maxHeight;
  final int? maxBitrate;

  /// Omitted fields are preserved; explicitly passing null clears a limit.
  YlVideoConstraints copyWith({
    Object? maxWidth = _absent,
    Object? maxHeight = _absent,
    Object? maxBitrate = _absent,
  }) => YlVideoConstraints(
    maxWidth: identical(maxWidth, _absent) ? this.maxWidth : _limit(maxWidth),
    maxHeight: identical(maxHeight, _absent)
        ? this.maxHeight
        : _limit(maxHeight),
    maxBitrate: identical(maxBitrate, _absent)
        ? this.maxBitrate
        : _limit(maxBitrate),
  );

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        maxWidth == other.maxWidth &&
        maxHeight == other.maxHeight &&
        maxBitrate == other.maxBitrate,
  );

  @override
  int get hashCode => Object.hash(maxWidth, maxHeight, maxBitrate);

  @override
  String toString() =>
      'YlVideoConstraints(maxWidth: $maxWidth, '
      'maxHeight: $maxHeight, maxBitrate: $maxBitrate)';
}

int? _limit(Object? value) {
  if (value == null || value is int) return value as int?;
  throw ArgumentError('Video constraints must be integers or null.');
}
