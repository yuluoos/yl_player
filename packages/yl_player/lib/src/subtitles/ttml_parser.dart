part of 'subtitle_document.dart';

/// Plain decoded text; never parsed a second time as HTML/SRT control markup.
final class SubtitleTextRun {
  const SubtitleTextRun(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.color = 0xffffffff,
  });
  final String text;
  final bool bold, italic, underline;
  final int color;
}

final class SubtitleRegion {
  const SubtitleRegion({
    required this.id,
    this.x = 0,
    this.y = 0,
    this.width = 1,
    this.height = 1,
    this.displayAlign = 'before',
  });
  final String id;
  final double x, y, width, height;
  final String displayAlign;
}

const _tt = 'http://www.w3.org/ns/ttml';
const _tts = '$_tt#styling';
const _ttp = '$_tt#parameter';
const _xml = 'http://www.w3.org/XML/1998/namespace';
const _xmlns = 'http://www.w3.org/2000/xmlns/';
const _timeBound = 7 * 24 * 60 * 60 * 1000000;

bool _xmlChar(int c) =>
    c == 9 ||
    c == 10 ||
    c == 13 ||
    (c >= 0x20 && c <= 0xd7ff) ||
    (c >= 0xe000 && c <= 0xfffd) ||
    (c >= 0x10000 && c <= 0x10ffff);

class _StrictEntities extends XmlDefaultEntityMapping {
  const _StrictEntities() : super.xml();
  @override
  String decode(String input) {
    final buffer = StringBuffer();
    var cursor = 0;
    while (cursor < input.length) {
      final amp = input.indexOf('&', cursor);
      if (amp < 0) {
        buffer.write(input.substring(cursor));
        break;
      }
      buffer.write(input.substring(cursor, amp));
      final end = input.indexOf(';', amp + 1);
      if (end < 0 || end - amp > 16) _malformed();
      final entity = input.substring(amp + 1, end);
      if (!RegExp(
        r'^(amp|lt|gt|quot|apos|#[0-9]+|#x[0-9a-fA-F]+)$',
      ).hasMatch(entity)) {
        _malformed();
      }
      final value = super.decodeEntity(entity);
      if (value == null || !value.runes.every(_xmlChar)) _malformed();
      buffer.write(value);
      cursor = end + 1;
    }
    return buffer.toString();
  }
}

final class _TNode {
  _TNode(this.name, this.attributes);
  final String name;
  final Map<String, String> attributes;
  final List<Object> children = []; // _TNode or decoded String
  Iterable<_TNode> get elements => children.whereType<_TNode>();
  String? operator [](String key) => attributes[key];
}

// The event library intentionally admits HTML-like attributes. Check only the
// omitted XML lexical constraints here; its parser still owns XML tokenization.
void _quotedAttributes(
  String raw,
  String opening,
  String closing,
  List<XmlEventAttribute> attributes,
) {
  if (!raw.startsWith(opening)) _malformed();
  var offset = opening.length;
  final attribute = RegExp(
    r'''[ \t\n\r]+([^ \t\n\r=/>]+)[ \t\n\r]*=[ \t\n\r]*(?:"[^"<]*"|'[^'<]*')''',
  );
  final names = <String>{};
  for (final expected in attributes) {
    final match = attribute.matchAsPrefix(raw, offset);
    if (match == null ||
        match[1] != expected.name ||
        !names.add(expected.name)) {
      _malformed();
    }
    offset = match.end;
  }
  if (raw.substring(offset).trim() != closing) _malformed();
}

_TNode _readTtmlXml(String input) {
  if (!input.runes.every(_xmlChar)) _malformed();
  input = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final stack = <_TNode>[];
  _TNode? root;
  var events = 0;
  try {
    for (final event in parseEvents(
      input,
      entityMapping: const _StrictEntities(),
      validateNesting: true,
      validateNamespace: true,
      validateDocument: true,
      withNamespace: true,
      withLocation: true,
    )) {
      if (++events > 50000) _limit();
      final raw = input.substring(event.start!, event.stop!);
      if (event is XmlStartElementEvent) {
        if (stack.length >= 32 || event.attributes.length > 32) _limit();
        _quotedAttributes(
          raw,
          '<${event.name}',
          event.isSelfClosing ? '/>' : '>',
          event.attributes,
        );
        if (event.namespaceUri != _tt) _unsupported();
        final attrs = <String, String>{};
        for (final attr in event.attributes) {
          if (attr.value.length > 4096) _limit();
          if (attr.namespaceUri == _xmlns || attr.name == 'xmlns') {
            if (attr.name == 'xmlns:xml') {
              if (attr.value != _xml) _malformed();
            } else if (attr.name == 'xmlns:xmlns' ||
                attr.value == _xml ||
                attr.value == _xmlns ||
                (attr.namespacePrefix != null && attr.value.isEmpty)) {
              _malformed();
            }
            continue;
          }
          // XML default namespaces apply to elements, never unprefixed attributes.
          final prefix = attr.namespacePrefix == null
              ? ''
              : switch (attr.namespaceUri) {
                  null || '' => '',
                  _xml => 'xml:',
                  _tts => 'tts:',
                  _ttp => 'ttp:',
                  _ => _unsupported(),
                };
          final key = '$prefix${attr.localName}';
          if (attrs.containsKey(key)) _malformed();
          attrs[key] = attr.value;
        }
        final node = _TNode(event.localName, attrs);
        if (stack.isEmpty) {
          if (root != null) _malformed();
          root = node;
        } else {
          stack.last.children.add(node);
        }
        if (!event.isSelfClosing) stack.add(node);
      } else if (event is XmlEndElementEvent) {
        stack.removeLast();
      } else if (event is XmlTextEvent || event is XmlCDATAEvent) {
        final text = event is XmlTextEvent
            ? event.value
            : (event as XmlCDATAEvent).value;
        if (!text.runes.every(_xmlChar)) _malformed();
        if (event is XmlTextEvent && raw.contains(']]>')) _malformed();
        if (stack.isEmpty) {
          if (event is XmlCDATAEvent ||
              !RegExp(r'^[ \t\r\n]*$').hasMatch(raw)) {
            _malformed();
          }
        } else {
          stack.last.children.add(text);
        }
      } else if (event is XmlDeclarationEvent) {
        if (event.start != 0 ||
            stack.isNotEmpty ||
            root != null ||
            raw.contains('&')) {
          _malformed();
        }
        _quotedAttributes(raw, '<?xml', '?>', event.attributes);
        if (!RegExp(
          r'^version(?:,encoding)?(?:,standalone)?$',
        ).hasMatch(event.attributes.map((a) => a.name).join(','))) {
          _malformed();
        }
        for (final attr in event.attributes) {
          if (attr.name == 'version' && attr.value != '1.0') _unsupported();
          if (attr.name == 'standalone' &&
              !{'yes', 'no'}.contains(attr.value)) {
            _malformed();
          }
          if (attr.name == 'encoding' && attr.value.toLowerCase() != 'utf-8') {
            _unsupported();
          }
        }
      } else if (event is XmlCommentEvent) {
        if (event.value.contains('--') || event.value.endsWith('-')) {
          _malformed();
        }
      } else {
        _unsupported(); // DTD, external entities and processing instructions.
      }
    }
  } on XmlException {
    _malformed();
  }
  if (root == null || root.name != 'tt') _malformed();
  return root;
}

const _textProperties = {
  'fontWeight',
  'fontStyle',
  'textDecoration',
  'color',
  'textAlign',
};
const _regionProperties = {'origin', 'extent', 'displayAlign'};

SubtitleDocument _parseTtml(
  String input,
  int inputBytes,
  SubtitleLimits limits,
) {
  final root = _readTtmlXml(input);
  return _TtmlParser(limits).parse(root, inputBytes);
}

final class _TtmlParser {
  _TtmlParser(this.limits);
  final SubtitleLimits limits;
  final styles = <String, _TNode>{};
  final resolved = <String, Map<String, String>>{};
  final resolvedDepth = <String, int>{};
  final regions = <String, (SubtitleRegion, Map<String, String>)>{};
  final ids = <String>{};
  final cues = <SubtitleCue>[];
  var paragraphCount = 0;
  var totalRuns = 0;

  SubtitleDocument parse(_TNode root, int bytes) {
    _validate(root, null);
    for (final head in root.elements.where((n) => n.name == 'head')) {
      for (final group in head.elements) {
        for (final child in group.elements) {
          final id = child['xml:id'];
          if (id == null) _malformed();
          if (group.name == 'styling') {
            if (styles.length >= 128) _limit();
            styles[id] = child;
          }
        }
      }
    }
    for (final id in styles.keys) {
      _resolve(id, <String>{});
    }
    for (final head in root.elements.where((n) => n.name == 'head')) {
      for (final layout in head.elements.where((n) => n.name == 'layout')) {
        for (final node in layout.elements) {
          if (regions.length >= 128) _limit();
          final props = _specified(node);
          final origin = _pair(props['origin'], (0.0, 0.0));
          final extent = _pair(props['extent'], (1.0, 1.0));
          if (extent.$1 <= 0 ||
              extent.$2 <= 0 ||
              origin.$1 + extent.$1 > 1.000000001 ||
              origin.$2 + extent.$2 > 1.000000001) {
            _unsupported();
          }
          regions[node['xml:id']!] = (
            SubtitleRegion(
              id: node['xml:id']!,
              x: origin.$1,
              y: origin.$2,
              width: extent.$1,
              height: extent.$2,
              displayAlign: props['displayAlign'] ?? 'before',
            ),
            props,
          );
        }
      }
    }
    for (final body in root.elements.where((n) => n.name == 'body')) {
      _content(body, 0, null, const {}, null, root['xml:space'] ?? 'default');
    }
    return SubtitleDocument._finish(cues, bytes, limits);
  }

  void _validate(_TNode node, String? parent) {
    const children = <String?, Set<String>>{
      null: {'tt'},
      'tt': {'head', 'body'},
      'head': {'styling', 'layout'},
      'styling': {'style'},
      'layout': {'region'},
      'style': {},
      'region': {},
      'body': {'div'},
      'div': {'div', 'p'},
      'p': {'span', 'br'},
      'span': {'span', 'br'},
      'br': {},
    };
    if (!(children[parent]?.contains(node.name) ?? false)) _unsupported();
    if (node.name == 'tt' || node.name == 'head') {
      final seen = <String>{};
      for (final child in node.elements) {
        if (!seen.add(child.name)) _malformed();
      }
    }
    for (final entry in node.attributes.entries) {
      final key = entry.key, value = entry.value;
      if (key == 'xml:id') {
        if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_.-]*$').hasMatch(value)) {
          _unsupported();
        }
        if (!ids.add(value)) _malformed();
      } else if (key == 'xml:lang') {
        // Label metadata only; language never overrides writing direction.
      } else if (key == 'xml:space') {
        if (value != 'default' && value != 'preserve') _malformed();
      } else if (key == 'ttp:timeBase' && node.name == 'tt') {
        if (value != 'media') _unsupported();
      } else if (key == 'style' &&
          {
            'style',
            'region',
            'body',
            'div',
            'p',
            'span',
            'br',
          }.contains(node.name)) {
        _refs(value);
      } else if (key == 'region' && {'body', 'div', 'p'}.contains(node.name)) {
        if (value.trim().isEmpty || value.contains(RegExp(r'\s'))) _malformed();
      } else if ({'begin', 'end', 'dur', 'timeContainer'}.contains(key) &&
          {'body', 'div', 'p'}.contains(node.name)) {
        if (key == 'timeContainer' && value != 'par') _unsupported();
      } else if (key.startsWith('tts:') &&
          {
            'style',
            'region',
            'body',
            'div',
            'p',
            'span',
            'br',
          }.contains(node.name)) {
        final property = key.substring(4);
        if (!_textProperties.contains(property) &&
            !(_regionProperties.contains(property) &&
                {'style', 'region'}.contains(node.name))) {
          _unsupported();
        }
        _validateProperty(property, value);
      } else {
        _unsupported();
      }
    }
    for (final child in node.children) {
      if (child is _TNode) {
        _validate(child, node.name);
      } else if (!{'p', 'span'}.contains(node.name) &&
          (child as String).trim().isNotEmpty) {
        _malformed();
      }
    }
  }

  List<String> _refs(String? value) {
    if (value == null) return const [];
    if (value.trim().isEmpty) _malformed();
    final refs = value.trim().split(RegExp(r'\s+'));
    if (refs.length > 16) _limit();
    return refs;
  }

  Map<String, String> _resolve(String id, Set<String> path) {
    if (resolved.containsKey(id)) {
      if (path.length + resolvedDepth[id]! > 32) _limit();
      return resolved[id]!;
    }
    if (!path.add(id)) _malformed();
    if (path.length > 32) _limit();
    final node = styles[id];
    if (node == null) _malformed();
    final props = <String, String>{};
    var depth = 1;
    for (final ref in _refs(node['style'])) {
      props.addAll(_resolve(ref, path));
      depth = math.max(depth, resolvedDepth[ref]! + 1);
    }
    if (depth > 32) _limit();
    resolvedDepth[id] = depth;
    for (final entry in node.attributes.entries.where(
      (a) => a.key.startsWith('tts:'),
    )) {
      props[entry.key.substring(4)] = entry.value;
    }
    path.remove(id);
    return resolved[id] = Map.unmodifiable(props);
  }

  Map<String, String> _specified(_TNode node) {
    final result = <String, String>{};
    for (final ref in _refs(node['style'])) {
      result.addAll(_resolve(ref, <String>{}));
    }
    for (final entry in node.attributes.entries.where(
      (a) => a.key.startsWith('tts:'),
    )) {
      result[entry.key.substring(4)] = entry.value;
    }
    if (!{'style', 'region'}.contains(node.name) &&
        result.keys.any(_regionProperties.contains)) {
      _unsupported();
    }
    return result;
  }

  void _content(
    _TNode node,
    int parentStart,
    int? parentEnd,
    Map<String, String> inherited,
    String? regionId,
    String space,
  ) {
    final start = parentStart + _time(node['begin'] ?? '0s');
    if (start > _timeBound) _limit();
    var end = parentEnd;
    if (node['end'] != null) {
      final ownEnd = parentStart + _time(node['end']!);
      if (ownEnd < start) _malformed();
      if (ownEnd > _timeBound) _limit();
      end = end == null ? ownEnd : math.min(end, ownEnd);
    }
    if (node['dur'] != null) {
      final ownEnd = start + _time(node['dur']!);
      if (ownEnd > _timeBound) _limit();
      end = end == null ? ownEnd : math.min(end, ownEnd);
    }
    final props = {...inherited, ..._specified(node)};
    final region = node['region'] ?? regionId;
    if (region != null && !regions.containsKey(region)) _malformed();
    space = node['xml:space'] ?? space;
    if (node.name == 'p') {
      if (++paragraphCount > limits.maxCues) _limit();
      if (end == null) _unsupported();
      final regionPair = region == null
          ? (const SubtitleRegion(id: ''), <String, String>{})
          : regions[region]!;
      final effective = {...regionPair.$2, ...props};
      final writer = _TtmlText(limits.maxCueCodeUnits);
      _inline(node, effective, space, writer, applyStyle: false);
      final runs = writer.finish();
      totalRuns += runs.length;
      if (totalRuns > 20000) _limit();
      if (end <= start || runs.isEmpty) return;
      cues.add(
        SubtitleCue._(
          ordinal: cues.length,
          identifier: node['xml:id'],
          start: Duration(microseconds: start),
          end: Duration(microseconds: end),
          payload: runs.map((r) => r.text).join(),
          textRuns: List.unmodifiable(runs),
          region: regionPair.$1,
          alignment: effective['textAlign'] ?? 'start',
        ),
      );
    } else {
      for (final child in node.elements) {
        _content(child, start, end, props, region, space);
      }
    }
  }

  void _inline(
    _TNode node,
    Map<String, String> inherited,
    String space,
    _TtmlText writer, {
    bool applyStyle = true,
  }) {
    final props = applyStyle ? {...inherited, ..._specified(node)} : inherited;
    space = node['xml:space'] ?? space;
    if (node.name == 'span' && props['textAlign'] != inherited['textAlign']) {
      _unsupported();
    }
    for (final child in node.children) {
      if (child is String) {
        writer.add(child, props, space == 'preserve');
      } else if ((child as _TNode).name == 'br') {
        if (child.attributes.keys.any(
          (k) => k == 'style' || k.startsWith('tts:'),
        )) {
          _unsupported();
        }
        writer.lineBreak(props);
      } else {
        _inline(child, props, space, writer);
      }
    }
  }
}

int _time(String value) {
  if (value.length > 64) _limit();
  final clock = RegExp(
    r'^([0-9]{2,}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?$',
  ).firstMatch(value);
  String amount;
  int multiplier;
  var whole = 0;
  if (clock != null) {
    if (clock[1]!.length > 3) _limit();
    final h = int.parse(clock[1]!),
        m = int.parse(clock[2]!),
        s = int.parse(clock[3]!);
    if (m > 59 || s > 59) _malformed();
    whole = (h * 3600 + m * 60 + s) * 1000000;
    amount = '0.${clock[4] ?? '0'}';
    multiplier = 1000000;
  } else {
    final match = RegExp(
      r'^([0-9]+(?:\.[0-9]+)?)(h|m|s|ms)$',
    ).firstMatch(value);
    if (match == null) {
      if (value.endsWith('f') ||
          value.endsWith('t') ||
          value.split(':').length == 4) {
        _unsupported();
      }
      _malformed();
    }
    amount = match[1]!;
    multiplier = switch (match[2]) {
      'h' => 3600000000,
      'm' => 60000000,
      'ms' => 1000,
      _ => 1000000,
    };
  }
  final pieces = amount.split('.');
  if (pieces.first.length > 12) _limit();
  final fraction = pieces.length == 2 ? pieces[1] : '';
  if (fraction.length > 6) _unsupported();
  final integer = int.parse(pieces.first);
  if (integer > _timeBound ~/ multiplier) _limit();
  final result =
      whole +
      integer * multiplier +
      (fraction.isEmpty
          ? 0
          : int.parse(fraction) *
                multiplier ~/
                math.pow(10, fraction.length).toInt());
  if (result > _timeBound) _limit();
  return result;
}

(double, double) _pair(String? value, (double, double) fallback) {
  if (value == null) return fallback;
  final m = RegExp(
    r'^([0-9]+(?:\.[0-9]+)?)%\s+([0-9]+(?:\.[0-9]+)?)%$',
  ).firstMatch(value.trim());
  if (m == null) _unsupported();
  final x = double.parse(m[1]!), y = double.parse(m[2]!);
  if (!x.isFinite || !y.isFinite || x > 100 || y > 100) _malformed();
  return (x / 100, y / 100);
}

void _validateProperty(String name, String value) {
  final values = switch (name) {
    'fontWeight' => {'normal', 'bold'},
    'fontStyle' => {'normal', 'italic'},
    'textDecoration' => {'underline', 'noUnderline'},
    'textAlign' => {'start', 'end', 'left', 'right', 'center'},
    'displayAlign' => {'before', 'center', 'after'},
    _ => null,
  };
  if (values != null && !values.contains(value)) _unsupported();
  if (name == 'color') _color(value);
  if (name == 'origin' || name == 'extent') _pair(value, (0, 0));
}

int _color(String value) {
  const named = {
    'white': 0xffffffff,
    'black': 0xff000000,
    'red': 0xffff0000,
    'yellow': 0xffffff00,
    'lime': 0xff00ff00,
    'green': 0xff008000,
    'blue': 0xff0000ff,
    'cyan': 0xff00ffff,
    'aqua': 0xff00ffff,
    'magenta': 0xffff00ff,
    'fuchsia': 0xffff00ff,
    'silver': 0xffc0c0c0,
    'gray': 0xff808080,
    'maroon': 0xff800000,
    'olive': 0xff808000,
    'purple': 0xff800080,
    'teal': 0xff008080,
    'navy': 0xff000080,
    'transparent': 0,
  };
  if (named.containsKey(value)) return named[value]!;
  if (!RegExp(
    r'^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$',
  ).hasMatch(value)) {
    _unsupported();
  }
  var hex = value.substring(1);
  if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
  if (hex.length == 6) return 0xff000000 | int.parse(hex, radix: 16);
  return int.parse(hex.substring(6), radix: 16) << 24 |
      int.parse(hex.substring(0, 6), radix: 16);
}

final class _TtmlText {
  _TtmlText(this.limit);
  final int limit;
  final runs = <SubtitleTextRun>[];
  var length = 0;
  var lineStart = true;
  Map<String, String>? pendingSpace;
  void _append(String text, Map<String, String> props) {
    if (text.isEmpty) return;
    length += text.length;
    if (length > limit || runs.length >= 512) _limit();
    runs.add(
      SubtitleTextRun(
        text,
        bold: props['fontWeight'] == 'bold',
        italic: props['fontStyle'] == 'italic',
        underline: props['textDecoration'] == 'underline',
        color: _color(props['color'] ?? 'white'),
      ),
    );
    lineStart = text.endsWith('\n');
  }

  void add(String text, Map<String, String> props, bool preserve) {
    if (preserve) {
      if (pendingSpace != null && !lineStart) _append(' ', pendingSpace!);
      pendingSpace = null;
      _append(text, props);
      return;
    }
    for (final match in RegExp(r'[ \t\n\r]+|[^ \t\n\r]+').allMatches(text)) {
      final piece = match[0]!;
      if (RegExp(r'^[ \t\n\r]').hasMatch(piece)) {
        pendingSpace = props;
      } else {
        if (pendingSpace != null && !lineStart) _append(' ', pendingSpace!);
        pendingSpace = null;
        _append(piece, props);
      }
    }
  }

  void lineBreak(Map<String, String> props) {
    pendingSpace = null;
    _append('\n', props);
  }

  List<SubtitleTextRun> finish() => runs;
}
