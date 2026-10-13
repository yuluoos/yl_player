part of 'subtitle_document.dart';

/// A complete Matroska DVD SPU, without PS/PES framing or an IDX file offset.
final class EmbeddedVobSubPacket {
  EmbeddedVobSubPacket(this.start, List<int> bytes, {this.end})
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();
  final Duration start;
  final Duration? end;
  final Uint8List bytes;
  @override
  String toString() => 'EmbeddedVobSubPacket(payload: <redacted>)';
}

final class _VobEntry {
  const _VobEntry(this.time, this.position);
  final int time, position; // Microseconds and byte offset, not PES PTS.
}

final class _VobStream {
  _VobStream(this.language, this.index);
  final String language;
  final int index;
  final entries = <_VobEntry>[];
}

final class _VobIndex {
  int width = 0, height = 0;
  List<int>? palette;
  final streams = <int, _VobStream>{};
  int? preferred;
  static const horizon = 7 * 24 * 60 * 60 * 1000000;

  _VobIndex(List<int> bytes, {bool embedded = false}) {
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      _malformed();
    }
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    // Bound line allocation before splitting, including CR-only files.
    var lines = 1;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 10 ||
          (text.codeUnitAt(i) == 13 &&
              (i + 1 == text.length || text.codeUnitAt(i + 1) != 10))) {
        if (++lines > 50000) _limit();
      }
    }
    final rows = const LineSplitter().convert(text);
    if (rows.isNotEmpty && rows.first.length > 2048) _limit();
    if (!embedded &&
        (rows.isEmpty ||
            !RegExp(
              r'^# VobSub index file, v7(?:\s|$)',
            ).hasMatch(rows.first))) {
      _malformed();
    }
    _VobStream? current;
    var delay = 0, entries = 0;
    final settings = <String>{};
    for (final raw in embedded ? rows : rows.skip(1)) {
      if (raw.length > 2048) _limit();
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.contains(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]'))) _malformed();
      final colon = line.indexOf(':');
      if (colon < 1) _malformed();
      final key = line.substring(0, colon).toLowerCase(),
          value = line.substring(colon + 1).trim();
      // Matroska owns stream identity and timing. Old IDX timestamps must
      // never override the edited container timeline or cause sidecar I/O.
      if (embedded && ['id', 'langidx', 'timestamp', 'alt'].contains(key)) {
        continue;
      }
      switch (key) {
        case 'size':
          if (!settings.add(key) || current != null) _malformed();
          final m = RegExp(r'^(\d{1,5})x(\d{1,5})$').firstMatch(value);
          if (m == null) _malformed();
          width = int.parse(m[1]!);
          height = int.parse(m[2]!);
          if (width == 0 || height == 0) _malformed();
          if (width > 8192 || height > 8192) _limit();
        case 'palette':
          if (!settings.add(key) || current != null) _malformed();
          final parts = value.split(',').map((v) => v.trim()).toList();
          if (parts.length != 16 ||
              parts.any((v) => !RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(v))) {
            _malformed();
          }
          palette = [for (final p in parts) int.parse(p, radix: 16)];
        case 'id':
          final m = RegExp(
            r'^([A-Za-z-]{2,8}),\s*index:\s*(\d{1,2})$',
          ).firstMatch(value);
          if (m == null) _malformed();
          final id = int.parse(m[2]!);
          if (id > 31) _limit();
          if (streams.containsKey(id)) _malformed();
          current = _VobStream(m[1]!.toLowerCase(), id);
          streams[id] = current;
        case 'timestamp':
          if (current == null) _malformed();
          if (++entries > 10000) _limit();
          final m = RegExp(
            r'^(\d{2,3}:\d{2}:\d{2}:\d{3}),\s*filepos:\s*([0-9a-fA-F]{1,12})$',
          ).firstMatch(value);
          if (m == null) _malformed();
          final time = clock(m[1]!) + delay, pos = int.parse(m[2]!, radix: 16);
          if (time.abs() >= horizon) _limit();
          if (current.entries.isNotEmpty &&
              (time <= current.entries.last.time ||
                  pos <= current.entries.last.position)) {
            _malformed();
          }
          current.entries.add(_VobEntry(time, pos));
        case 'delay':
          delay = clock(value, signed: true);
          if (embedded && delay != 0) _unsupported();
        case 'langidx':
          if (!settings.add(key) || !RegExp(r'^\d{1,2}$').hasMatch(value)) {
            _malformed();
          }
          preferred = int.parse(value);
          if (preferred! > 31) _limit();
        case 'alt':
          if (current == null) {
            _malformed(); // Label only; public metadata is caller-owned.
          }
        default:
          final neutral = switch (key) {
            'org' => value == '0, 0' || value == '0,0',
            'scale' => RegExp(r'^100%,\s*100%$').hasMatch(value),
            'alpha' => value == '100%',
            'smooth' || 'forced subs' => value.toUpperCase() == 'OFF',
            'fadein/out' => RegExp(r'^0,\s*0$').hasMatch(value),
            'align' => value.toUpperCase() == 'OFF AT LEFT TOP',
            'time offset' => value == '0',
            'custom colors' => RegExp(
              r'^OFF(?:,|$)',
              caseSensitive: false,
            ).hasMatch(value),
            _ => false,
          };
          if (!neutral) _unsupported();
      }
    }
    if (width == 0 ||
        palette == null ||
        (!embedded && (streams.isEmpty || entries == 0))) {
      _malformed();
    }
    if (preferred != null && !streams.containsKey(preferred)) _malformed();
  }

  static int clock(String value, {bool signed = false}) {
    final m = RegExp(
      signed
          ? r'^([+-]?)(\d{2,3}):(\d{2}):(\d{2}):(\d{3})$'
          : r'^()(\d{2,3}):(\d{2}):(\d{2}):(\d{3})$',
    ).firstMatch(value);
    if (m == null) _malformed();
    final h = int.parse(m[2]!),
        min = int.parse(m[3]!),
        sec = int.parse(m[4]!),
        ms = int.parse(m[5]!);
    if (min > 59 || sec > 59) _malformed();
    final result = ((h * 60 + min) * 60 + sec) * 1000000 + ms * 1000;
    if (result >= horizon) _limit();
    return m[1] == '-' ? -result : result;
  }

  _VobStream select(String? language) {
    if (language == null) return streams[preferred] ?? streams.values.first;
    final primary = language.toLowerCase().split(RegExp('[-_]')).first;
    final matches = streams.values.where((s) => s.language == primary).toList();
    if (matches.length != 1) _unsupported();
    return matches.single;
  }
}

final class _VobAssembly {
  _VobAssembly(this.pack, this.pes, this.size);
  final int pack, pes, size;
  final data = BytesBuilder(copy: false);
}

/// One linear bounded pass over the PS, avoiding a scan per index entry.
Map<(int, int), Uint8List> _vobPackets(List<int> bytes) {
  final r = _PgsReader(bytes),
      active = <int, _VobAssembly>{},
      result = <(int, int), Uint8List>{};
  var pack = -1, segments = 0, packets = 0;
  while (r.left > 0) {
    if (++segments > 50000) _limit();
    final pos = r.offset;
    if (r.triple() != 1) _malformed();
    final type = r.byte();
    if (type == 0xba) {
      final b = r.take(10);
      if (b[0] & 0xc0 != 0x40) _unsupported();
      if (b[0] & 4 == 0 ||
          b[2] & 4 == 0 ||
          b[4] & 4 == 0 ||
          b[5] & 1 == 0 ||
          b[8] & 3 != 3 ||
          b[9] & 0xf8 != 0xf8) {
        _malformed();
      }
      if (r.take(b[9] & 7).any((v) => v != 255)) _malformed();
      pack = pos;
      continue;
    }
    if (type == 0xb9) {
      if (r.left != 0 || active.isNotEmpty) _malformed();
      break;
    }
    if (pack < 0) _malformed();
    final body = _PgsReader(r.take(r.word()));
    if ([0xbb, 0xbe, 0xbf].contains(type)) continue;
    if (type != 0xbd) _unsupported();
    final flags = body.byte(),
        timing = body.byte(),
        header = body.take(body.byte());
    if (flags & 0xc0 != 0x80) _unsupported();
    if (flags & 0x30 != 0 || timing & 0x3e != 0) _unsupported();
    final timestamps = timing >> 6;
    if (timestamps == 1) _malformed();
    final required = timestamps == 3
        ? 10
        : timestamps == 2
        ? 5
        : 0;
    if (header.length < required) _malformed();
    for (var i = 0; i < required; i += 5) {
      final prefix = i == 5
          ? 1
          : timestamps == 3
          ? 3
          : 2;
      if (header[i] >> 4 != prefix ||
          header[i] & 1 == 0 ||
          header[i + 2] & 1 == 0 ||
          header[i + 4] & 1 == 0) {
        _malformed();
      }
    }
    var consumed = required;
    if (timing & 1 != 0) {
      // Ordinary DVD muxers include this bounded P-STD buffer extension.
      if (header.length <= consumed) _malformed();
      final extension = header[consumed++];
      if (extension & 0x0e != 0x0e) _malformed();
      if (extension & 0xf1 != 0x10) _unsupported();
      if (header.length < consumed + 2 || header[consumed] & 0xc0 != 0x40) {
        _malformed();
      }
      consumed += 2; // Buffer scale/size does not allocate or change cue time.
    }
    if (header.skip(consumed).any((v) => v != 255)) _malformed();
    final stream = body.byte() - 0x20;
    if (stream < 0 || stream > 31) _unsupported();
    var pending = active[stream];
    if (pending == null) {
      if (body.left < 4) _malformed();
      final size = body.bytes[body.offset] * 256 + body.bytes[body.offset + 1];
      if (size == 0) _unsupported();
      if (size < 10) _malformed();
      if (++packets > 10000) _limit();
      pending = _VobAssembly(pack, pos, size);
      active[stream] = pending;
    }
    if (body.left == 0 || pending.data.length + body.left > pending.size) {
      _malformed();
    }
    pending.data.add(body.take(body.left));
    if (pending.data.length == pending.size) {
      final unit = pending.data.takeBytes();
      // filepos convention is pack start; allow exact PES positions as well.
      if (result.containsKey((pending.pack, stream))) _unsupported();
      result[(pending.pack, stream)] = unit;
      result[(pending.pes, stream)] = unit;
      active.remove(stream);
    }
  }
  if (active.isNotEmpty || result.isEmpty) _malformed();
  return result;
}

final class _VobDecoder {
  _VobDecoder(this.index, this.limits);
  final _VobIndex index;
  final SubtitleLimits limits;
  final cues = <SubtitleCue>[];
  int expanded = 0, commands = 0;
  void packet(Uint8List bytes, int base, int until) {
    final header = _PgsReader(bytes);
    if (header.word() != bytes.length) _malformed();
    final control = header.word();
    if (control < 4 || control > bytes.length - 5) _malformed();
    var at = control, priorTime = -1, count = 0;
    List<int>? map, alpha;
    _PgsBox? rect;
    int? even, odd;
    var visible = false, forced = false;
    PgsFrame? prior;
    var priorStart = base;
    void emit(int end) {
      if (prior == null) return;
      final start = math.max(0, priorStart), stop = math.min(until, end);
      if (stop <= start) return;
      if (cues.length >= limits.maxCues) _limit();
      cues.add(
        SubtitleCue._(
          ordinal: cues.length,
          identifier: null,
          start: Duration(microseconds: start),
          end: Duration(microseconds: stop),
          payload: '',
          pgs: prior,
        ),
      );
    }

    while (true) {
      if (++count > 256) _limit();
      final r = _PgsReader(bytes)..offset = at;
      final ticks = r.word(), next = r.word();
      if (ticks < priorTime ||
          next < at ||
          (next != at && next > bytes.length - 5)) {
        _malformed();
      }
      priorTime = ticks;
      final time = base + ticks * 1024 * 1000000 ~/ 90000;
      if (time >= _VobIndex.horizon) _limit();
      emit(time);
      var ended = false;
      while (r.left > 0 && (next == at || r.offset < next)) {
        if (++commands > 50000) _limit();
        final cmd = r.byte();
        if (cmd == 0xff) {
          ended = true;
          break;
        }
        switch (cmd) {
          case 0:
            visible = true;
            forced = true;
          case 1:
            visible = true;
            forced = false;
          case 2:
            visible = false;
          case 3:
            final value = r.word();
            map = [for (var i = 0; i < 4; i++) (value >> (i * 4)) & 15];
          case 4:
            final value = r.word();
            alpha = [
              for (var i = 0; i < 4; i++) ((value >> (i * 4)) & 15) * 17,
            ];
          case 5:
            final x = r.triple(), y = r.triple();
            final x1 = x >> 12, x2 = x & 4095, y1 = y >> 12, y2 = y & 4095;
            if (x2 < x1 || y2 < y1 || x2 >= index.width || y2 >= index.height) {
              _malformed();
            }
            rect = _PgsBox(x1, y1, x2 - x1 + 1, y2 - y1 + 1);
          case 6:
            even = r.word();
            odd = r.word();
          default:
            _unsupported();
        }
      }
      // DVD producers may append one END byte to align an odd-sized SPU.
      // It is allowed only after the self-linked final command sequence.
      if (ended &&
          next == at &&
          r.offset.isOdd &&
          r.left == 1 &&
          bytes[r.offset] == 0xff) {
        r.byte();
      }
      if (!ended || r.offset != (next == at ? bytes.length : next)) {
        _malformed();
      }
      prior = null;
      priorStart = time;
      if (visible) {
        if (map == null ||
            alpha == null ||
            rect == null ||
            even == null ||
            odd == null) {
          _malformed();
        }
        if (rect.w * rect.h > 4 * 1024 * 1024 ||
            expanded + rect.w * rect.h * 4 > limits.maxPgsBitmapBytes) {
          _limit();
        }
        expanded += rect.w * rect.h * 4;
        // Check offsets and budget before either pixel allocation.
        if (even < 4 ||
            even >= control ||
            odd < 4 ||
            odd > control ||
            (rect.h > 1 && (odd == control || odd == even))) {
          _malformed();
        }
        final pixels = Uint8List(rect.w * rect.h);
        field(
          bytes,
          even,
          odd > even ? odd : control,
          rect.w,
          rect.h,
          0,
          pixels,
        );
        if (rect.h > 1) {
          field(
            bytes,
            odd,
            even > odd ? even : control,
            rect.w,
            rect.h,
            1,
            pixels,
          );
        }
        final rgba = Uint8List(pixels.length * 4);
        for (var i = 0; i < pixels.length; i++) {
          final c = index.palette![map[pixels[i]]], a = alpha[pixels[i]];
          rgba[i * 4] = ((c >> 16) * a + 127) ~/ 255;
          rgba[i * 4 + 1] = (((c >> 8) & 255) * a + 127) ~/ 255;
          rgba[i * 4 + 2] = ((c & 255) * a + 127) ~/ 255;
          rgba[i * 4 + 3] = a;
        }
        prior = PgsFrame._(index.width, index.height, [
          PgsBitmap._(rect.x, rect.y, rect.w, rect.h, forced, rgba),
        ]);
      }
      if (next == at) break;
      at = next;
    }
    emit(until);
  }

  void field(
    Uint8List bytes,
    int start,
    int end,
    int w,
    int h,
    int parity,
    Uint8List pixels,
  ) {
    var nib = start * 2;
    int read() {
      if (nib >= end * 2) _malformed();
      final n = (bytes[nib ~/ 2] >> (nib.isEven ? 4 : 0)) & 15;
      nib++;
      return n;
    }

    for (var y = parity; y < h; y += 2) {
      var x = 0;
      while (x < w) {
        var code = read();
        if (code < 4) {
          code = code * 16 + read();
          if (code < 16) {
            code = code * 16 + read();
            if (code < 64) code = code * 16 + read();
          }
        }
        final color = code & 3, run = code < 4 ? w - x : code >> 2;
        if (run == 0 || run > w - x) _malformed();
        pixels.fillRange(y * w + x, y * w + x + run, color);
        x += run;
      }
      if (nib.isOdd && read() != 0) _malformed();
    }
    if (nib != end * 2) _malformed();
  }
}

SubtitleDocument _parseVobSub(
  List<int> sub,
  List<int> idx,
  SubtitleLimits limits,
  String? language,
) {
  final index = _VobIndex(idx), packets = _vobPackets(sub);
  for (final stream in index.streams.values) {
    for (final entry in stream.entries) {
      if (!packets.containsKey((entry.position, stream.index))) _malformed();
    }
  }
  final selected = index.select(language);
  if (selected.entries.isEmpty) _malformed();
  final decoder = _VobDecoder(index, limits);
  for (var i = 0; i < selected.entries.length; i++) {
    final entry = selected.entries[i];
    decoder.packet(
      packets[(entry.position, selected.index)]!,
      entry.time,
      i + 1 < selected.entries.length
          ? selected.entries[i + 1].time
          : _VobIndex.horizon,
    );
  }
  return SubtitleDocument._finish(
    decoder.cues,
    sub.length + idx.length,
    limits,
  );
}

SubtitleDocument _parseEmbeddedVobSub(
  List<EmbeddedVobSubPacket> packets,
  String codecPrivate,
  SubtitleLimits limits,
) {
  final header = utf8.encode(codecPrivate);
  if (header.length > 256 * 1024 || packets.length > 10000) _limit();
  var input = header.length;
  var previous = -1;
  for (final packet in packets) {
    input += packet.bytes.length;
    if (input > limits.maxInputBytes || packet.bytes.length > 65535) _limit();
    final start = packet.start.inMicroseconds, end = packet.end?.inMicroseconds;
    if (start < 0 ||
        start < previous ||
        start >= _VobIndex.horizon ||
        (end != null && (end <= start || end > _VobIndex.horizon))) {
      _malformed();
    }
    previous = start;
  }
  if (input > limits.maxInputBytes) _limit();
  final decoder = _VobDecoder(_VobIndex(header, embedded: true), limits);
  for (var i = 0; i < packets.length; i++) {
    final packet = packets[i];
    final next = i + 1 < packets.length
        ? packets[i + 1].start.inMicroseconds
        : _VobIndex.horizon;
    decoder.packet(
      packet.bytes,
      packet.start.inMicroseconds,
      math.min(packet.end?.inMicroseconds ?? _VobIndex.horizon, next),
    );
  }
  return SubtitleDocument._finish(decoder.cues, input, limits);
}
