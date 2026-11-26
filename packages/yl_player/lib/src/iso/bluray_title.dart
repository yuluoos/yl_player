import 'dart:typed_data';

import 'iso_segment.dart';
import 'udf.dart';

int _u16(Uint8List b, int i) => ByteData.sublistView(b).getUint16(i);
int _u32(Uint8List b, int i) => ByteData.sublistView(b).getUint32(i);
typedef _Item = ({String clip, int start, int end, int stc});
typedef _Point = ({int time, int packet});

// All segments of a clip share the small PAT/PMT prefix and any in-flight read.
final class _Clip {
  _Clip(this.file);
  final DiscFile file;
  Future<Uint8List>? _tables;
  Future<Uint8List> tables({Uint8List? prefix}) =>
      _tables ??= _loadTables(prefix);

  Future<Uint8List> _loadTables(Uint8List? prefix) async {
    try {
      return await _programTables(file, prefix);
    } catch (_) {
      _tables = null;
      rethrow;
    }
  }
}

final class _DiscSegment implements IsoSegment {
  _DiscSegment(this.clip, this.first, this.end, this.ticks, this.discontinuity);
  final _Clip clip;
  final int first, end;
  @override
  final int ticks;
  @override
  final bool discontinuity;
  @override
  Future<IsoPayload> openPayload() async {
    final tables = first == 0 ? Uint8List(0) : await clip.tables();
    return _ClipPayload(clip, first, end, tables);
  }
}

final class _ClipPayload implements IsoPayload {
  _ClipPayload(this.clip, this.first, this.end, this.tables);
  final _Clip clip;
  final int first, end;
  final Uint8List tables;
  @override
  int get length => tables.length + (end - first) * 188;

  /// Strip the four-byte Blu-ray arrival timestamp from each TS packet.
  @override
  Stream<Uint8List> read(int start, int stop) async* {
    if (start < tables.length) {
      yield Uint8List.sublistView(
        tables,
        start,
        stop.clamp(start, tables.length),
      );
      start = tables.length;
    }
    if (stop <= start) return;
    var at = start - tables.length;
    final limit = stop - tables.length;
    var validateClip = first == 0;
    while (at < limit) {
      final packet = at ~/ 188;
      final n = ((limit + 187) ~/ 188 - packet).clamp(1, 2048);
      final raw = await clip.file.read((first + packet) * 192, n * 192);
      if (validateClip) {
        // Packet zero already carries the tables. Use the bytes from this
        // GET when jumping to a new clip instead of a separate HTTP round trip.
        await clip.tables(prefix: packet == 0 ? raw : null);
        validateClip = false;
      }
      final data = Uint8List(n * 188);
      for (var p = 0; p < n; p++) {
        final sync = p * 192 + 4;
        if (raw[sync] != 0x47 || raw[sync + 3] & 0xc0 != 0) invalidDisc();
        data.setRange(p * 188, (p + 1) * 188, raw, sync);
      }
      final within = at % 188,
          count = (limit - at).clamp(0, data.length - within);
      yield Uint8List.sublistView(data, within, within + count);
      at += count;
    }
  }
}

List<_Item> _playlist(Uint8List b) {
  if (String.fromCharCodes(b, 0, 4) != 'MPLS') invalidDisc();
  final list = _u32(b, 8),
      end = list + 4 + _u32(b, list),
      count = _u16(b, list + 6);
  if (end > b.length || count > 2048) invalidDisc();
  var at = list + 10;
  final items = <_Item>[];
  for (var i = 0; i < count; i++) {
    final len = _u16(b, at);
    at += 2;
    if (len < 32 || at + len > end) invalidDisc();
    final clip = String.fromCharCodes(b, at, at + 5);
    if (!RegExp(r'^\d{5}$').hasMatch(clip) ||
        String.fromCharCodes(b, at + 5, at + 9) != 'M2TS') {
      invalidDisc();
    }
    final start = _u32(b, at + 12), stop = _u32(b, at + 16);
    if (stop <= start) invalidDisc();
    items.add((clip: clip, start: start, end: stop, stc: b[at + 11]));
    at += len;
  }
  return items;
}

// The CLPI coarse entry supplies the high bits of both time and source
// packet number. Fine entries identify individual random access points.
// Times here and in MPLS play items use the Blu-ray 45 kHz clock.
List<_Point> _accessPoints(Uint8List b, int packets) {
  final cpi = _u32(b, 16), end = cpi + 4 + _u32(b, cpi);
  if (end > b.length) invalidDisc();
  final base = cpi + 6;
  for (var i = 0; i < b[base + 1]; i++) {
    final at = base + 2 + i * 12;
    if (at + 12 > end) invalidDisc();
    if ((_u32(b, at + 2) >> 18) & 15 != 1) continue;
    final coarse = (_u32(b, at + 2) >> 2) & 0xffff,
        fine = _u32(b, at + 4) & 0x3ffff;
    final table = base + _u32(b, at + 8), fineAt = table + _u32(b, table);
    if (coarse == 0 ||
        fine == 0 ||
        table + 4 + 8 * coarse > fineAt ||
        fineAt + 4 * fine > end) {
      invalidDisc();
    }
    final points = <_Point>[];
    for (var j = 0; j < coarse; j++) {
      final c = table + 4 + j * 8, v = _u32(b, c);
      final first = v >> 14,
          next = j + 1 == coarse ? fine : _u32(b, c + 8) >> 14;
      if ((j == 0 && first != 0) || next <= first || next > fine) invalidDisc();
      for (var k = first; k < next; k++) {
        final bits = _u32(b, fineAt + k * 4);
        final time = ((v & 0x3ffe) << 18) | (((bits >> 17) & 0x7ff) << 8);
        final packet = (_u32(b, c + 4) & 0xfffe0000) | (bits & 0x1ffff);
        if (packet >= packets ||
            points.isNotEmpty &&
                (packet <= points.last.packet || time < points.last.time)) {
          invalidDisc();
        }
        points.add((time: time, packet: packet));
      }
    }
    return points;
  }
  return invalidDisc();
}

// A fresh HLS segment must announce its program before its first video PES.
// Blu-ray uses a single program. Keep its original PAT and PMT packets.
Future<Uint8List> _programTables(DiscFile file, Uint8List? initial) async {
  final limit = (file.length ~/ 192).clamp(0, 512) * 192;
  final prefix = initial == null
      ? await file.read(0, limit.clamp(0, 16 * 192), readAhead: false)
      : Uint8List.sublistView(initial, 0, initial.length.clamp(0, limit));
  final tables = _findProgramTables(prefix);
  if (tables != null) return tables;
  if (prefix.length == limit) invalidDisc();
  final bytes = Uint8List(limit)..setAll(0, prefix);
  bytes.setAll(
    prefix.length,
    await file.read(prefix.length, limit - prefix.length),
  );
  return _findProgramTables(bytes) ?? invalidDisc();
}

Uint8List? _findProgramTables(Uint8List bytes) {
  Uint8List? pat;
  int? pmt;
  for (var i = 4; i + 188 <= bytes.length; i += 192) {
    if (bytes[i] != 0x47) invalidDisc();
    final pid = ((bytes[i + 1] & 31) << 8) | bytes[i + 2];
    if (bytes[i + 1] & 64 == 0 || bytes[i + 3] & 16 == 0) continue;
    var off = i + 4;
    if (bytes[i + 3] & 32 != 0) off += 1 + bytes[off];
    if (off >= i + 188) continue;
    off += 1 + bytes[off];
    if (off + 3 > i + 188) continue;
    final sectionEnd = off + 3 + (_u16(bytes, off + 1) & 4095);
    if (pid == 0 && bytes[off] == 0 && sectionEnd <= i + 188) {
      for (var j = off + 8; j + 4 <= sectionEnd - 4; j += 4) {
        if (_u16(bytes, j) == 0) continue;
        pmt = _u16(bytes, j + 2) & 8191;
        pat = Uint8List.sublistView(bytes, i, i + 188);
        break;
      }
    } else if (pid == pmt && pat != null && bytes[off] == 2) {
      final result = BytesBuilder()
        ..add(pat)
        ..add(Uint8List.sublistView(bytes, i, i + 188));
      var missing = sectionEnd - (i + 188);
      for (var j = i + 192; missing > 0 && j + 188 <= bytes.length; j += 192) {
        if (((_u16(bytes, j + 1)) & 8191) != pmt || bytes[j + 3] & 16 == 0) {
          continue;
        }
        if (bytes[j + 1] & 64 != 0) invalidDisc();
        result.add(Uint8List.sublistView(bytes, j, j + 188));
        missing -= 184 - (bytes[j + 3] & 32 != 0 ? 1 + bytes[j + 4] : 0);
      }
      if (missing > 0) return null;
      return result.takeBytes();
    }
  }
  return null;
}

Future<List<IsoSegment>> openMainTitle(
  UdfVolume volume, {
  int? playlist,
}) async {
  final root = await volume.directory(volume.root);
  if (root.containsKey('AACS') || root.containsKey('BDSVM')) invalidDisc();
  final bd = await volume.directory(await volume.child(root, 'BDMV'));
  final playlists = await volume.directory(await volume.child(bd, 'PLAYLIST'));
  final clips = await volume.directory(await volume.child(bd, 'CLIPINF'));
  final streams = await volume.directory(await volume.child(bd, 'STREAM'));
  final names = playlists.keys.where(RegExp(r'^\d{5}\.MPLS$').hasMatch).toList()
    ..sort();
  if (names.length > 2048) invalidDisc();
  var best = <_Item>[], duration = 0, metadataBytes = 0;
  for (final name in names) {
    if (playlist != null && int.parse(name.substring(0, 5)) != playlist) {
      continue;
    }
    final playlistFile = await volume.child(playlists, name);
    metadataBytes += playlistFile.length;
    if (metadataBytes > 32 * 1024 * 1024) invalidDisc();
    final bytes = await playlistFile.metadata();
    List<_Item> items;
    try {
      items = _playlist(bytes);
    } on FormatException {
      if (playlist != null) rethrow;
      continue;
    } on RangeError {
      if (playlist != null) rethrow;
      continue;
    }
    final ticks = items.fold(0, (v, p) => v + p.end - p.start);
    if (ticks > duration) {
      duration = ticks;
      best = items;
    }
  }
  final segments = <IsoSegment>[];
  final byClip = <String, _Clip>{};
  for (final item in best) {
    final file = await volume.child(streams, '${item.clip}.M2TS');
    final clipInfo = await volume.child(clips, '${item.clip}.CLPI');
    metadataBytes += clipInfo.length;
    if (metadataBytes > 64 * 1024 * 1024) invalidDisc();
    final info = await clipInfo.metadata();
    if (String.fromCharCodes(info, 0, 4) != 'HDMV' || file.length % 192 != 0) {
      invalidDisc();
    }
    final seq = _u32(info, 8);
    if (info[seq + 5] != 1 ||
        info[seq + 10] != 1 ||
        info[seq + 11] != item.stc) {
      invalidDisc();
    }
    final packets = file.length ~/ 192;
    final points = _accessPoints(info, packets);
    int boundary(int time) {
      for (final point in points) {
        if (point.time <= time && time - point.time < 256) return point.packet;
      }
      return invalidDisc(); // A cut inside a GOP needs a frame-accurate remux.
    }

    final first = item.start == _u32(info, seq + 18) ? 0 : boundary(item.start);
    final last = item.end == _u32(info, seq + 22)
        ? packets
        : boundary(item.end);
    if (first >= last) invalidDisc();
    final clip = byClip.putIfAbsent(item.clip, () => _Clip(file));
    if (segments.isEmpty) await clip.tables();
    var start = first, time = item.start, discontinuous = segments.isNotEmpty;
    void emit(int packet, int until) {
      if (segments.length >= 100000) invalidDisc();
      segments.add(
        _DiscSegment(clip, start, packet, until - time, discontinuous),
      );
      start = packet;
      time = until;
      discontinuous = false;
    }

    for (final point in points) {
      if (point.packet > start &&
          point.packet < last &&
          point.time < item.end &&
          point.time - time >= 4 * 45000) {
        emit(point.packet, point.time);
      }
    }
    emit(last, item.end);
  }
  if (segments.isEmpty) invalidDisc();
  return segments;
}
