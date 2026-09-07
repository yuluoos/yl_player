import 'value_helpers.dart';

enum YlTrackKind { audio, video }

const _absent = Object();

/// Immutable MediaTrack value; validate at publication boundaries.
final class YlMediaTrack {
  const YlMediaTrack({
    required this.id,
    required this.kind,
    this.isSelected = false,
    this.label,
    this.language,
    this.codec,
    this.bitrate,
    this.width,
    this.height,
  });

  final String id;

  final YlTrackKind kind;

  final bool isSelected;

  final String? label;

  final String? language;

  final String? codec;

  final int? bitrate;

  final int? width;

  final int? height;

  /// Omitted fields are preserved; explicit null clears nullable fields.
  YlMediaTrack copyWith({
    String? id,
    YlTrackKind? kind,
    bool? isSelected,
    Object? label = _absent,
    Object? language = _absent,
    Object? codec = _absent,
    Object? bitrate = _absent,
    Object? width = _absent,
    Object? height = _absent,
  }) => YlMediaTrack(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    isSelected: isSelected ?? this.isSelected,
    label: identical(label, _absent)
        ? this.label
        : ylNullableValue<String>(label),
    language: identical(language, _absent)
        ? this.language
        : ylNullableValue<String>(language),
    codec: identical(codec, _absent)
        ? this.codec
        : ylNullableValue<String>(codec),
    bitrate: identical(bitrate, _absent)
        ? this.bitrate
        : ylNullableValue<int>(bitrate),
    width: identical(width, _absent) ? this.width : ylNullableValue<int>(width),
    height: identical(height, _absent)
        ? this.height
        : ylNullableValue<int>(height),
  );

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        id == other.id &&
        kind == other.kind &&
        isSelected == other.isSelected &&
        label == other.label &&
        language == other.language &&
        codec == other.codec &&
        bitrate == other.bitrate &&
        width == other.width &&
        height == other.height,
  );

  @override
  int get hashCode => Object.hashAll([
    id,
    kind,
    isSelected,
    label,
    language,
    codec,
    bitrate,
    width,
    height,
  ]);

  @override
  String toString() =>
      'YlMediaTrack(id: <redacted>, kind: $kind, isSelected: $isSelected, label: <redacted>, language: <redacted>, codec: <redacted>, bitrate: $bitrate, width: $width, height: $height)';
}
