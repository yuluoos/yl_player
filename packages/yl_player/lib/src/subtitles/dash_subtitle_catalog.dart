part of 'dash_subtitles.dart';

final class _DNode {
  _DNode(this.name, this.attributes);
  final String name;
  final Map<String, String> attributes;
  final children = <_DNode>[];
  final text = StringBuffer();
  List<_DNode> nodes(String name) =>
      children.where((n) => n.name == name).toList();
  _DNode? one(String name) {
    final list = nodes(name);
    if (list.length > 1) _dashBad();
    return list.isEmpty ? null : list.single;
  }
}

bool _dashXmlChar(int c) =>
    c == 9 ||
    c == 10 ||
    c == 13 ||
    (c >= 0x20 && c <= 0xd7ff) ||
    (c >= 0xe000 && c <= 0xfffd) ||
    (c >= 0x10000 && c <= 0x10ffff);

class _DashEntities extends XmlDefaultEntityMapping {
  const _DashEntities() : super.xml();
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
      if (end < 0 || end - amp > 16) _dashBad();
      final entity = input.substring(amp + 1, end);
      if (!RegExp(
        r'^(amp|lt|gt|quot|apos|#[0-9]+|#x[0-9a-fA-F]+)$',
      ).hasMatch(entity)) {
        _dashBad();
      }
      final value = super.decodeEntity(entity);
      if (value == null || !value.runes.every(_dashXmlChar)) _dashBad();
      buffer.write(value);
      cursor = end + 1;
    }
    return buffer.toString();
  }
}

void _dashQuotedAttributes(
  String raw,
  String opening,
  String closing,
  List<XmlEventAttribute> attributes,
) {
  if (!raw.startsWith(opening)) _dashBad();
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
      _dashBad();
    }
    offset = match.end;
  }
  if (raw.substring(offset).trim() != closing) _dashBad();
}

_DNode _dashXml(List<int> bytes) {
  if (bytes.length > 2 * 1024 * 1024) _dashLimit();
  final input = utf8
      .decode(bytes)
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  if (!input.runes.every(_dashXmlChar)) _dashBad();
  final stack = <_DNode>[];
  _DNode? root;
  var count = 0;
  for (final event in parseEvents(
    input,
    entityMapping: const _DashEntities(),
    validateNesting: true,
    validateNamespace: true,
    validateDocument: true,
    withNamespace: true,
    withLocation: true,
  )) {
    if (++count > 200000) _dashLimit();
    final raw = input.substring(event.start!, event.stop!);
    if (event is XmlStartElementEvent) {
      _dashQuotedAttributes(
        raw,
        '<${event.name}',
        event.isSelfClosing ? '/>' : '>',
        event.attributes,
      );
      if (stack.length >= 64 || event.attributes.length > 128) _dashLimit();
      final attrs = <String, String>{};
      for (final attr in event.attributes) {
        if (attr.value.length > 8192) _dashLimit();
        if (attr.namespaceUri == 'http://www.w3.org/1999/xlink') {
          _dashUnsupported();
        }
        if (attr.namespacePrefix == null && attr.name != 'xmlns' ||
            attr.namespaceUri == 'http://www.w3.org/XML/1998/namespace' &&
                attr.localName == 'lang') {
          if (attrs.containsKey(attr.localName)) _dashBad();
          attrs[attr.localName] = attr.value;
        }
      }
      final name =
          event.namespaceUri == null ||
              event.namespaceUri == '' ||
              event.namespaceUri == 'urn:mpeg:dash:schema:mpd:2011'
          ? event.localName
          : '';
      if ([
        'ContentProtection',
        'ContentSteering',
        'UTCTiming',
        'Location',
      ].contains(name)) {
        _dashUnsupported();
      }
      final node = _DNode(name, attrs);
      if (stack.isEmpty) {
        if (root != null) _dashBad();
        root = node;
      } else {
        stack.last.children.add(node);
      }
      if (!event.isSelfClosing) stack.add(node);
    } else if (event is XmlEndElementEvent) {
      stack.removeLast();
    } else if (event is XmlTextEvent || event is XmlCDATAEvent) {
      final value = event is XmlTextEvent
          ? event.value
          : (event as XmlCDATAEvent).value;
      if (!value.runes.every(_dashXmlChar) ||
          event is XmlTextEvent && raw.contains(']]>')) {
        _dashBad();
      }
      if (stack.isEmpty) {
        if (event is XmlCDATAEvent || raw.trim().isNotEmpty) _dashBad();
      } else {
        stack.last.text.write(value);
      }
    } else if (event is XmlDeclarationEvent) {
      if (event.start != 0 || root != null || raw.contains('&')) _dashBad();
      _dashQuotedAttributes(raw, '<?xml', '?>', event.attributes);
      if (!RegExp(
        r'^version(?:,encoding)?(?:,standalone)?$',
      ).hasMatch(event.attributes.map((a) => a.name).join(','))) {
        _dashBad();
      }
      for (final attr in event.attributes) {
        if (attr.name == 'version' && attr.value != '1.0') _dashUnsupported();
        if (attr.name == 'encoding' && attr.value.toLowerCase() != 'utf-8') {
          _dashUnsupported();
        }
        if (attr.name == 'standalone' && !{'yes', 'no'}.contains(attr.value)) {
          _dashBad();
        }
      }
    } else if (event is XmlCommentEvent) {
      if (event.value.contains('--') || event.value.endsWith('-')) _dashBad();
    } else {
      _dashUnsupported();
    }
  }
  if (root == null || root.name != 'MPD') _dashBad();
  return root;
}

final class _DAddress {
  String? mode;
  final attributes = <String, String>{};
  _DNode? timeline, initialization;
  List<_DNode> urls = [];
  _DAddress(List<_DNode> ancestors) {
    for (final ancestor in ancestors) {
      final nodes = ancestor.children
          .where(
            (n) => [
              'SegmentTemplate',
              'SegmentList',
              'SegmentBase',
            ].contains(n.name),
          )
          .toList();
      if (nodes.length > 1) _dashBad();
      if (nodes.isEmpty) continue;
      final node = nodes.single;
      if (mode != node.name) {
        attributes.clear();
        timeline = null;
        initialization = null;
        urls = [];
      }
      mode = node.name;
      attributes.addAll(node.attributes);
      timeline = node.one('SegmentTimeline') ?? timeline;
      initialization = node.one('Initialization') ?? initialization;
      if (node.nodes('SegmentURL').isNotEmpty) urls = node.nodes('SegmentURL');
    }
  }
}

final class _DashCatalogParser {
  _DashCatalogParser(this.location);
  final DashSubtitleLocation location;
  var _segments = 0, _uriUnits = 0, _representations = 0;
  final _identities = <String, String>{};
  List<DashSubtitleLocation> _bases(
    _DNode node,
    List<DashSubtitleLocation> parents,
  ) {
    final declarations = node.nodes('BaseURL');
    if (declarations.isEmpty) return parents;
    if (declarations.length * parents.length > 16) _dashLimit();
    return [
      for (final parent in parents)
        for (final declaration in declarations)
          _resolve(parent, declaration.text.toString().trim()),
    ];
  }

  DashSubtitleLocation _resolve(DashSubtitleLocation parent, String value) {
    final child = parent.resolve(value);
    _uriUnits += child.uri.toString().length;
    if (_uriUnits > 4 * 1024 * 1024) _dashLimit();
    return child;
  }

  DashSubtitleRange? _range(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^(\d{1,16})-(\d{1,16})$').firstMatch(value);
    if (match == null) _dashBad();
    final start = _dashInt(match[1]!), end = _dashInt(match[2]!);
    if (end < start || end > 0x1fffffffffffff) _dashBad();
    return DashSubtitleRange(start, end - start + 1);
  }

  DashSubtitleResource _resource(
    List<DashSubtitleLocation> parents,
    String? path,
    String? range,
  ) => DashSubtitleResource([
    for (final parent in parents) _resolve(parent, path ?? ''),
  ], range: _range(range));
  DashSubtitleCatalog parse(List<int> bytes) {
    final root = _dashXml(bytes);
    if ((root.attributes['type'] ?? 'static') != 'static') _dashUnsupported();
    final nodes = root.nodes('Period');
    if (nodes.isEmpty || nodes.length > 64) _dashLimit();
    final total = root.attributes['mediaPresentationDuration'] == null
        ? null
        : DashSubtitleTime.parseDuration(
            root.attributes['mediaPresentationDuration']!,
          );
    final rootBases = _bases(root, [location]);
    final periods = <DashSubtitlePeriod>[];
    final metadata = <String, YlSubtitleTrack>{};
    var cursor = DashSubtitleTime.zero;
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      final start = node.attributes['start'] == null
          ? cursor
          : DashSubtitleTime.parseDuration(node.attributes['start']!);
      final next =
          i + 1 < nodes.length && nodes[i + 1].attributes['start'] != null
          ? DashSubtitleTime.parseDuration(nodes[i + 1].attributes['start']!)
          : null;
      final declared = node.attributes['duration'];
      final span = declared != null
          ? DashSubtitleTime.parseDuration(declared)
          : next != null
          ? next - start
          : i + 1 == nodes.length && total != null
          ? total - start
          : _infer(root, node);
      if (start < DashSubtitleTime.zero ||
          span <= DashSubtitleTime.zero ||
          periods.isNotEmpty && start <= periods.last.start) {
        _dashBad();
      }
      cursor = start + span;
      final end = next != null && next < cursor ? next : cursor;
      final periodBases = _bases(node, rootBases);
      final tracks = <DashSubtitleTrack>[];
      for (final adaptation in node.nodes('AdaptationSet')) {
        final adaptationBases = _bases(adaptation, periodBases);
        final representations = adaptation.nodes('Representation');
        _representations += representations.length;
        if (_representations > 4096) _dashLimit();
        // Renditions share content identity. Validate all recognized text
        // representations, retain the first declared compatible rendition.
        final choices = <String, DashSubtitleTrack>{};
        for (final representation in representations) {
          final ancestors = [root, node, adaptation, representation];
          final attrs = <String, String>{
            for (final a in ancestors) ...a.attributes,
          };
          final mime = attrs['mimeType'], codecs = attrs['codecs'];
          final format = mime == 'text/vtt' || codecs == 'wvtt'
              ? YlSubtitleFormat.webvtt
              : mime == 'application/ttml+xml' ||
                    codecs == 'stpp' ||
                    codecs?.startsWith('stpp.') == true
              ? YlSubtitleFormat.ttml
              : null;
          if (format == null) continue;
          final roles =
              adaptation
                  .nodes('Role')
                  .where(
                    (n) =>
                        n.attributes['schemeIdUri'] ==
                        'urn:mpeg:dash:role:2011',
                  )
                  .map((n) => n.attributes['value'] ?? '')
                  .toList()
                ..sort();
          final label =
              representation.one('Label')?.text.toString().trim() ??
              adaptation.one('Label')?.text.toString().trim() ??
              attrs['label'];
          final content =
              adaptation.attributes['id'] ?? representation.attributes['id'];
          final canonical = jsonEncode([
            content,
            format.name,
            attrs['lang'],
            roles,
            label,
          ]);
          final id = _identity(canonical);
          final trackMetadata = YlSubtitleTrack(
            id: id,
            format: format,
            isExternal: false,
            label: label?.isEmpty == true ? null : label,
            language: attrs['lang'],
            role: roles.isEmpty ? null : roles.join(','),
            contentId: content,
          );
          final address = _DAddress(ancestors);
          final scale = _dashInt(address.attributes['timescale'] ?? '1'),
              offset = _dashInt(
                address.attributes['presentationTimeOffset'] ?? '0',
              );
          if (scale <= 0) _dashBad();
          final bases = _bases(representation, adaptationBases);
          DashSubtitleResource? initialization;
          if (address.attributes['initialization'] case final pattern?) {
            initialization = _resource(
              bases,
              _expand(pattern, representation.attributes, null, null),
              null,
            );
          } else if (address.initialization case final init?) {
            initialization = _resource(
              bases,
              init.attributes['sourceURL'],
              init.attributes['range'],
            );
          }
          final segments = <DashSubtitleSegment>[];
          if (address.mode == null || address.mode == 'SegmentBase') {
            // A standalone subtitle resource is still limited to the subtitle
            // byte budget. It cannot cause an AV movie to be fully downloaded.
            if (++_segments > 100000) _dashLimit();
            segments.add(
              DashSubtitleSegment(
                DashSubtitleTime.of(offset, scale),
                span,
                _resource(bases, null, null),
              ),
            );
            initialization = null;
          } else {
            final times = _times(address, scale, offset, span);
            if (address.mode == 'SegmentList' &&
                address.urls.length != times.length) {
              _dashBad();
            }
            final first = _dashInt(address.attributes['startNumber'] ?? '1');
            for (var index = 0; index < times.length; index++) {
              final (tick, duration) = times[index];
              final url = address.mode == 'SegmentList'
                  ? address.urls[index]
                  : null;
              final path =
                  url?.attributes['media'] ??
                  _expand(
                    address.attributes['media'] ?? _dashBad(),
                    representation.attributes,
                    _dashAdd(first, index),
                    tick,
                  );
              segments.add(
                DashSubtitleSegment(
                  DashSubtitleTime.of(tick, scale),
                  DashSubtitleTime.of(duration, scale),
                  _resource(bases, path, url?.attributes['mediaRange']),
                ),
              );
            }
          }
          final fragmented =
              mime == 'application/mp4' ||
              mime == 'text/mp4' ||
              codecs == 'wvtt' ||
              codecs == 'stpp' ||
              codecs?.startsWith('stpp.') == true;
          final track = DashSubtitleTrack(
            trackMetadata,
            DashSubtitleTime.of(offset, scale),
            initialization,
            segments,
            fragmented: fragmented,
          );
          choices.putIfAbsent(id, () => track);
        }
        for (final track in choices.values) {
          if (tracks.any((t) => t.id == track.id)) _dashBad();
          tracks.add(track);
          metadata.putIfAbsent(track.id, () => track.metadata);
        }
      }
      if (tracks.length > 32 || metadata.length > 128) _dashLimit();
      periods.add(DashSubtitlePeriod(start, end, tracks));
    }
    if (total != null && cursor != total) _dashBad();
    cursor.microseconds(ceil: true);
    validateYlSubtitleState(YlSubtitleState(tracks: metadata.values.toList()));
    return DashSubtitleCatalog._(
      List.unmodifiable(periods),
      List.unmodifiable(metadata.values),
      cursor,
    );
  }

  String _identity(String canonical) {
    // Opaque stable non-security hash. Retain canonical keys and reject any
    // collision rather than ever conflating different subtitle content.
    var hash = BigInt.parse('14695981039346656037');
    final mask = (BigInt.one << 64) - BigInt.one;
    for (final byte in utf8.encode(canonical)) {
      hash =
          ((hash ^ BigInt.from(byte)) * BigInt.parse('1099511628211')) & mask;
    }
    final id = 'dash-sub-${hash.toRadixString(16).padLeft(16, '0')}';
    if (_identities[id] != null && _identities[id] != canonical) _dashBad();
    _identities[id] = canonical;
    return id;
  }

  DashSubtitleTime _infer(_DNode root, _DNode period) {
    final ends = <DashSubtitleTime>[];
    for (final adaptation in period.nodes('AdaptationSet')) {
      for (final representation in adaptation.nodes('Representation')) {
        final ancestors = [root, period, adaptation, representation];
        final attrs = <String, String>{
          for (final node in ancestors) ...node.attributes,
        };
        if (!['audio', 'video'].contains(attrs['contentType']) &&
            !(attrs['mimeType']?.startsWith('audio/') ?? false) &&
            !(attrs['mimeType']?.startsWith('video/') ?? false)) {
          continue;
        }
        final address = _DAddress(ancestors);
        if (address.mode == null || address.mode == 'SegmentBase') {
          _dashUnsupported();
        }
        final scale = _dashInt(address.attributes['timescale'] ?? '1'),
            offset = _dashInt(
              address.attributes['presentationTimeOffset'] ?? '0',
            );
        if (scale == 0) _dashBad();
        final times = _times(address, scale, offset, null);
        if (times.isEmpty) _dashBad();
        if (address.mode == 'SegmentList' &&
            times.length != address.urls.length) {
          _dashBad();
        }
        ends.add(
          DashSubtitleTime.of(_dashAdd(times.last.$1, times.last.$2), scale) -
              DashSubtitleTime.of(offset, scale),
        );
      }
    }
    if (ends.isEmpty ||
        ends.first <= DashSubtitleTime.zero ||
        ends.any((e) => e != ends.first)) {
      _dashUnsupported();
    }
    return ends.first;
  }

  List<(int, int)> _times(
    _DAddress address,
    int scale,
    int offset,
    DashSubtitleTime? span,
  ) {
    final result = <(int, int)>[];
    void append(int start, int duration, int count) {
      if (start < 0 ||
          duration <= 0 ||
          count < 1 ||
          count > 100000 - _segments) {
        _dashLimit();
      }
      _dashAdd(start, _dashMultiply(duration, count));
      _segments += count;
      for (var n = 0; n < count; n++) {
        result.add((_dashAdd(start, _dashMultiply(duration, n)), duration));
      }
    }

    if (address.timeline case final timeline?) {
      final entries = timeline.nodes('S');
      if (entries.isEmpty) _dashBad();
      var cursor = 0;
      for (var index = 0; index < entries.length; index++) {
        final attrs = entries[index].attributes;
        final start = attrs['t'] == null ? cursor : _dashInt(attrs['t']!);
        final d = _dashInt(attrs['d'] ?? _dashBad()),
            repeat = _dashInt(attrs['r'] ?? '0', signed: true);
        if (d <= 0 ||
            repeat < -1 ||
            result.isNotEmpty && start <= result.last.$1) {
          _dashBad();
        }
        int count;
        if (repeat == -1) {
          final next = index + 1 < entries.length
              ? entries[index + 1].attributes['t']
              : null;
          final bound = next != null
              ? _dashInt(next)
              : span != null
              ? (span + DashSubtitleTime.of(offset, scale)).units(
                  scale,
                  ceil: true,
                )
              : _dashUnsupported();
          if (bound <= start) _dashBad();
          count = (bound - start) ~/ d + ((bound - start) % d == 0 ? 0 : 1);
        } else {
          count = _dashAdd(repeat, 1);
        }
        append(start, d, count);
        cursor = _dashAdd(start, _dashMultiply(d, count));
      }
    } else {
      final d = _dashInt(address.attributes['duration'] ?? _dashBad());
      if (d <= 0) _dashBad();
      final end = span == null
          ? null
          : (span + DashSubtitleTime.of(offset, scale)).units(
              scale,
              ceil: true,
            );
      final count = address.mode == 'SegmentList'
          ? address.urls.length
          : end == null
          ? _dashUnsupported()
          : end ~/ d + (end % d == 0 ? 0 : 1);
      append(0, d, count);
    }
    return result;
  }

  String _expand(
    String template,
    Map<String, String> attributes,
    int? number,
    int? time,
  ) {
    if (template.length > 8192) _dashLimit();
    final parts = template.split(r'$');
    if (parts.length.isEven) _dashBad();
    final out = StringBuffer();
    for (var i = 0; i < parts.length; i++) {
      final token = parts[i];
      if (i.isEven) {
        out.write(token);
      } else if (token.isEmpty) {
        out.write(r'$');
      } else if (token == 'RepresentationID') {
        out.write(attributes['id'] ?? _dashBad());
      } else {
        final m = RegExp(
          r'^(Number|Time|Bandwidth)(?:%0(\d{1,2})d)?$',
        ).firstMatch(token);
        if (m == null) _dashUnsupported();
        final value = switch (m[1]) {
          'Number' => number,
          'Time' => time,
          _ =>
            attributes['bandwidth'] == null
                ? null
                : _dashInt(attributes['bandwidth']!),
        };
        if (value == null) _dashBad();
        final width = m[2] == null ? 1 : int.parse(m[2]!);
        if (width < 1 || width > 20) _dashLimit();
        out.write(value.toString().padLeft(width, '0'));
      }
      if (out.length > 8192) _dashLimit();
    }
    return out.toString();
  }
}
