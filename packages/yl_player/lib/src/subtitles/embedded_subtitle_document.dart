part of 'subtitle_document.dart';

/// One decoded container block. Container timing is authoritative, including
/// sub-centisecond ASS times; packet content cannot inject file-level events.
final class EmbeddedSubtitlePacket {
  const EmbeddedSubtitlePacket(
    this.start,
    this.end,
    this.text, {
    this.textRuns,
    this.alignment = 'center',
  });
  final Duration start, end;
  final String text;
  final List<SubtitleTextRun>? textRuns;
  final String alignment;
  @override
  String toString() => 'EmbeddedSubtitlePacket(payload: <redacted>)';
}

SubtitleDocument _embeddedDocument(
  List<EmbeddedSubtitlePacket> packets,
  SubtitleFormat format,
  String? header,
  SubtitleLimits limits,
) {
  limits._validate();
  if (![
    SubtitleFormat.srt,
    SubtitleFormat.ass,
    SubtitleFormat.ssa,
  ].contains(format)) {
    _unsupported();
  }
  if (packets.length > limits.maxCues) _limit();
  var bytes = utf8.encode(header ?? '').length;
  for (final p in packets) {
    bytes += utf8.encode(p.text).length;
    if (bytes > limits.maxInputBytes ||
        p.text.length > limits.maxCueCodeUnits + 4096) {
      _limit();
    }
    if (p.start.isNegative ||
        p.end <= p.start ||
        p.end > const Duration(days: 7) ||
        p.text.isEmpty ||
        p.text.contains('\u0000')) {
      _malformed();
    }
  }
  if (format == SubtitleFormat.srt) {
    if (header?.isNotEmpty ?? false) _unsupported();
    final cues = <SubtitleCue>[];
    for (final p in packets) {
      if (p.text.length > limits.maxCueCodeUnits) _limit();
      cues.add(
        SubtitleCue._(
          ordinal: cues.length,
          identifier: null,
          start: p.start,
          end: p.end,
          payload: p.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
          textRuns: p.textRuns,
          alignment: p.alignment,
        ),
      );
    }
    return SubtitleDocument._finish(cues, bytes, limits);
  }
  if (header == null || header.contains('\u0000')) _malformed();
  if (bytes > limits.maxInputBytes) _limit();
  final parser = _AssParser(limits, format == SubtitleFormat.ssa);
  parser.parse(header, bytes, headerOnly: true);
  final rows =
      <({int order, EmbeddedSubtitlePacket packet, Map<String, String> row})>[];
  final orders = <int>{};
  for (final p in packets) {
    if (p.text.contains('\n') || p.text.contains('\r')) _malformed();
    final fields = <String>[];
    var at = 0;
    for (var i = 0; i < 8; i++) {
      final end = p.text.indexOf(',', at);
      if (end < 0) _malformed();
      fields.add(p.text.substring(at, end));
      at = end + 1;
    }
    fields.add(p.text.substring(at));
    final order = int.tryParse(fields[0]);
    if (order == null ||
        order < 0 ||
        order > 0x7fffffff ||
        !orders.add(order)) {
      _malformed();
    }
    if (parser.ssa && fields[1].isNotEmpty && fields[1] != '0') _unsupported();
    rows.add((
      order: order,
      packet: p,
      row: {
        'layer': fields[1],
        'marked': 'Marked=0',
        'style': fields[2],
        'name': fields[3],
        'marginl': fields[4],
        'marginr': fields[5],
        'marginv': fields[6],
        'effect': fields[7],
        'text': fields[8],
      },
    ));
  }
  rows.sort((a, b) => a.order.compareTo(b.order));
  for (final row in rows) {
    parser.dialogue(
      row.row,
      startOverride: row.packet.start,
      endOverride: row.packet.end,
    );
  }
  return SubtitleDocument._finish(parser.cues, bytes, limits);
}
