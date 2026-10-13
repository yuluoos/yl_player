import 'dart:convert';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'matroska_subtitles.dart' show EmbeddedSubtitleData;
import 'subtitle_document.dart';
import 'subtitle_resource.dart';

part 'mp4_webvtt.dart';
part 'mp4_ttml.dart';
part 'mp4_fragments.dart';

Never _bad() =>
    throw const SubtitleParseException(SubtitleParseReason.malformed);
Never _unsupported() =>
    throw const SubtitleParseException(SubtitleParseReason.unsupported);
Never _limit() =>
    throw const SubtitleParseException(SubtitleParseReason.limitExceeded);
int _u(List<int> b, int p, [int n = 4]) {
  if (p < 0 || p + n > b.length) _bad();
  var v = 0;
  for (var i = p; i < p + n; i++) {
    if (v > 0x1fffffffffffff ~/ 256) _limit();
    v = v * 256 + b[i];
  }
  return v;
}

int _signed(List<int> b, int p, int n) {
  if (p + n > b.length) _bad();
  if (b[p] & 128 == 0) return _u(b, p, n);
  // Decode two's complement without overflowing Dart's signed 64-bit int.
  return -1 - _u([for (final v in b.sublist(p, p + n)) 255 - v], 0, n);
}

String _type(List<int> b, int p) => String.fromCharCodes(b.sublist(p, p + 4));
String _utf8(List<int> b) {
  try {
    final s = utf8.decode(b);
    if (s.contains('\u0000')) _bad();
    return s;
  } on FormatException {
    return _bad();
  }
}

final class _Box {
  const _Box(this.type, this.start, this.end, {this.headerSize = 8});
  final String type;
  final int start, end, headerSize;
  int get offset => start - headerSize;
  int get size => end - start;
}

/// Bounded ISO BMFF subtitle demux, including fragmented tx3g/wvtt/stpp.
/// Skips audio/video payloads; no external drefs or segment URL fetching.
final class Mp4Subtitles {
  Mp4Subtitles(this.length, this.read, this.token);
  final int length;
  final Future<List<int>> Function(int, int) read;
  final SubtitleCancellation token;
  var _boxes = 0,
      _readBytes = 0,
      _payloadBytes = 0,
      _samples = 0,
      _runs = 0,
      _cueCount = 0;
  bool _fragmented = false;
  // Shared by initial sample tables and later fragments in the same resource.
  final _fragmentExtents = <(int, int)>[];
  final _fragmentTracks = <int, _Mp4TrackSamples>{};
  final _ids = <int>{};
  final _mdats = <_Box>[];
  Future<List<int>> _bytes(int p, int n) async {
    token.check();
    if (p < 0 || n < 0 || p > length || n > length - p) _bad();
    _readBytes += n;
    if (n > 256 * 1024 || _readBytes > 64 * 1024 * 1024) _limit();
    final b = await read(p, n);
    token.check();
    if (b.length != n) _bad();
    return b;
  }

  /// One allowance for container, subtitle configuration and sample boxes.
  void _countBox() {
    if (++_boxes > 200000) _limit();
  }

  Future<_Box> _box(int p, int end, {bool top = false}) async {
    _countBox();
    if (end - p < 8) _bad();
    final b = await _bytes(p, 8);
    var size = _u(b, 0), header = 8;
    if (size == 1) {
      if (end - p < 16) _bad();
      size = _u(await _bytes(p + 8, 8), 0, 8);
      header = 16;
    }
    if (size == 0) {
      if (!top) _unsupported();
      size = end - p;
    }
    if (size < header || size > end - p) _bad();
    return _Box(_type(b, 4), p + header, p + size, headerSize: header);
  }

  Future<List<_Box>> _children(
    int start,
    int end, {
    bool top = false,
    int max = 256,
  }) async {
    final out = <_Box>[];
    for (var p = start; p < end;) {
      if (out.length >= max) _limit();
      final b = await _box(p, end, top: top);
      out.add(b);
      p = b.end;
    }
    return out;
  }

  _Box? _one(List<_Box> boxes, String type, {bool required = false}) {
    final entries = boxes.where((b) => b.type == type).toList();
    if (entries.length > 1 || (required && entries.isEmpty)) _bad();
    return entries.isEmpty ? null : entries.single;
  }

  Future<List<int>> _body(_Box b, {int min = 0}) async {
    if (b.size < min) _bad();
    return _bytes(b.start, b.size);
  }

  void _full(List<int> b, {List<int> versions = const [0]}) {
    if (b.length < 4) _bad();
    if (!versions.contains(b[0]) || _u(b, 1, 3) != 0) _unsupported();
  }

  Future<List<EmbeddedSubtitleData>> parse() async {
    if (length > 0x1fffffffffffff) _limit();
    final root = await _children(0, length, top: true, max: 4096);
    final ftyp = _one(root, 'ftyp', required: true)!;
    final brands = await _body(ftyp, min: 8);
    if (brands.length % 4 != 0) _bad();
    final accepted = {
      'isom',
      'iso2',
      'iso3',
      'iso4',
      'iso5',
      'iso6',
      'mp41',
      'mp42',
      'M4V ',
      '3gp4',
      '3gp5',
      '3gp6',
      '3gp7',
      '3g2a',
    };
    if (![
      0,
      for (var i = 8; i < brands.length; i += 4) i,
    ].any((i) => accepted.contains(_type(brands, i)))) {
      _unsupported();
    }
    _mdats.addAll(root.where((b) => b.type == 'mdat'));
    final moov = _one(root, 'moov', required: true)!;
    final children = await _children(moov.start, moov.end);
    if (children.any((b) => b.type == 'cmov')) _unsupported();
    final mvex = _one(children, 'mvex');
    _fragmented = mvex != null;
    final fragments = root.where((b) => b.type == 'moof').toList();
    if (!_fragmented && fragments.isNotEmpty) _unsupported();
    if (fragments.any((b) => b.offset < moov.end)) _unsupported();
    final mvhd = await _body(_one(children, 'mvhd', required: true)!, min: 20);
    _full(mvhd, versions: [0, 1]);
    final movieScale = _u(mvhd, mvhd[0] == 0 ? 12 : 20);
    if (movieScale == 0) _bad();
    final tracks = children.where((b) => b.type == 'trak').toList();
    if (tracks.length > 128) _limit();
    final out = <EmbeddedSubtitleData>[];
    for (final t in tracks) {
      final data = await _track(t, movieScale);
      if (data != null) {
        if (out.length >= 32) _limit();
        out.add(data);
      }
    }
    if (mvex != null) {
      await _readFragments(mvex, fragments);
      return [for (final track in _fragmentTracks.values) track.data()];
    }
    return out;
  }

  Future<EmbeddedSubtitleData?> _track(_Box t, int movieScale) async {
    final children = await _children(t.start, t.end);
    final tkhd = await _body(_one(children, 'tkhd', required: true)!, min: 24);
    if (![0, 1].contains(tkhd[0])) _unsupported();
    final id = _u(tkhd, tkhd[0] == 0 ? 12 : 20);
    if (id == 0 || !_ids.add(id)) _bad();
    final mdia = _one(children, 'mdia', required: true)!;
    final media = await _children(mdia.start, mdia.end);
    final hdlr = await _body(_one(media, 'hdlr', required: true)!, min: 24);
    _full(hdlr);
    if (!['text', 'sbtl', 'subt', 'clcp'].contains(_type(hdlr, 8))) return null;
    final name = hdlr.sublist(
      24,
      hdlr.length > 24 && hdlr.last == 0 ? hdlr.length - 1 : hdlr.length,
    );
    if (name.length > 1024) _limit();
    final label = name.isEmpty ? null : _utf8(name);
    if (label != null && RegExp(r'[\x00-\x1f\x7f]').hasMatch(label)) _bad();
    final mdhd = await _body(_one(media, 'mdhd', required: true)!, min: 24);
    _full(mdhd, versions: [0, 1]);
    final scale = _u(mdhd, mdhd[0] == 0 ? 12 : 20);
    if (scale == 0) _bad();
    final lang = _u(mdhd, mdhd[0] == 0 ? 20 : 32, 2);
    final codes = [(lang >> 10) & 31, (lang >> 5) & 31, lang & 31];
    if (lang & 0x8000 != 0 || codes.any((c) => c < 1 || c > 26)) _unsupported();
    final language = String.fromCharCodes(codes.map((c) => c + 96));
    final minf = _one(media, 'minf', required: true)!;
    final info = await _children(minf.start, minf.end);
    final dinf = _one(info, 'dinf', required: true)!;
    final dref = _one(
      await _children(dinf.start, dinf.end),
      'dref',
      required: true,
    )!;
    final dr = await _body(dref, min: 8);
    _full(dr);
    final refs = await _children(dref.start + 8, dref.end);
    if (_u(dr, 4) != refs.length || refs.isEmpty) _bad();
    for (final r in refs) {
      final data = await _body(r, min: 4);
      if (r.type != 'url ' || data.length != 4 || _u(data, 0) != 1) {
        _unsupported();
      }
    }
    final stbl = _one(info, 'stbl', required: true)!;
    final tables = await _children(stbl.start, stbl.end);
    if (tables.any(
      (b) => !{
        'stsd',
        'stts',
        'stsc',
        'stsz',
        'stz2',
        'stco',
        'co64',
        'ctts',
        'stss',
        'free',
        'skip',
      }.contains(b.type),
    )) {
      _unsupported();
    }
    final sd = _one(tables, 'stsd', required: true)!;
    final sdb = await _body(sd, min: 8);
    _full(sdb);
    final entries = await _children(sd.start + 8, sd.end, max: 32);
    if (entries.isEmpty || _u(sdb, 4) != entries.length) _bad();
    final descriptions = <_Mp4SubtitleEntry>[];
    for (final entry in entries) {
      if (!['tx3g', 'wvtt', 'stpp'].contains(entry.type)) _unsupported();
      final b = await _body(entry, min: entry.type == 'tx3g' ? 38 : 8);
      if (b.take(6).any((v) => v != 0)) _bad();
      final ref = _u(b, 6, 2);
      if (ref < 1 || ref > refs.length) _bad();
      descriptions.add(switch (entry.type) {
        'tx3g' => _Tx3g.parse(b, _countBox),
        'wvtt' => _Wvtt.parse(b, _countBox),
        _ => _Stpp.parse(b, _countBox),
      });
    }
    // The public track has one format; codec switching within a track is not supported.
    if (descriptions.any((d) => d.format != descriptions.first.format)) {
      _unsupported();
    }
    final sz = _one(tables, 'stsz'), z2 = _one(tables, 'stz2');
    if ((sz == null) == (z2 == null)) _bad();
    final sizes = <int>[];
    final b = await _body((sz ?? z2)!, min: 12);
    _full(b);
    final count = _u(b, 8);
    _samples += count;
    if (_samples > 20000) _limit();
    if (sz != null) {
      final common = _u(b, 4);
      if (b.length != 12 + (common == 0 ? count * 4 : 0)) _bad();
      for (var i = 0; i < count; i++) {
        sizes.add(common == 0 ? _u(b, 12 + 4 * i) : common);
      }
    } else {
      final bits = b[7];
      if (_u(b, 4, 3) != 0 || ![4, 8, 16].contains(bits)) _bad();
      if (b.length != 12 + (count * bits + 7) ~/ 8) _bad();
      for (var i = 0; i < count; i++) {
        sizes.add(
          bits == 4
              ? (b[12 + i ~/ 2] >> (i.isEven ? 4 : 0)) & 15
              : _u(b, 12 + i * (bits ~/ 8), bits ~/ 8),
        );
      }
    }
    if (sizes.any((s) => s < 2)) _bad();
    final sync = _one(tables, 'stss');
    if (sync != null) {
      final b = await _body(sync, min: 8);
      _full(b);
      final n = _u(b, 4);
      if (n > count || b.length != 8 + 4 * n) _bad();
      var previous = 0;
      for (var i = 0; i < n; i++) {
        final sample = _u(b, 8 + 4 * i);
        if (sample <= previous || sample > count) _bad();
        previous = sample;
      }
    }
    final durations = await _timeTable(
      _one(tables, 'stts', required: true)!,
      count,
    );
    final ct = _one(tables, 'ctts');
    final offsets = ct == null
        ? List.filled(count, 0)
        : await _timeTable(ct, count, composition: true);
    final co = _one(tables, 'stco'), co64 = _one(tables, 'co64');
    if ((co == null) == (co64 == null)) _bad();
    final cb = await _body((co ?? co64)!, min: 8);
    _full(cb);
    final chunks = _u(cb, 4), width = co == null ? 8 : 4;
    if (chunks > 20000) _limit();
    if (cb.length != 8 + chunks * width) _bad();
    final sc = await _body(_one(tables, 'stsc', required: true)!, min: 8);
    _full(sc);
    final runs = _u(sc, 4);
    if (runs > chunks ||
        sc.length != 8 + 12 * runs ||
        (chunks == 0) != (count == 0) ||
        (runs == 0) != (chunks == 0)) {
      _bad();
    }
    final mapping = <(int, int, int)>[];
    for (var i = 0; i < runs; i++) {
      final first = _u(sc, 8 + i * 12),
          per = _u(sc, 12 + i * 12),
          desc = _u(sc, 16 + i * 12);
      if (first < 1 ||
          first > chunks ||
          per < 1 ||
          per > count ||
          desc < 1 ||
          desc > descriptions.length ||
          (i == 0 ? first != 1 : first <= mapping.last.$1)) {
        _bad();
      }
      mapping.add((first, per, desc));
    }
    final edit = await _edit(_one(children, 'edts'), movieScale, scale);
    final track = _Mp4TrackSamples(
      YlSubtitleTrack(
        id: 'mp4:$id',
        format: descriptions.first.format,
        isExternal: false,
        label: label,
        language: language,
        role: descriptions.every((d) => d.forced) ? 'forced' : null,
        contentId: '$id',
      ),
      descriptions,
      scale,
      movieScale,
      edit,
    );
    if (_fragmented) _fragmentTracks[id] = track;
    var sample = 0, run = 0, dts = 0;
    final extents = <(int, int)>[];
    for (var c = 1; c <= chunks; c++) {
      if (run + 1 < mapping.length && mapping[run + 1].$1 == c) run++;
      var pos = _u(cb, 8 + (c - 1) * width, width);
      final desc = descriptions[mapping[run].$3 - 1];
      final chunkStart = pos;
      for (var k = 0; k < mapping[run].$2; k++) {
        if (sample >= count) _bad();
        final size = sizes[sample];
        await _appendSample(
          track,
          desc,
          pos,
          size,
          dts + offsets[sample],
          durations[sample],
        );
        dts += durations[sample];
        if (dts > scale * 604800) _limit();
        pos += size;
        sample++;
      }
      extents.add((chunkStart, pos));
    }
    if (sample != count) _bad();
    // Fragment tfdt continues decode time, independently of ctts or edit clipping.
    if (_fragmented) track.decodeEnd = dts;
    extents.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 1; i < extents.length; i++) {
      if (extents[i].$1 < extents[i - 1].$2) _bad();
    }
    return track.data();
  }

  Future<void> _appendSample(
    _Mp4TrackSamples track,
    _Mp4SubtitleEntry desc,
    int pos,
    int size,
    int startTicks,
    int duration,
  ) async {
    final scale = track.scale, movieScale = track.movieScale, edit = track.edit;
    final packets = track.packets, sample = track.ordinal++;
    if (size < 2) _bad();
    if (!_mdats.any(
      (m) => pos >= m.start && pos <= m.end && size <= m.end - pos,
    )) {
      _bad();
    }
    if (_fragmented) _fragmentExtents.add((pos, pos + size));
    _payloadBytes += size;
    if (_payloadBytes > 4 * 1024 * 1024) _limit();
    final decoded = desc.decode(await _bytes(pos, size));
    if (desc.format == YlSubtitleFormat.ttml) track.sourceBytes += size;
    final endTicks = startTicks + duration;
    if (startTicks.abs() > scale * 604800 || endTicks.abs() > scale * 604800) {
      _limit();
    }
    int mapped(int ticks) =>
        ((BigInt.from(ticks - edit.mediaStart) * BigInt.from(movieScale) +
                    BigInt.from(edit.delayTicks) * BigInt.from(scale)) *
                BigInt.from(1000000) ~/
                (BigInt.from(scale) * BigInt.from(movieScale)))
            .toInt();
    final startUs = mapped(startTicks), endUs = mapped(endTicks);
    final start = startUs.clamp(edit.delay, edit.end),
        end = endUs.clamp(edit.delay, edit.end);
    if (decoded.isNotEmpty) {
      if (duration == 0) _bad();
      if (end > start) {
        for (final cue in decoded) {
          final ttml = cue.ttml;
          // TTML coordinates are track composition time (14496-30:2022),
          // not offsets from this sample. Combine edit ratios before rounding.
          int mappedTtml(Duration time) =>
              ((BigInt.from(time.inMicroseconds) *
                              BigInt.from(scale) *
                              BigInt.from(movieScale) -
                          BigInt.from(edit.mediaStart) *
                              BigInt.from(1000000) *
                              BigInt.from(movieScale) +
                          BigInt.from(edit.delayTicks) *
                              BigInt.from(scale) *
                              BigInt.from(1000000)) ~/
                      (BigInt.from(scale) * BigInt.from(movieScale)))
                  .toInt();
          final cueStart = ttml == null
              ? start
              : mappedTtml(ttml.start).clamp(start, end);
          final cueEnd = ttml == null
              ? end
              : mappedTtml(ttml.end).clamp(start, end);
          if (cueEnd <= cueStart) continue;
          final region = ttml?.region;
          _runs += cue.runs?.length ?? 0;
          if (_runs > 20000 || ++_cueCount > 10000) _limit();
          packets.add(
            EmbeddedSubtitlePacket(
              Duration(microseconds: cueStart),
              Duration(microseconds: cueEnd),
              cue.text,
              textRuns: cue.runs,
              alignment: cue.alignment,
              identifier: cue.identifier,
              webvttSettings: cue.settings,
              // Region identifiers are document-local, even when samples overlap.
              region: region == null
                  ? null
                  : SubtitleRegion(
                      id: '$sample:${region.id}',
                      x: region.x,
                      y: region.y,
                      width: region.width,
                      height: region.height,
                      displayAlign: region.displayAlign,
                    ),
            ),
          );
        }
      }
    }
  }

  int _micros(int t, int scale) =>
      (BigInt.from(t) * BigInt.from(1000000) ~/ BigInt.from(scale)).toInt();
  Future<List<int>> _timeTable(
    _Box box,
    int samples, {
    bool composition = false,
  }) async {
    final b = await _body(box, min: 8);
    _full(b, versions: composition ? [0, 1] : [0]);
    final count = _u(b, 4);
    if (count > 20000) _limit();
    if (b.length != 8 + 8 * count) _bad();
    final out = <int>[];
    for (var i = 0; i < count; i++) {
      final n = _u(b, 8 + 8 * i),
          v = composition && b[0] == 1
              ? _signed(b, 12 + 8 * i, 4)
              : _u(b, 12 + 8 * i);
      if (n == 0 || n > samples - out.length) _bad();
      out.addAll(List.filled(n, v));
    }
    if (out.length != samples) _bad();
    return out;
  }

  Future<({int delay, int delayTicks, int mediaStart, int end})> _edit(
    _Box? box,
    int movieScale,
    int scale,
  ) async {
    if (box == null) {
      return (delay: 0, delayTicks: 0, mediaStart: 0, end: 604800000000);
    }
    final elst = _one(
      await _children(box.start, box.end),
      'elst',
      required: true,
    )!;
    final b = await _body(elst, min: 8);
    _full(b, versions: [0, 1]);
    final n = _u(b, 4), w = b[0] == 1 ? 8 : 4, step = 2 * w + 4;
    if (n < 1 || n > 2) _unsupported();
    if (b.length != 8 + n * step) _bad();
    var delay = 0, delayTicks = 0, mediaStart = 0, end = 0;
    for (var i = 0; i < n; i++) {
      final at = 8 + i * step,
          duration = _u(b, at, w),
          media = _signed(b, at + w, w);
      if (_u(b, at + 2 * w) != 0x10000) _unsupported();
      if (duration > movieScale * 604800) _limit();
      if (media == -1 && i == 0 && n == 2) {
        delayTicks = duration;
        delay = _micros(duration, movieScale);
      } else {
        if (media < 0 || (i == 0 && n == 2)) _unsupported();
        if (media > scale * 604800) _limit();
        mediaStart = media;
        end = _fragmented && duration == 0
            ? 604800000000
            : _micros(delayTicks + duration, movieScale);
      }
    }
    if (end > 604800000000) _limit();
    return (
      delay: delay,
      delayTicks: delayTicks,
      mediaStart: mediaStart,
      end: end,
    );
  }
}

final class _Style {
  const _Style(this.font, this.face, this.size, this.color);
  final int font, face, size, color;
  static _Style read(List<int> b, int p) {
    final face = _u(b, p + 2, 1);
    if (face & ~7 != 0) _unsupported();
    final size = _u(b, p + 3, 1);
    if (size == 0) _unsupported();
    final rgba = _u(b, p + 4);
    return _Style(_u(b, p, 2), face, size, ((rgba & 255) << 24) | (rgba >> 8));
  }
}

final class _Tx3g implements _Mp4SubtitleEntry {
  _Tx3g(
    this.defaults,
    this.fonts,
    this.align,
    this.forced,
    this.backgroundColor,
    this._countBox,
  );
  final _Style defaults;
  final Map<int, String> fonts;
  final String align;
  @override
  final bool forced;
  final int backgroundColor;
  final void Function() _countBox;
  static _Tx3g parse(List<int> b, void Function() countBox) {
    final flags = _u(b, 8);
    // All samples forced is supported; some-forced needs per-sample frcd.
    if (![0, 0xc0000000].contains(flags) ||
        b[13] != 255 ||
        b.sublist(18, 26).any((v) => v != 0)) {
      _unsupported();
    }
    final align = switch (b[12]) {
      0 => 'left',
      1 => 'center',
      255 => 'right',
      _ => _unsupported(),
    };
    if (_u(b, 26) != 0) _unsupported();
    final defaults = _Style.read(b, 30);
    final fonts = <int, String>{};
    for (var p = 38; p < b.length;) {
      countBox();
      if (b.length - p < 8) _bad();
      final size = _u(b, p);
      if (size < 8 || size > b.length - p) _bad();
      final type = _type(b, p + 4);
      if (type == 'ftab') {
        if (fonts.isNotEmpty || size < 10) _bad();
        final n = _u(b, p + 8, 2);
        if (n > 64) _limit();
        var at = p + 10;
        for (var i = 0; i < n; i++) {
          if (at + 3 > p + size) _bad();
          final id = _u(b, at, 2), len = b[at + 2];
          at += 3;
          if (len == 0 || at + len > p + size || fonts.containsKey(id)) _bad();
          final name = _utf8(b.sublist(at, at + len));
          if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) _bad();
          fonts[id] = name;
          at += len;
        }
        if (at != p + size) _bad();
      } else if (type != 'btrt') {
        _unsupported();
      }
      p += size;
    }
    if (!fonts.containsKey(defaults.font)) _unsupported();
    final rgba = _u(b, 14);
    return _Tx3g(
      defaults,
      fonts,
      align,
      flags == 0xc0000000,
      ((rgba & 255) << 24) | (rgba >> 8),
      countBox,
    );
  }

  @override
  YlSubtitleFormat get format => YlSubtitleFormat.srt;
  @override
  List<_Mp4Cue> decode(List<int> b) {
    final runs = _decodeText(b);
    return runs.isEmpty
        ? []
        : [
            _Mp4Cue(
              runs.map((r) => r.text).join(),
              runs: runs,
              alignment: align,
            ),
          ];
  }

  List<SubtitleTextRun> _decodeText(List<int> b) {
    final len = _u(b, 0, 2);
    if (len > b.length - 2) _bad();
    final raw = b.sublist(2, len + 2);
    String text;
    if (raw.length >= 2 &&
        ((raw[0] == 254 && raw[1] == 255) ||
            (raw[0] == 255 && raw[1] == 254))) {
      if (raw.length.isOdd) _bad();
      final le = raw[0] == 255;
      final units = [
        for (var p = 2; p < raw.length; p += 2)
          le ? raw[p] | (raw[p + 1] << 8) : (raw[p] << 8) | raw[p + 1],
      ];
      for (var i = 0; i < units.length; i++) {
        if (units[i] >= 0xd800 && units[i] <= 0xdbff) {
          if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
            _bad();
          }
        } else if (units[i] >= 0xdc00 && units[i] <= 0xdfff) {
          _bad();
        }
      }
      text = String.fromCharCodes(units);
    } else {
      text = _utf8(raw);
    }
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    if (text.contains('\u0000')) _bad();
    if (text.length > 16384) _limit();
    // tx3g style offsets count Unicode characters, not UTF-8 bytes.
    final chars = text.runes.toList();
    final styles = <(int, int, _Style)>[];
    var stylSeen = false;
    for (var p = 2 + len; p < b.length;) {
      _countBox();
      if (b.length - p < 8) _bad();
      final size = _u(b, p);
      if (size < 8 || size > b.length - p) _bad();
      final type = _type(b, p + 4);
      if (type != 'styl') _unsupported();
      if (stylSeen || size < 10) _bad();
      stylSeen = true;
      final n = _u(b, p + 8, 2);
      if (n > 1024) _limit();
      if (size != 10 + 12 * n) _bad();
      for (var i = 0; i < n; i++) {
        final at = p + 10 + 12 * i,
            start = _u(b, at, 2),
            end = _u(b, at + 2, 2);
        if (end < start ||
            end > chars.length ||
            (styles.isNotEmpty && start < styles.last.$2)) {
          _bad();
        }
        final s = _Style.read(b, at + 4);
        if (!fonts.containsKey(s.font)) _unsupported();
        if (end > start) styles.add((start, end, s));
      }
      p += size;
    }
    final out = <SubtitleTextRun>[];
    void append(int a, int b, _Style style) {
      if (b <= a) return;
      // Keep style offsets in the original scalar sequence. A CRLF is one
      // newline even if CR and LF belong to different style records.
      final normalized = <int>[];
      for (var i = a; i < b; i++) {
        if (chars[i] == 10 && i > 0 && chars[i - 1] == 13) continue;
        normalized.add(chars[i] == 13 ? 10 : chars[i]);
      }
      if (normalized.isEmpty) return;
      out.add(
        SubtitleTextRun(
          String.fromCharCodes(normalized),
          bold: style.face & 1 != 0,
          italic: style.face & 2 != 0,
          underline: style.face & 4 != 0,
          color: style.color,
          fontSize: style.size.toDouble(),
          fontFamily: fonts[style.font],
          backgroundColor: backgroundColor,
        ),
      );
    }

    var at = 0;
    for (final s in styles) {
      append(at, s.$1, defaults);
      append(s.$1, s.$2, s.$3);
      at = s.$2;
    }
    append(at, chars.length, defaults);
    return List.unmodifiable(out);
  }
}
