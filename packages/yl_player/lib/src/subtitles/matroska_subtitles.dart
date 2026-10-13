import 'dart:convert';
import 'dart:typed_data';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'subtitle_document.dart';
import 'subtitle_resource.dart';
import 'subtitle_inflate.dart';

part 'matroska_webvtt.dart';

/// Bounded random-access demux; media payloads are skipped, never decoded here.
/// Unknown-size Segment is accepted; unknown-size children are not supported.
final class MatroskaSubtitles {
  MatroskaSubtitles(this.length, this.read, this.token, {this.expectedDocType});
  final String? expectedDocType;
  var _webm = false;
  final int length;
  final Future<List<int>> Function(int offset, int count) read;
  final SubtitleCancellation token;
  var _elements = 0, _readBytes = 0, _payloadBytes = 0, _packetCount = 0;
  var _scale = 1000000, _pgsPacketCount = 0;
  final _tracks = <int, _Track>{};
  final _uids = <String>{};
  final _numbers = <int>{};

  Never _bad() =>
      throw const SubtitleParseException(SubtitleParseReason.malformed);
  Never _unsupported() =>
      throw const SubtitleParseException(SubtitleParseReason.unsupported);
  Never _limit() =>
      throw const SubtitleParseException(SubtitleParseReason.limitExceeded);
  Future<List<int>> _bytes(int offset, int count) async {
    token.check();
    if (offset < 0 || count < 0 || offset + count > length) _bad();
    _readBytes += count;
    if (_readBytes > 64 * 1024 * 1024) _limit();
    final b = await read(offset, count);
    token.check();
    if (b.length != count) _bad();
    return b;
  }

  Future<_Element> _element(int offset, int end, {bool segment = false}) async {
    if (++_elements > 2000000) _limit();
    final b = await _bytes(offset, (end - offset).clamp(0, 12));
    if (b.isEmpty) _bad();
    final idWidth = _width(b[0], 4);
    if (b.length <= idWidth) _bad();
    final sizeWidth = _width(b[idWidth], 8);
    if (b.length < idWidth + sizeWidth) _bad();
    final id = _integer(b.take(idWidth).toList());
    var size = b[idWidth] & ((1 << (8 - sizeWidth)) - 1);
    for (var i = 1; i < sizeWidth; i++) {
      size = size * 256 + b[idWidth + i];
    }
    final unknown = size == (1 << (7 * sizeWidth)) - 1;
    final start = offset + idWidth + sizeWidth;
    if (unknown && !(segment && id == 0x18538067)) _unsupported();
    final stop = unknown ? end : start + size;
    if (stop > end || stop < start) _bad();
    return _Element(id, start, stop);
  }

  int _width(int first, int max) {
    for (var n = 1; n <= max; n++) {
      if (first & (1 << (8 - n)) != 0) return n;
    }
    return _bad();
  }

  int _integer(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > 8) _bad();
    var result = 0;
    for (final byte in bytes) {
      if (result > 0x1fffffffffffff ~/ 256) _limit();
      result = result * 256 + byte;
    }
    return result;
  }

  Future<int> _uint(_Element e) async {
    if (e.size > 8) _bad();
    return _integer(await _bytes(e.start, e.size));
  }

  Future<String> _string(_Element e, int limit) async {
    if (e.size > limit * 4) _limit();
    String s;
    try {
      s = utf8.decode(await _bytes(e.start, e.size));
    } on FormatException {
      return _bad();
    }
    if (s.length > limit) _limit();
    if (s.isEmpty || RegExp(r'[\x00-\x1f\x7f]').hasMatch(s)) _bad();
    return s;
  }

  Future<List<_Element>> _children(_Element e, {int limit = 128}) async {
    final result = <_Element>[];
    for (var at = e.start; at < e.end;) {
      if (result.length >= limit) _limit();
      final child = await _element(at, e.end);
      result.add(child);
      at = child.end;
    }
    return result;
  }

  Future<Map<int, _Element>> _fields(
    _Element e, {
    bool blockGroup = false,
  }) async {
    final fields = <int, _Element>{};
    for (final child in await _children(e)) {
      if (child.id == 0xec || child.id == 0xbf) continue;
      if (blockGroup && child.id == 0xfb) continue;
      if (fields.containsKey(child.id)) _bad();
      fields[child.id] = child;
    }
    return fields;
  }

  Future<List<EmbeddedSubtitleData>> parse() async {
    final header = await _element(0, length);
    if (header.id != 0x1a45dfa3) _unsupported();
    final h = await _fields(header);
    if (h[0x4282] == null) _unsupported();
    final docType = await _string(h[0x4282]!, 16);
    if (!['matroska', 'webm'].contains(docType) ||
        (expectedDocType != null && expectedDocType != docType)) {
      _unsupported();
    }
    _webm = docType == 'webm';
    for (final (id, max) in [
      (0x42f7, 1),
      (0x4285, 4),
      (0x42f2, 4),
      (0x42f3, 8),
    ]) {
      if (h[id] != null && await _uint(h[id]!) > max) _unsupported();
    }
    var at = header.end;
    while (at < length) {
      final e = await _element(at, length, segment: true);
      if (e.id == 0xec || e.id == 0xbf) {
        at = e.end;
        continue;
      }
      if (e.id != 0x18538067 || e.end != length) _unsupported();
      final clusters = <_Element>[];
      var infoSeen = false, tracksSeen = false;
      for (var pos = e.start; pos < e.end;) {
        final child = await _element(pos, e.end);
        pos = child.end;
        if (child.id == 0x1549a966) {
          if (infoSeen) _bad();
          infoSeen = true;
          final f = await _fields(child);
          if (f[0x2ad7b1] != null) _scale = await _uint(f[0x2ad7b1]!);
          if (_scale < 1 || _scale > 1000000000) _unsupported();
          if ([0x3cb923, 0x3eb923].any(f.containsKey)) _unsupported();
        } else if (child.id == 0x1654ae6b) {
          if (tracksSeen) _bad();
          tracksSeen = true;
          for (final entry in await _children(child, limit: 256)) {
            if (entry.id == 0xae) await _track(entry);
          }
        } else if (child.id == 0x1f43b675) {
          if (clusters.length >= 50000) _limit();
          clusters.add(child);
        }
      }
      if (!tracksSeen) _bad();
      for (final c in clusters) {
        await _cluster(c);
      }
      return [
        for (final t in _tracks.values)
          EmbeddedSubtitleData(
            t.track,
            t.private,
            List.unmodifiable(t.packets),
            sourceBytes: t.sourceBytes,
            compressionBytes: t.compressionBytes,
            pgsPackets: List.unmodifiable(t.pgsPackets),
            vobSubPackets: List.unmodifiable(t.vobSubPackets),
          ),
      ];
    }
    return _bad();
  }

  Future<void> _track(_Element e) async {
    if (_numbers.length >= 128) _limit();
    final f = await _fields(e);
    if (![0xd7, 0x73c5, 0x83, 0x86].every(f.containsKey)) _bad();
    final number = await _uint(f[0xd7]!);
    final uidField = f[0x73c5]!;
    if (uidField.size < 1 || uidField.size > 8) _bad();
    var uid = BigInt.zero;
    for (final b in await _bytes(uidField.start, uidField.size)) {
      uid = (uid << 8) | BigInt.from(b);
    }
    if (number < 1 ||
        number > 0x7fffffff ||
        uid == BigInt.zero ||
        !_numbers.add(number) ||
        !_uids.add(uid.toString())) {
      _bad();
    }
    if (await _uint(f[0x83]!) != 17) return;
    if (f[0xb9] != null && await _uint(f[0xb9]!) == 0) return;
    if (_tracks.length >= 32) _limit();
    final codec = await _string(f[0x86]!, 128);
    if (_webm && !['D_WEBVTT/SUBTITLES', 'D_WEBVTT/CAPTIONS'].contains(codec)) {
      _unsupported();
    }
    final format = switch (codec) {
      'S_TEXT/UTF8' => YlSubtitleFormat.srt,
      'S_TEXT/ASS' => YlSubtitleFormat.ass,
      'S_TEXT/SSA' => YlSubtitleFormat.ssa,
      'S_HDMV/PGS' => YlSubtitleFormat.pgs,
      'S_VOBSUB' => YlSubtitleFormat.vobsub,
      'S_TEXT/WEBVTT' ||
      'D_WEBVTT/SUBTITLES' ||
      'D_WEBVTT/CAPTIONS' => YlSubtitleFormat.webvtt,
      _ => _unsupported(),
    };
    if ([0x6fab, 0x6624, 0x41e4].any(f.containsKey)) _unsupported();
    if (f[0x537f] != null &&
        await _uint(f[0x537f]!) > (codec == 'S_TEXT/WEBVTT' ? 1 : 0)) {
      _unsupported();
    }
    if (f[0x23314f] case final scale?) {
      if (scale.size != 4 && scale.size != 8) _bad();
      final bytes = Uint8List.fromList(await _bytes(scale.start, scale.size));
      final data = ByteData.sublistView(bytes);
      if ((scale.size == 4 ? data.getFloat32(0) : data.getFloat64(0)) != 1) {
        _unsupported();
      }
    }
    final compression = f[0x6d80] == null
        ? null
        : await _compression(f[0x6d80]!);
    String? private;
    if (f[0x63a2] case final p?) {
      _payloadBytes += p.size;
      if (p.size > 256 * 1024 || _payloadBytes > 4 * 1024 * 1024) _limit();
      try {
        private = utf8.decode(await _bytes(p.start, p.size));
      } on FormatException {
        _bad();
      }
    }
    if ((format == YlSubtitleFormat.srt || format == YlSubtitleFormat.pgs) &&
        (private?.isNotEmpty ?? false)) {
      _unsupported();
    }
    if (format == YlSubtitleFormat.vobsub &&
        (private == null || private.isEmpty)) {
      _bad();
    }
    if (format == YlSubtitleFormat.webvtt) {
      if (codec == 'S_TEXT/WEBVTT') {
        if (private == null) _bad();
        _webVttHeader(private);
      } else if (private?.isNotEmpty ?? false) {
        _unsupported();
      }
    }
    final lang = f[0x22b59d] ?? f[0x22b59c];
    final forced = f[0x55aa] == null ? 0 : await _uint(f[0x55aa]!);
    if (forced > 1) _bad();
    _tracks[number] = _Track(
      YlSubtitleTrack(
        id: 'mkv:$uid',
        format: format,
        label: f[0x536e] == null ? null : await _string(f[0x536e]!, 1024),
        language: lang == null ? 'eng' : await _string(lang, 128),
        role: forced == 1 ? 'forced' : 'main',
      ),
      format == YlSubtitleFormat.webvtt ? null : private,
      f[0x23e383] == null ? null : await _uint(f[0x23e383]!),
      f[0x56aa] == null ? 0 : await _uint(f[0x56aa]!),
      compression: compression,
      compressionBytes: compression?.header.length ?? 0,
      webVttInBlock: codec.startsWith('D_WEBVTT/'),
      sourceBytes: format == YlSubtitleFormat.webvtt
          ? (f[0x63a2]?.size ?? 0)
          : 0,
    );
  }

  Future<_Compression> _compression(_Element e) async {
    if (_webm) _unsupported();
    final entries = (await _children(
      e,
    )).where((c) => c.id != 0xec && c.id != 0xbf).toList();
    if (entries.length != 1 || entries.single.id != 0x6240) _unsupported();
    final f = await _fields(entries.single);
    if (f.keys.any((id) => ![0x5031, 0x5032, 0x5033, 0x5034].contains(id))) {
      _unsupported();
    }
    if ((f[0x5031] != null && await _uint(f[0x5031]!) != 0) ||
        (f[0x5032] != null && await _uint(f[0x5032]!) != 1) ||
        (f[0x5033] != null && await _uint(f[0x5033]!) != 0)) {
      _unsupported();
    }
    if (f[0x5034] == null) _bad();
    final c = await _fields(f[0x5034]!);
    if (c.keys.any((id) => id != 0x4254 && id != 0x4255)) _unsupported();
    final algorithm = c[0x4254] == null ? 0 : await _uint(c[0x4254]!);
    if (algorithm != 0 && algorithm != 3) _unsupported();
    final settings = c[0x4255];
    if (algorithm == 0 && settings != null && settings.size != 0) {
      _unsupported();
    }
    if (algorithm == 3 && settings == null) _bad();
    final size = settings?.size ?? 0;
    _payloadBytes += size;
    if (size > 256 * 1024 || _payloadBytes > 4 * 1024 * 1024) _limit();
    return _Compression(
      algorithm,
      settings == null ? const [] : await _bytes(settings.start, size),
    );
  }

  Future<List<int>> _payload(
    _Element e,
    int offset,
    _Track t,
    int limit,
  ) async {
    final size = e.size - offset;
    final compression = t.compression;
    _payloadBytes += size;
    if (size > (compression == null ? limit : 256 * 1024) ||
        _payloadBytes > 4 * 1024 * 1024) {
      _limit();
    }
    final bytes = await _bytes(e.start + offset, size);
    if (compression == null) return bytes;
    t.compressionBytes += size;
    final left = (4 * 1024 * 1024 - _payloadBytes).clamp(0, limit);
    final List<int> decoded;
    if (compression.algorithm == 0) {
      decoded = inflateSubtitle(bytes, left);
    } else {
      if (compression.header.length + bytes.length > left) _limit();
      decoded = [...compression.header, ...bytes];
    }
    _payloadBytes += decoded.length;
    token.check();
    return decoded;
  }

  Future<void> _cluster(_Element e) async {
    // First pass finds Timestamp regardless of child order, without retaining blocks.
    int? time;
    for (var at = e.start; at < e.end;) {
      final child = await _element(at, e.end);
      at = child.end;
      if (child.id == 0xe7) {
        if (time != null) _bad();
        time = await _uint(child);
      }
    }
    if (time == null || time > 604800000000000 ~/ _scale) _limit();
    for (var at = e.start; at < e.end;) {
      final child = await _element(at, e.end);
      at = child.end;
      if (child.id == 0xa3) {
        await _block(child, time, null, false);
      } else if (child.id == 0xa0) {
        final f = await _fields(child, blockGroup: true);
        if (f[0xa1] == null) _bad();
        final duration = f[0x9b] == null ? null : await _uint(f[0x9b]!);
        await _block(
          f[0xa1]!,
          time,
          duration,
          [0xa4, 0x75a2, 0x8e, 0xfd].any(f.containsKey) ||
              (f[0xfa] != null && await _uint(f[0xfa]!) != 0),
          additions: f[0x75a1],
        );
      }
    }
  }

  Future<void> _block(
    _Element e,
    int cluster,
    int? duration,
    bool effects, {
    _Element? additions,
  }) async {
    final prefix = await _bytes(e.start, e.size.clamp(0, 11));
    if (prefix.isEmpty) _bad();
    final width = _width(prefix[0], 8);
    if (prefix.length < width + 3) _bad();
    final numberBytes = prefix.take(width).toList();
    numberBytes[0] &= (1 << (8 - width)) - 1;
    final number = _integer(numberBytes);
    if (!_numbers.contains(number)) _bad();
    final t = _tracks[number];
    if (t == null) return;
    if (effects || prefix[width + 2] & 0x0f != 0) _unsupported();
    final webVtt = t.track.format == YlSubtitleFormat.webvtt;
    if (webVtt && duration == null) _unsupported();
    if (additions != null && (!webVtt || t.webVttInBlock)) _unsupported();
    var relative = prefix[width] * 256 + prefix[width + 1];
    if (relative >= 32768) relative -= 65536;
    final ticks = cluster + relative;
    if (ticks < 0 || ticks > 604800000000000 ~/ _scale) _bad();
    final startNs = ticks * _scale - t.delay;
    final pgs = t.track.format == YlSubtitleFormat.pgs;
    final vobSub = t.track.format == YlSubtitleFormat.vobsub;
    final bitmap = pgs || vobSub;
    if (startNs < 0) _bad();
    final durationNs = duration == null
        ? t.defaultDuration
        : duration <= 604800000000000 ~/ _scale
        ? duration * _scale
        : null;
    if (durationNs == null && (!bitmap || duration != null)) _unsupported();
    if (bitmap) {
      if (durationNs != null &&
          (durationNs <= 0 || startNs + durationNs > 604800000000000)) {
        _bad();
      }
      if (pgs ? ++_pgsPacketCount > 50000 : ++_packetCount > 10000) _limit();
      final start = Duration(microseconds: startNs ~/ 1000);
      final end = durationNs == null
          ? null
          : Duration(microseconds: (startNs + durationNs) ~/ 1000);
      if (end != null && end <= start) _unsupported();
      final bytes = await _payload(e, width + 3, t, pgs ? 256 * 1024 : 65535);
      if (bytes.isEmpty) _bad();
      if (pgs) {
        t.pgsPackets.add(EmbeddedPgsPacket(start, bytes, end: end));
      } else {
        t.vobSubPackets.add(EmbeddedVobSubPacket(start, bytes, end: end));
      }
      return;
    }
    if (durationNs == null) _unsupported();
    if (durationNs <= 0 ||
        startNs < 0 ||
        startNs + durationNs > 604800000000000) {
      _bad();
    }
    final start = Duration(microseconds: startNs ~/ 1000),
        end = Duration(microseconds: (startNs + durationNs) ~/ 1000);
    if (end <= start) _unsupported();
    if (++_packetCount > 10000) _limit();
    final bytes = await _payload(e, width + 3, t, 64 * 1024);
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      _bad();
    }
    if (text.isEmpty || text.contains('\u0000')) _bad();
    if (text.length > 16384 + 4096) _limit();
    if (webVtt) {
      t.sourceBytes += bytes.length;
      String? metadata;
      if (additions != null) {
        final more = (await _children(
          additions,
        )).where((e) => e.id != 0xec && e.id != 0xbf).toList();
        if (more.isEmpty) _bad();
        if (more.length != 1 || more.single.id != 0xa6) _unsupported();
        final fields = await _fields(more.single);
        if (fields.keys.any((id) => id != 0xee && id != 0xa5)) _unsupported();
        if (fields[0xee] != null && await _uint(fields[0xee]!) != 1) {
          _unsupported();
        }
        final data = fields[0xa5];
        if (data == null) _bad();
        _payloadBytes += data.size;
        if (data.size > 64 * 1024 || _payloadBytes > 4 * 1024 * 1024) _limit();
        t.sourceBytes += data.size;
        try {
          metadata = utf8.decode(await _bytes(data.start, data.size));
        } on FormatException {
          _bad();
        }
      }
      t.packets.add(_webVttPacket(start, end, text, metadata, t.webVttInBlock));
    } else {
      t.packets.add(EmbeddedSubtitlePacket(start, end, text));
    }
  }
}

final class _Element {
  const _Element(this.id, this.start, this.end);
  final int id, start, end;
  int get size => end - start;
}

final class _Track {
  _Track(
    this.track,
    this.private,
    this.defaultDuration,
    this.delay, {
    this.compression,
    this.compressionBytes = 0,
    this.webVttInBlock = false,
    this.sourceBytes = 0,
  });
  final _Compression? compression;
  int compressionBytes;
  final bool webVttInBlock;
  int sourceBytes;
  final YlSubtitleTrack track;
  final String? private;
  final int? defaultDuration;
  final int delay;
  final packets = <EmbeddedSubtitlePacket>[];
  final pgsPackets = <EmbeddedPgsPacket>[];
  final vobSubPackets = <EmbeddedVobSubPacket>[];
}

final class EmbeddedSubtitleData {
  const EmbeddedSubtitleData(
    this.track,
    this.codecPrivate,
    this.packets, {
    this.sourceBytes = 0,
    this.pgsPackets = const [],
    this.vobSubPackets = const [],
    this.compressionBytes = 0,
  });

  /// Stored block bytes/settings charged in addition to reconstructed content.
  final int compressionBytes;
  final List<EmbeddedPgsPacket> pgsPackets;
  final List<EmbeddedVobSubPacket> vobSubPackets;
  final YlSubtitleTrack track;
  final String? codecPrivate;
  final List<EmbeddedSubtitlePacket> packets;

  /// Retain the encoded document budget when cues expand from container samples.
  final int sourceBytes;
}

final class _Compression {
  const _Compression(this.algorithm, this.header);
  final int algorithm;
  final List<int> header;
}
