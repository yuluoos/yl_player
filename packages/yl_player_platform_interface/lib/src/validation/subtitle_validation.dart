import '../model/subtitles.dart';
import '../source/media_source.dart';
import 'v2_validation.dart';

final _controls = RegExp(r'[\x00-\x1f\x7f]');

void _text(String value, int limit) {
  if (value.isEmpty || value.length > limit || _controls.hasMatch(value)) {
    throw ArgumentError('Subtitle metadata is invalid.');
  }
}

void validateYlSubtitleTrackId(String id) => _text(id, 1024);

/// Whole milliseconds within ±7 days, checked before wire conversion.
void validateYlSubtitleOffset(Duration offset) {
  const bound = 7 * 24 * 60 * 60 * 1000000;
  if (offset.inMicroseconds < -bound ||
      offset.inMicroseconds > bound ||
      offset.inMicroseconds % 1000 != 0) {
    throw ArgumentError(
      'Subtitle offset must be whole milliseconds within seven days.',
    );
  }
}

void _metadata({
  required String id,
  String? label,
  String? language,
  String? role,
  String? contentId,
}) {
  validateYlSubtitleTrackId(id);
  for (final value in [label, contentId]) {
    if (value != null) _text(value, 1024);
  }
  for (final value in [language, role]) {
    if (value != null) _text(value, 128);
  }
}

void validateYlSubtitleState(YlSubtitleState state) {
  validateYlSubtitleOffset(state.offset);
  if (state.tracks.length > 128) {
    throw ArgumentError('Too many subtitle tracks.');
  }
  final ids = <String>{};
  for (final track in state.tracks) {
    _metadata(
      id: track.id,
      label: track.label,
      language: track.language,
      role: track.role,
      contentId: track.contentId,
    );
    if (!ids.add(track.id)) {
      throw ArgumentError('Duplicate subtitle track identity.');
    }
  }
  if (state.selectedTrackId case final id?) {
    validateYlSubtitleTrackId(id);
    if (!ids.contains(id)) {
      throw ArgumentError('Selected subtitle is absent from the catalog.');
    }
  }
}

void validateYlExternalSubtitles(List<YlExternalSubtitle> subtitles) {
  if (subtitles.length > 32) {
    throw ArgumentError('Too many external subtitles.');
  }
  final ids = <String>{};
  for (final subtitle in subtitles) {
    _metadata(
      id: subtitle.id,
      label: subtitle.label,
      language: subtitle.language,
      role: subtitle.role,
      contentId: subtitle.contentId,
    );
    if (!ids.add(subtitle.id)) {
      throw ArgumentError('Duplicate external subtitle identity.');
    }
    _source(subtitle.source);
    if ((subtitle.format == YlSubtitleFormat.vobsub) !=
        (subtitle.companionSource != null)) {
      throw ArgumentError(
        'Subtitle companion resource does not match the format.',
      );
    }
    if (subtitle.companionSource case final source?) _source(source);
  }
}

void _source(YlMediaSource source) {
  if (source.format != YlMediaFormat.automatic ||
      source.intent == YlStreamIntent.live) {
    throw ArgumentError('Subtitle source contains media-only requirements.');
  }
  switch (source) {
    case YlFileSource():
      if (source.path.length > 8192) {
        throw ArgumentError('Subtitle path exceeds its limit.');
      }
    case YlNetworkSource():
      // Keep URI failures input-free, including custom Uri implementations.
      var valid = false;
      try {
        valid =
            (source.uri.scheme == 'http' || source.uri.scheme == 'https') &&
            source.uri.toString().length <= 8192 &&
            source.drm == null;
      } on FormatException {
        valid = false;
      } on ArgumentError {
        valid = false;
      }
      if (!valid) throw ArgumentError('Subtitle network source is invalid.');
    case YlAndroidContentSource():
      throw ArgumentError('Subtitle source type is unsupported.');
  }
  validateYlSource(source);
}
