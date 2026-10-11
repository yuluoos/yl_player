import 'package:flutter/foundation.dart';

import '../source/media_source.dart';
import 'value_helpers.dart';

/// Format identity, not a declaration of platform decoding/rendering support.
enum YlSubtitleFormat { srt, webvtt, ttml, ass, ssa, pgs, vobsub }

/// One external subtitle resource and its declared request requirements.
/// VobSub uses [source] for .sub and [companionSource] for .idx.
/// Validate at command boundaries; only file and HTTP(S) sources are allowed.
final class YlExternalSubtitle {
  const YlExternalSubtitle({
    required this.id,
    required this.source,
    required this.format,
    this.companionSource,
    this.label,
    this.language,
    this.role,
    this.contentId,
  });

  final String id;
  final YlMediaSource source;
  final YlSubtitleFormat format;
  final YlMediaSource? companionSource;
  final String? label;
  final String? language;
  final String? role;
  final String? contentId;

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        id == other.id &&
        source == other.source &&
        format == other.format &&
        companionSource == other.companionSource &&
        label == other.label &&
        language == other.language &&
        role == other.role &&
        contentId == other.contentId,
  );

  @override
  int get hashCode => Object.hash(
    id,
    source,
    format,
    companionSource,
    label,
    language,
    role,
    contentId,
  );

  @override
  String toString() =>
      'YlExternalSubtitle(format: $format, metadata: <redacted>, resources: <redacted>)';
}

/// One session-scoped stable identity; language or array index is not identity.
/// A missing identity must not be silently remapped to a same-language track.
final class YlSubtitleTrack {
  const YlSubtitleTrack({
    required this.id,
    required this.format,
    this.isExternal = false,
    this.label,
    this.language,
    this.role,
    this.contentId,
  });

  final String id;
  final YlSubtitleFormat format;
  final bool isExternal;
  final String? label;
  final String? language;
  final String? role;
  final String? contentId;

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        id == other.id &&
        format == other.format &&
        isExternal == other.isExternal &&
        label == other.label &&
        language == other.language &&
        role == other.role &&
        contentId == other.contentId,
  );

  @override
  int get hashCode =>
      Object.hash(id, format, isExternal, label, language, role, contentId);

  @override
  String toString() =>
      'YlSubtitleTrack(format: $format, isExternal: $isExternal, metadata: <redacted>)';
}

const _absent = Object();

/// Authoritative catalog and selection. Null selection means explicitly off.
/// Positive offset delays subtitles; negative offset advances them.
final class YlSubtitleState {
  YlSubtitleState({
    List<YlSubtitleTrack> tracks = const [],
    this.selectedTrackId,
    this.offset = Duration.zero,
  }) : tracks = List.unmodifiable(tracks);

  final List<YlSubtitleTrack> tracks;
  final String? selectedTrackId;
  final Duration offset;

  YlSubtitleState copyWith({
    List<YlSubtitleTrack>? tracks,
    Object? selectedTrackId = _absent,
    Duration? offset,
  }) => YlSubtitleState(
    tracks: tracks ?? this.tracks,
    selectedTrackId: identical(selectedTrackId, _absent)
        ? this.selectedTrackId
        : ylNullableValue<String>(selectedTrackId),
    offset: offset ?? this.offset,
  );

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        listEquals(tracks, other.tracks) &&
        selectedTrackId == other.selectedTrackId &&
        offset == other.offset,
  );

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(tracks), selectedTrackId, offset);

  @override
  String toString() =>
      'YlSubtitleState(trackCount: ${tracks.length}, '
      'enabled: ${selectedTrackId != null}, offset: $offset, selectedTrackId: <redacted>)';
}
