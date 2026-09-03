/// The kind of selectable media track.
enum YlTrackKind { audio, video }

/// Immutable metadata for a selectable audio or video track.
final class YlMediaTrack {
  const YlMediaTrack({
    required this.id,
    required this.kind,
    this.label,
    this.language,
    this.codec,
    this.bitrate,
    this.width,
    this.height,
    this.isSelected = false,
  });

  final String id;
  final YlTrackKind kind;
  final String? label;
  final String? language;
  final String? codec;
  final int? bitrate;
  final int? width;
  final int? height;
  final bool isSelected;
}
