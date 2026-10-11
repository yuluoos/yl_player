part of 'subtitle_document.dart';

/// Script-space styles. No native handles, external resources or font cache.
final class AssTextStyle {
  const AssTextStyle({
    required this.font,
    required this.size,
    required this.color,
    required this.outlineColor,
    required this.shadowColor,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikeout = false,
    this.outline = 0,
    this.shadow = 0,
  });
  final String font;
  final double size, outline, shadow;
  final int color, outlineColor, shadowColor;
  final bool bold, italic, underline, strikeout;
  AssTextStyle copyWith({
    String? font,
    double? size,
    int? color,
    int? outlineColor,
    int? shadowColor,
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strikeout,
    double? outline,
    double? shadow,
  }) => AssTextStyle(
    font: font ?? this.font,
    size: size ?? this.size,
    color: color ?? this.color,
    outlineColor: outlineColor ?? this.outlineColor,
    shadowColor: shadowColor ?? this.shadowColor,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    strikeout: strikeout ?? this.strikeout,
    outline: outline ?? this.outline,
    shadow: shadow ?? this.shadow,
  );
}

final class AssTextRun {
  const AssTextRun(this.text, this.style);
  final String text;
  final AssTextStyle style;
}

final class AssMotion {
  const AssMotion(this.x1, this.y1, this.x2, this.y2, this.startMs, this.endMs);
  final double x1, y1, x2, y2, startMs, endMs;
  (double, double) at(double ms) {
    final t = endMs == startMs
        ? (ms < startMs ? 0.0 : 1.0)
        : ((ms - startMs) / (endMs - startMs)).clamp(0.0, 1.0);
    return (x1 + (x2 - x1) * t, y1 + (y2 - y1) * t);
  }
}

final class AssCueLayout {
  AssCueLayout({
    required this.width,
    required this.height,
    required this.layer,
    required this.alignment,
    required this.left,
    required this.right,
    required this.vertical,
    required this.wrap,
    required List<AssTextRun> runs,
    this.motion,
    this.fadeInMs = 0,
    this.fadeOutMs = 0,
  }) : runs = List.unmodifiable(runs);
  final double width, height, left, right, vertical, fadeInMs, fadeOutMs;
  final int layer, alignment, wrap;
  final AssMotion? motion;
  final List<AssTextRun> runs;
  double opacity(double ms, double durationMs) => math.min(
    fadeInMs == 0 ? 1.0 : (ms / fadeInMs).clamp(0.0, 1.0),
    fadeOutMs == 0 ? 1.0 : ((durationMs - ms) / fadeOutMs).clamp(0.0, 1.0),
  );
}

final class _AssStyle {
  const _AssStyle(
    this.text,
    this.alignment,
    this.left,
    this.right,
    this.vertical,
  );
  final AssTextStyle text;
  final int alignment;
  final double left, right, vertical;
}

const _assStyleFields =
    'name,fontname,fontsize,primarycolour,secondarycolour,outlinecolour,backcolour,bold,italic,underline,strikeout,scalex,scaley,spacing,angle,borderstyle,outline,shadow,alignment,marginl,marginr,marginv,encoding';
const _ssaStyleFields =
    'name,fontname,fontsize,primarycolour,secondarycolour,tertiarycolour,backcolour,bold,italic,borderstyle,outline,shadow,alignment,marginl,marginr,marginv,alphalevel,encoding';

SubtitleDocument _parseAss(
  String input,
  int bytes,
  SubtitleLimits limits,
  bool ssa,
) => _AssParser(limits, ssa).parse(input, bytes);

final class _AssParser {
  _AssParser(this.limits, this.ssa);
  final SubtitleLimits limits;
  final bool ssa;
  final styles = <String, _AssStyle>{};
  final fonts = <String>{};
  final info = <String, String>{};
  final cues = <SubtitleCue>[];
  var width = 0.0, height = 0.0;
  var wrap = 0;
  bool sealed = false;
  var allocatedRuns = 0;
  String font(String raw) {
    if (raw.isEmpty) _malformed();
    if (raw.length > 128) _limit();
    if (raw.startsWith('@')) _unsupported();
    fonts.add(raw);
    if (fonts.length > 128) _limit();
    return raw;
  }

  void seal() {
    if (sealed) return;
    if (info['scripttype'] != (ssa ? 'v4.00' : 'v4.00+')) _malformed();
    width = _assNumber(info['playresx'] ?? '', min: 1);
    height = _assNumber(info['playresy'] ?? '', min: 1);
    wrap = _assInteger(info['wrapstyle'] ?? '0', max: 3);
    if (wrap != 1 && wrap != 2) _unsupported();
    if ((info['scaledborderandshadow'] ?? 'yes').toLowerCase() != 'yes' ||
        (info['collisions'] ?? 'normal').toLowerCase() != 'normal' ||
        (info['ycbcr matrix'] ?? 'none').toLowerCase() != 'none' ||
        _assNumber(info['timer'] ?? '100') != 100) {
      _unsupported();
    }
    sealed = true;
  }

  SubtitleDocument parse(String input, int bytes, {bool headerOnly = false}) {
    // Bound line objects before splitting; CRLF is one line ending.
    var breaks = 0;
    for (var i = 0; i < input.length; i++) {
      final unit = input.codeUnitAt(i);
      if (unit == 10 ||
          (unit == 13 &&
              (i + 1 == input.length || input.codeUnitAt(i + 1) != 10))) {
        if (++breaks >= 50000) _limit();
      }
    }
    String section = '';
    List<String>? styleFormat, eventFormat;
    final sections = <String>{};
    for (final raw in const LineSplitter().convert(input)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith(';')) continue;
      if (line.startsWith('[')) {
        if (!line.endsWith(']')) _malformed();
        section = line.toLowerCase();
        if (!sections.add(section)) _malformed();
        if (![
          '[script info]',
          ssa ? '[v4 styles]' : '[v4+ styles]',
          '[events]',
          '[aegisub project garbage]',
        ].contains(section)) {
          _unsupported();
        }
        if (section != '[script info]') seal();
        continue;
      }
      final colon = line.indexOf(':');
      if (colon < 1) _malformed();
      final key = line.substring(0, colon).toLowerCase();
      final value = line.substring(colon + 1).trimLeft();
      if (key != 'dialogue' && raw.length > 4096) _limit();
      switch (section) {
        case '[script info]':
          if (sealed || info.containsKey(key)) _malformed();
          if (![
            'scripttype',
            'playresx',
            'playresy',
            'wrapstyle',
            'scaledborderandshadow',
            'collisions',
            'ycbcr matrix',
            'timer',
            'title',
            'original script',
            'original translation',
            'original editing',
            'original timing',
            'synch point',
            'script updated by',
            'update details',
            'script comments',
          ].contains(key)) {
            _unsupported();
          }
          info[key] = value;
        case '[v4 styles]':
        case '[v4+ styles]':
          if (key == 'format') {
            if (styleFormat != null) _malformed();
            styleFormat = _assFormat(
              value,
              ssa ? _ssaStyleFields : _assStyleFields,
            );
          } else if (key == 'style' && styleFormat != null) {
            if (styles.length >= 128) _limit();
            final row = _assRow(styleFormat, value);
            final name = row['name']!;
            if (name.isEmpty || styles.containsKey(name)) _malformed();
            if (name.length > 128) _limit();
            styles[name] = style(row);
          } else {
            _malformed();
          }
        case '[events]':
          if (key == 'format') {
            if (eventFormat != null) _malformed();
            eventFormat = _assFormat(
              value,
              '${ssa ? 'marked' : 'layer'},start,end,style,name,marginl,marginr,marginv,effect,text',
            );
            if (eventFormat.last != 'text') _unsupported();
          } else if (key == 'dialogue' && eventFormat != null) {
            if (headerOnly) _unsupported();
            if (cues.length >= limits.maxCues) _limit();
            if (value.length > limits.maxCueCodeUnits + 4096) _limit();
            dialogue(_assRow(eventFormat, value, text: true));
          } else if (key != 'comment') {
            _unsupported();
          }
        case '[aegisub project garbage]':
          break;
        default:
          _malformed();
      }
    }
    seal();
    if ((!headerOnly && eventFormat == null) ||
        styleFormat == null ||
        styles.isEmpty) {
      _malformed();
    }
    return SubtitleDocument._finish(cues, bytes, limits);
  }

  _AssStyle style(Map<String, String> r) {
    if (_assInteger(r['borderstyle']!) != 1) _unsupported();
    if (!ssa &&
        (_assNumber(r['scalex']!) != 100 ||
            _assNumber(r['scaley']!) != 100 ||
            _assNumber(r['spacing']!) != 0 ||
            _assNumber(r['angle']!, min: -8192) != 0)) {
      _unsupported();
    }
    if (![0, 1].contains(_assInteger(r['encoding']!))) _unsupported();
    // SSA uses BackColour for outline; AlphaLevel applies to foreground and
    // outline, with legacy half-transparent shadow (libass/VSFilter behavior).
    final alpha = ssa ? _assInteger(r['alphalevel']!, max: 255) : null;
    int color(String key, [int? override]) {
      final value = _assColor(r[key]!);
      return override == null
          ? value
          : ((255 - override) << 24) | (value & 0xffffff);
    }

    color('secondarycolour');
    if (ssa) color('tertiarycolour');
    final size = _assNumber(r['fontsize']!, max: 256);
    if (size == 0) _malformed();
    return _AssStyle(
      AssTextStyle(
        font: font(r['fontname']!),
        size: size,
        color: color('primarycolour', alpha),
        outlineColor: color(ssa ? 'backcolour' : 'outlinecolour', alpha),
        shadowColor: color('backcolour', ssa ? 128 : null),
        bold: _assBool(r['bold']!),
        italic: _assBool(r['italic']!),
        underline: !ssa && _assBool(r['underline']!),
        strikeout: !ssa && _assBool(r['strikeout']!),
        outline: _assNumber(r['outline']!, max: 16),
        shadow: _assNumber(r['shadow']!, max: 16),
      ),
      _assAlignment(r['alignment']!, legacy: ssa),
      _assNumber(r['marginl']!),
      _assNumber(r['marginr']!),
      _assNumber(r['marginv']!),
    );
  }

  void dialogue(
    Map<String, String> r, {
    Duration? startOverride,
    Duration? endOverride,
  }) {
    if (r['effect']!.isNotEmpty) _unsupported();
    if (ssa &&
        !RegExp(
          r'^Marked=[01]$',
          caseSensitive: false,
        ).hasMatch(r['marked']!)) {
      _malformed();
    }
    final layer = ssa ? 0 : _assInteger(r['layer']!, max: 65535);
    final start = startOverride ?? _assTime(r['start']!),
        end = endOverride ?? _assTime(r['end']!);
    if (end <= start) _malformed();
    final base = styles[r['style']!];
    if (base == null) _malformed();
    double margin(String key, double fallback) {
      final n = _assNumber(r[key]!);
      return n == 0 ? fallback : n;
    }

    final left = margin('marginl', base.left),
        right = margin('marginr', base.right),
        vertical = margin('marginv', base.vertical);
    if (left + right >= width || vertical >= height) _malformed();
    final payload = r['text']!;
    if (payload.length > limits.maxCueCodeUnits) _limit();
    var defaults = base.text;
    var current = defaults, alignment = base.alignment, wrapping = wrap;
    AssMotion? motion;
    var fadeIn = 0.0, fadeOut = 0.0, faded = false;
    var buffer = StringBuffer();
    final runs = <AssTextRun>[];
    void flush() {
      if (buffer.isEmpty) return;
      if (runs.length >= 512 || allocatedRuns >= limits.maxAssRuns) _limit();
      allocatedRuns++;
      runs.add(AssTextRun(buffer.toString(), current));
      buffer = StringBuffer();
    }

    for (var i = 0; i < payload.length;) {
      final c = payload[i++];
      if (c == '{') {
        flush();
        final close = payload.indexOf('}', i);
        if (close < 0) _malformed();
        final block = payload.substring(i, close);
        if (block.contains('{')) _malformed();
        i = close + 1;
        if (!block.contains(r'\')) continue;
        if (!block.startsWith(r'\')) _unsupported();
        for (final tag in block.substring(1).split(r'\')) {
          if (tag.isEmpty) _malformed();
          final complex = RegExp(
            r'^(pos|move|fad)\(([^()]*)\)$',
          ).firstMatch(tag);
          if (complex != null) {
            final args = complex[2]!.split(',').map((e) => e.trim()).toList();
            switch (complex[1]) {
              case 'pos':
              case 'move':
                if (motion != null) _unsupported();
                final pos = complex[1] == 'pos';
                if (pos ? args.length != 2 : ![4, 6].contains(args.length)) {
                  _malformed();
                }
                final coords = args
                    .take(pos ? 2 : 4)
                    .map((v) => _assNumber(v, min: -8192))
                    .toList();
                final t1 = args.length == 6
                    ? _assNumber(args[4], max: 604800000)
                    : 0.0;
                var t2 = args.length == 6
                    ? _assNumber(args[5], max: 604800000)
                    : (end - start).inMilliseconds.toDouble();
                if (!pos && t1 == 0 && t2 == 0) {
                  t2 = (end - start).inMilliseconds.toDouble();
                }
                if (t2 < t1) _malformed();
                motion = AssMotion(
                  coords[0],
                  coords[1],
                  pos ? coords[0] : coords[2],
                  pos ? coords[1] : coords[3],
                  t1,
                  t2,
                );
              case 'fad':
                if (faded) _unsupported();
                if (args.length != 2) _malformed();
                fadeIn = _assNumber(args[0], max: 604800000);
                fadeOut = _assNumber(args[1], max: 604800000);
                if (fadeIn + fadeOut > (end - start).inMilliseconds) {
                  _unsupported();
                }
                faded = true;
            }
            continue;
          }
          final match = RegExp(
            r'^(fn|r|(?:alpha|bord|shad|[134]a|[134]c|an|fs|[biuscaq])(?=[^A-Za-z]|$))(.*)$',
          ).firstMatch(tag);
          if (match == null) _unsupported();
          final name = match[1]!, value = match[2]!.trim();
          switch (name) {
            case 'b':
              current = current.copyWith(
                bold: value.isEmpty ? defaults.bold : _assBool(value),
              );
            case 'i':
              current = current.copyWith(
                italic: value.isEmpty ? defaults.italic : _assBool(value),
              );
            case 'u':
              current = current.copyWith(
                underline: value.isEmpty ? defaults.underline : _assBool(value),
              );
            case 's':
              current = current.copyWith(
                strikeout: value.isEmpty ? defaults.strikeout : _assBool(value),
              );
            case 'fn':
              current = current.copyWith(
                font: value.isEmpty ? defaults.font : font(value),
              );
            case 'fs':
              final size = value.isEmpty
                  ? defaults.size
                  : _assNumber(value, max: 256);
              if (size == 0) _malformed();
              current = current.copyWith(size: size);
            case 'bord':
              current = current.copyWith(
                outline: value.isEmpty
                    ? defaults.outline
                    : _assNumber(value, max: 16),
              );
            case 'shad':
              current = current.copyWith(
                shadow: value.isEmpty
                    ? defaults.shadow
                    : _assNumber(value, max: 16),
              );
            case 'c':
            case '1c':
            case '3c':
            case '4c':
              final old = name == '3c'
                  ? current.outlineColor
                  : name == '4c'
                  ? current.shadowColor
                  : current.color;
              final original = name == '3c'
                  ? defaults.outlineColor
                  : name == '4c'
                  ? defaults.shadowColor
                  : defaults.color;
              final rgb = value.isEmpty
                  ? original & 0xffffff
                  : _assHex(value, 6);
              final color =
                  (old & 0xff000000) |
                  ((rgb & 255) << 16) |
                  (rgb & 0xff00) |
                  ((rgb >> 16) & 255);
              // Defaults are already ARGB; ASS overrides are BGR.
              final result = value.isEmpty
                  ? (old & 0xff000000) | (original & 0xffffff)
                  : color;
              current = name == '3c'
                  ? current.copyWith(outlineColor: result)
                  : name == '4c'
                  ? current.copyWith(shadowColor: result)
                  : current.copyWith(color: result);
            case 'alpha':
            case '1a':
            case '3a':
            case '4a':
              int apply(int old, int original) =>
                  (old & 0xffffff) |
                  (value.isEmpty
                      ? original & 0xff000000
                      : (255 - _assHex(value, 2)) << 24);
              current = current.copyWith(
                color: name == 'alpha' || name == '1a'
                    ? apply(current.color, defaults.color)
                    : null,
                outlineColor: name == 'alpha' || name == '3a'
                    ? apply(current.outlineColor, defaults.outlineColor)
                    : null,
                shadowColor: name == 'alpha' || name == '4a'
                    ? apply(current.shadowColor, defaults.shadowColor)
                    : null,
              );
            case 'an':
            case 'a':
              alignment = _assAlignment(value, legacy: name == 'a');
            case 'q':
              wrapping = _assInteger(value, max: 3);
              if (wrapping != 1 && wrapping != 2) _unsupported();
            case 'r':
              final replacement = value.isEmpty ? base : styles[value];
              if (replacement == null) _malformed();
              defaults = replacement.text;
              current = defaults;
          }
        }
      } else if (c == '}') {
        _malformed();
      } else if (c == r'\' && i < payload.length) {
        final escape = payload[i++];
        buffer.write(switch (escape) {
          'N' => '\n',
          'n' => wrapping == 2 ? '\n' : ' ',
          'h' => '\u00a0',
          _ => '\\$escape',
        });
      } else {
        buffer.write(c);
      }
    }
    flush();
    if (runs.isEmpty) _malformed();
    if (runs.any((r) => r.style.shadow != runs.first.style.shadow)) {
      _unsupported();
    }
    cues.add(
      SubtitleCue._(
        ordinal: cues.length,
        identifier: null,
        start: start,
        end: end,
        payload: payload,
        ass: AssCueLayout(
          width: width,
          height: height,
          layer: layer,
          alignment: alignment,
          left: left,
          right: right,
          vertical: vertical,
          wrap: wrapping,
          runs: runs,
          motion: motion,
          fadeInMs: fadeIn,
          fadeOutMs: fadeOut,
        ),
      ),
    );
  }
}

List<String> _assFormat(String value, String expected) {
  final fields = value.toLowerCase().split(',').map((v) => v.trim()).toList();
  final wanted = expected.split(',').toSet();
  if (fields.toSet().length != fields.length) _malformed();
  if (fields.length != wanted.length || !wanted.containsAll(fields)) {
    _unsupported();
  }
  return fields;
}

Map<String, String> _assRow(
  List<String> fields,
  String value, {
  bool text = false,
}) {
  final result = <String, String>{};
  var cursor = 0;
  for (var i = 0; i < fields.length; i++) {
    final last = i == fields.length - 1;
    final end = last ? value.length : value.indexOf(',', cursor);
    if (end < 0) _malformed();
    final raw = value.substring(cursor, end);
    if (last && !text && raw.contains(',')) _malformed();
    result[fields[i]] = last && text ? raw : raw.trim();
    cursor = end + 1;
  }
  return result;
}

double _assNumber(String value, {double min = 0, double max = 8192}) {
  if (!RegExp(r'^-?\d+(?:\.\d+)?$').hasMatch(value)) _malformed();
  final n = double.tryParse(value);
  if (n == null || !n.isFinite || n > max || n < min) _limit();
  return n;
}

int _assInteger(String value, {int max = 8192}) {
  if (!RegExp(r'^\d+$').hasMatch(value)) _malformed();
  return _assNumber(value, max: max.toDouble()).toInt();
}

bool _assBool(String value) {
  if (!['-1', '0', '1'].contains(value)) _unsupported();
  return value != '0';
}

int _assAlignment(String value, {required bool legacy}) {
  final n = _assInteger(value, max: 11);
  if (legacy) {
    const conversion = {1: 1, 2: 2, 3: 3, 5: 7, 6: 8, 7: 9, 9: 4, 10: 5, 11: 6};
    return conversion[n] ?? _unsupported();
  }
  if (n < 1 || n > 9) _malformed();
  return n;
}

int _assHex(String value, int digits) {
  final m = RegExp('^&[Hh]([0-9a-fA-F]{1,$digits})&?\$').firstMatch(value);
  if (m == null) _malformed();
  return int.parse(m[1]!, radix: 16);
}

int _assColor(String value) {
  final int n;
  if (value.startsWith('&')) {
    n = _assHex(value, 8);
  } else {
    if (!RegExp(r'^-?\d+$').hasMatch(value)) _malformed();
    final parsed = int.tryParse(value);
    if (parsed == null || parsed < -2147483648 || parsed > 0xffffffff) _limit();
    n = parsed & 0xffffffff;
  }
  return ((255 - (n >> 24)) << 24) |
      ((n & 255) << 16) |
      (n & 0xff00) |
      ((n >> 16) & 255);
}

Duration _assTime(String value) {
  final m = RegExp(
    r'^(\d{1,3}):([0-5]\d):([0-5]\d)\.(\d{2})$',
  ).firstMatch(value);
  if (m == null) _malformed();
  final ms =
      ((int.parse(m[1]!) * 60 + int.parse(m[2]!)) * 60 + int.parse(m[3]!)) *
          1000 +
      int.parse(m[4]!) * 10;
  if (ms > 604800000) _limit();
  return Duration(milliseconds: ms);
}
