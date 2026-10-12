part of 'matroska_subtitles.dart';

/// Validate global blocks without turning them into independently timed cues.
void _webVttHeader(String header) {
  final doc = SubtitleDocument.parse(
    utf8.encode(header),
    format: SubtitleFormat.webvtt,
  );
  if (doc.cues.isNotEmpty) {
    throw const SubtitleParseException(SubtitleParseReason.unsupported);
  }
}

EmbeddedSubtitlePacket _webVttPacket(
  Duration start,
  Duration end,
  String text,
  String? metadata,
  bool inBlock,
) {
  Never bad() =>
      throw const SubtitleParseException(SubtitleParseReason.malformed);
  Never limit() =>
      throw const SubtitleParseException(SubtitleParseReason.limitExceeded);
  String normalize(String s) =>
      s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  text = normalize(text);
  var id = '', settings = '';
  if (inBlock) {
    // The D_WEBVTT mapping prefixes the Block with identifier, then settings.
    final first = text.indexOf('\n');
    final second = first < 0 ? -1 : text.indexOf('\n', first + 1);
    if (second < 0) bad();
    id = text.substring(0, first);
    settings = text.substring(first + 1, second);
    text = text.substring(second + 1);
  } else if (metadata != null) {
    // S_TEXT/WEBVTT stores settings, identifier and preceding NOTE blocks in
    // BlockAdditional ID 1. A terminal identifier may omit its trailing LF.
    metadata = normalize(metadata);
    if (metadata.contains('\u0000')) bad();
    final first = metadata.indexOf('\n');
    if (first < 0) bad();
    final second = metadata.indexOf('\n', first + 1);
    settings = metadata.substring(0, first);
    id = metadata.substring(first + 1, second < 0 ? metadata.length : second);
    if (second >= 0) {
      _webVttHeader('WEBVTT\n\n${metadata.substring(second + 1)}');
    }
  }
  if (id.length > 1024 || text.length > 16384) limit();
  if (id.contains('-->') ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(id) ||
      text.isEmpty) {
    bad();
  }
  return EmbeddedSubtitlePacket(
    start,
    end,
    text,
    identifier: id.isEmpty ? null : id,
    webvttSettings: WebVttCueSettings.parse(settings),
  );
}
