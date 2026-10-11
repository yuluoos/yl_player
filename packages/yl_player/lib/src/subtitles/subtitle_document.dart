import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:xml/xml.dart' show XmlDefaultEntityMapping, XmlException;
import 'package:xml/xml_events.dart';

part 'ttml_parser.dart';
part 'ass_parser.dart';
part 'pgs_parser.dart';

/// Internal parsing foundation; not a public subtitle loading/rendering API.
enum SubtitleFormat { srt, webvtt, ttml, ass, ssa, pgs }

enum SubtitleParseReason { malformed, unsupported, limitExceeded }

/// Deliberately contains no source text, URL, identifier or decoder exception.
final class SubtitleParseException implements Exception {
  const SubtitleParseException(this.reason);
  final SubtitleParseReason reason;

  @override
  String toString() => 'SubtitleParseException(${reason.name})';
}

/// Independent subtitle budgets, unrelated to the media buffer ledger.
/// Callers may lower these limits but cannot raise their hard ceilings.
final class SubtitleLimits {
  const SubtitleLimits({
    this.maxInputBytes = 4 * 1024 * 1024,
    this.maxCues = 10000,
    this.maxCueCodeUnits = 16384,
    this.maxActiveCues = 64,
    this.maxAssRuns = 20000,
    this.maxPgsBitmapBytes = 64 * 1024 * 1024,
  });

  final int maxInputBytes;
  final int maxCues;
  final int maxCueCodeUnits;
  final int maxActiveCues;

  /// Remaining ASS/SSA catalog budget, enforced before run allocation.
  final int maxAssRuns;
  final int maxPgsBitmapBytes;

  void _validate() {
    if (maxPgsBitmapBytes < 0 || maxPgsBitmapBytes > 64 * 1024 * 1024) {
      throw ArgumentError('PGS bitmap budget is outside its allowed range');
    }
    if (maxAssRuns < 0 || maxAssRuns > 20000) {
      throw ArgumentError('ASS run budget is outside its allowed range');
    }
    for (final (value, ceiling) in [
      (maxInputBytes, 4 * 1024 * 1024),
      (maxCues, 10000),
      (maxCueCodeUnits, 16384),
      (maxActiveCues, 64),
    ]) {
      if (value < 1 || value > ceiling) {
        throw ArgumentError('Subtitle budget is outside its allowed range');
      }
    }
  }
}

/// Payload is raw subtitle markup, not HTML or ready-to-display plain text.
/// Retaining markup is not evidence that its visual effects are supported.
final class SubtitleCue {
  const SubtitleCue._({
    required this.ordinal,
    required this.identifier,
    required this.start,
    required this.end,
    required this.payload,
    this.textRuns,
    this.region,
    this.ass,
    this.pgs,
    this.positionPercent,
    this.positionAlignment = 'auto',
    this.alignment = 'center',
  });

  final int ordinal;
  final String? identifier;
  final Duration start;
  final Duration end;
  final String payload;
  final List<SubtitleTextRun>? textRuns;
  final SubtitleRegion? region;
  final AssCueLayout? ass;
  final PgsFrame? pgs;
  final double? positionPercent;
  final String positionAlignment;
  final String alignment;

  @override
  String toString() =>
      'SubtitleCue(ordinal: $ordinal, '
      'start: $start, end: $end, payload: <redacted>, identifier: <redacted>)';
}

final class SubtitleDocument {
  SubtitleDocument._(List<SubtitleCue> cues, this.inputBytes)
    : cues = List.unmodifiable(cues),
      _index = _CueNode.build(
        [...cues]..sort((a, b) {
          final order = a.start.compareTo(b.start);
          return order == 0 ? a.ordinal.compareTo(b.ordinal) : order;
        }),
        0,
        cues.length,
      );

  final List<SubtitleCue> cues;
  final int inputBytes;
  int get pgsBitmapBytes =>
      cues.fold(0, (n, c) => n + (c.pgs?.byteLength ?? 0));
  final _CueNode? _index;

  /// Strict UTF-8 and strict supported syntax: malformed documents are rejected
  /// atomically rather than silently dropping a damaged cue.
  static SubtitleDocument parse(
    List<int> bytes, {
    required SubtitleFormat format,
    SubtitleLimits limits = const SubtitleLimits(),
  }) {
    limits._validate();
    if (bytes.length > limits.maxInputBytes) _limit();
    // The List<int> boundary must not silently mask non-byte integers.
    if (bytes.any((byte) => byte < 0 || byte > 255)) _malformed();
    if (format == SubtitleFormat.pgs) return _parsePgs(bytes, limits);
    String text;
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      _malformed();
    }
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    if (text.contains('\u0000')) _malformed();
    if (format == SubtitleFormat.ttml) {
      return _parseTtml(text, bytes.length, limits);
    }
    if (format == SubtitleFormat.ass || format == SubtitleFormat.ssa) {
      return _parseAss(
        text,
        bytes.length,
        limits,
        format == SubtitleFormat.ssa,
      );
    }
    // Bound line objects as well as payload bytes before allocating the list.
    var lineBreaks = 0;
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit == 10 ||
          (unit == 13 &&
              (i + 1 == text.length || text.codeUnitAt(i + 1) != 10))) {
        if (++lineBreaks >= 50000) _limit();
      }
    }
    final lines = const LineSplitter().convert(text);
    var cursor = 0;
    final vtt = format == SubtitleFormat.webvtt;
    if (vtt) {
      if (lines.isEmpty ||
          !RegExp(r'^WEBVTT(?:[ \t].*)?$').hasMatch(lines.first) ||
          lines.first.contains('-->')) {
        _malformed();
      }
      cursor = 1;
      if (cursor < lines.length && lines[cursor].isNotEmpty) {
        if (lines[cursor].contains('-->')) _malformed();
        // Includes HLS timestamp mapping; ignoring it would shift cue times.
        _unsupported();
      }
    }

    final cues = <SubtitleCue>[];
    while (cursor < lines.length) {
      if (lines[cursor].isEmpty) {
        cursor++;
        continue;
      }
      final first = cursor;
      while (cursor < lines.length && lines[cursor].isNotEmpty) {
        cursor++;
      }
      final head = lines[first];
      if (vtt &&
          (head == 'NOTE' ||
              head.startsWith('NOTE ') ||
              head.startsWith('NOTE\t'))) {
        for (var i = first; i < cursor; i++) {
          if (lines[i].contains('-->')) _malformed();
        }
        continue;
      }
      if (vtt && (head == 'STYLE' || head == 'REGION')) _unsupported();
      if (cues.length >= limits.maxCues) _limit();
      var timingLine = first;
      String? identifier;
      if (!head.contains('-->')) {
        if (!vtt && !RegExp(r'^[0-9]+$').hasMatch(head)) _malformed();
        if (head.length > 1024) _limit();
        identifier = head;
        timingLine++;
      }
      if (timingLine >= cursor || lines[timingLine].length > 1024) {
        if (timingLine < cursor) _limit();
        _malformed();
      }
      final timing = RegExp(
        r'^(\S+)[ \t]+-->[ \t]+(\S+)(?:[ \t]+(.*))?$',
      ).firstMatch(lines[timingLine]);
      if (timing == null) _malformed();
      final start = _timestamp(timing.group(1)!, vtt: vtt);
      final end = _timestamp(timing.group(2)!, vtt: vtt);
      if (end <= start || (vtt && cues.isNotEmpty && start < cues.last.start)) {
        _malformed();
      }
      final settings = timing.group(3)?.trim() ?? '';
      double? position;
      var positionAlignment = 'auto';
      var alignment = 'center';
      if (settings.isNotEmpty) {
        if (!vtt) _malformed();
        final seen = <String>{};
        for (final token in settings.split(RegExp(r'[ \t]+'))) {
          final colon = token.indexOf(':');
          if (colon < 1 || colon == token.length - 1) _malformed();
          final key = token.substring(0, colon);
          final value = token.substring(colon + 1);
          if (!seen.add(key)) _malformed();
          switch (key) {
            case 'align':
              if (!const [
                'start',
                'center',
                'end',
                'left',
                'right',
              ].contains(value)) {
                _malformed();
              }
              alignment = value;
            case 'position':
              final match = RegExp(
                r'^([0-9]+(?:\.[0-9]+)?)%(?:,(line-left|center|line-right))?$',
              ).firstMatch(value);
              if (match == null) _malformed();
              position = double.tryParse(match.group(1)!);
              if (position == null || !position.isFinite || position > 100) {
                _malformed();
              }
              positionAlignment = match.group(2) ?? 'auto';
            default:
              _unsupported();
          }
        }
      }
      if (timingLine + 1 >= cursor) _malformed();
      var payloadLength = 0;
      for (var i = timingLine + 1; i < cursor; i++) {
        if (lines[i].contains('-->')) _malformed();
        payloadLength += lines[i].length + (i == timingLine + 1 ? 0 : 1);
        if (payloadLength > limits.maxCueCodeUnits) _limit();
      }
      cues.add(
        SubtitleCue._(
          ordinal: cues.length,
          identifier: identifier,
          start: start,
          end: end,
          payload: lines.sublist(timingLine + 1, cursor).join('\n'),
          positionPercent: position,
          positionAlignment: positionAlignment,
          alignment: alignment,
        ),
      );
    }
    return _finish(cues, bytes.length, limits);
  }

  static SubtitleDocument _finish(
    List<SubtitleCue> cues,
    int inputBytes,
    SubtitleLimits limits,
  ) {
    // End events sort before start events: intervals are [start, end).
    final events =
        <(int, int)>[
          for (final cue in cues) ...[
            (cue.start.inMicroseconds, 1),
            (cue.end.inMicroseconds, -1),
          ],
        ]..sort(
          (a, b) => a.$1 == b.$1 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1),
        );
    var active = 0;
    for (final event in events) {
      active += event.$2;
      if (active > limits.maxActiveCues) _limit();
    }
    return SubtitleDocument._(cues, inputBytes);
  }

  /// Pure media-time query: positive offset delays display. No wall clock,
  /// retained active list or previous seek position participates in selection.
  List<SubtitleCue> cuesAt(
    Duration position, {
    Duration offset = Duration.zero,
    bool enabled = true,
  }) {
    if (!enabled || position.isNegative) return const [];
    // Bound operands before subtraction to avoid native integer overflow.
    const bound = 7 * 24 * 60 * 60 * 1000000;
    if (offset.inMicroseconds < -bound || offset.inMicroseconds > bound) {
      throw ArgumentError('Subtitle offset exceeds seven days');
    }
    if (position.inMicroseconds > 2 * bound) return const [];
    final time = position.inMicroseconds - offset.inMicroseconds;
    if (time < 0) return const [];
    final active = <SubtitleCue>[];
    _index?.collect(time, active);
    active.sort((a, b) => a.ordinal.compareTo(b.ordinal));
    return List.unmodifiable(active);
  }

  @override
  String toString() =>
      'SubtitleDocument(cues: ${cues.length}, inputBytes: $inputBytes)';
}

Duration _timestamp(String value, {required bool vtt}) {
  final pattern = vtt
      ? RegExp(r'^(?:([0-9]{2,}):)?([0-9]{2}):([0-9]{2})\.([0-9]{3})$')
      : RegExp(r'^([0-9]{2,}):([0-9]{2}):([0-9]{2}),([0-9]{3})$');
  final match = pattern.firstMatch(value);
  if (match == null) _malformed();
  final hourText = match.group(1) ?? '00';
  // Check length before parsing or multiplying attacker-provided integers.
  if (hourText.length > 3) _limit();
  final hours = int.parse(hourText);
  final minutes = int.parse(match.group(2)!);
  final seconds = int.parse(match.group(3)!);
  final millis = int.parse(match.group(4)!);
  if (minutes > 59 || seconds > 59) _malformed();
  final result = Duration(
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    milliseconds: millis,
  );
  if (result > const Duration(days: 7)) _limit();
  return result;
}

/// Balanced interval index, with subtree end bounds to prune expired cues.
final class _CueNode {
  _CueNode(this.cue, this.left, this.right)
    : maxEnd = math.max(
        cue.end.inMicroseconds,
        math.max(left?.maxEnd ?? 0, right?.maxEnd ?? 0),
      );
  final SubtitleCue cue;
  final _CueNode? left;
  final _CueNode? right;
  final int maxEnd;

  static _CueNode? build(List<SubtitleCue> cues, int start, int end) {
    if (start == end) return null;
    final middle = (start + end) ~/ 2;
    return _CueNode(
      cues[middle],
      build(cues, start, middle),
      build(cues, middle + 1, end),
    );
  }

  void collect(int time, List<SubtitleCue> output) {
    if (maxEnd <= time) return;
    left?.collect(time, output);
    if (cue.start.inMicroseconds > time) return;
    if (cue.end.inMicroseconds > time) output.add(cue);
    right?.collect(time, output);
  }
}

Never _malformed() =>
    throw const SubtitleParseException(SubtitleParseReason.malformed);
Never _limit() =>
    throw const SubtitleParseException(SubtitleParseReason.limitExceeded);
Never _unsupported() =>
    throw const SubtitleParseException(SubtitleParseReason.unsupported);
