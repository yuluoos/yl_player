import 'dart:typed_data';

import 'dvd_transport.dart';
import 'iso_segment.dart';
import 'udf.dart';

const _sector = 2048;
int _u16(Uint8List b, int i) => ByteData.sublistView(b).getUint16(i);
int _u32(Uint8List b, int i) => ByteData.sublistView(b).getUint32(i);
int _tableOffset(Uint8List b, int pointer) {
  final at = _u32(b, pointer) * _sector;
  if (at == 0 || at + 8 > b.length) invalidDisc();
  return at;
}

int _tableEnd(Uint8List b, int table) {
  final end = table + _u32(b, table + 4) + 1;
  if (end < table + 8 || end > b.length) invalidDisc();
  return end;
}

String _prefix(int set) => 'VTS_${set.toString().padLeft(2, '0')}';

typedef _Cell = ({int first, int lastNav, int last, int ticks});
typedef _Title = ({
  int set,
  Uint8List ifo,
  List<_Cell> cells,
  DvdAudio? audio,
  bool mpeg1,
});

int _time(Uint8List b, int i) {
  int bcd(int v) {
    if ((v & 15) > 9 || v >> 4 > 9) invalidDisc();
    return (v >> 4) * 10 + (v & 15);
  }

  final minutes = bcd(b[i + 1]), seconds = bcd(b[i + 2]);
  if (minutes > 59 || seconds > 59) invalidDisc();
  final frames = bcd(b[i + 3] & 63), rate = b[i + 3] >> 6;
  if (rate != 1 && rate != 3 || frames >= (rate == 1 ? 25 : 30)) invalidDisc();
  return (bcd(b[i]) * 3600 + minutes * 60 + seconds) * 90000 +
      frames * (rate == 1 ? 3600 : 3003);
}

// Follow VMG title number -> VTS part-of-title table -> PGC -> program/cells.
// VM-command navigation and interleaved angles require a DVD virtual machine.
_Title? _title(Uint8List b, int set, int title, int chapters) {
  if (String.fromCharCodes(b, 0, 12) != 'DVDVIDEO-VTS') invalidDisc();
  final parts = _tableOffset(b, 0xc8), chains = _tableOffset(b, 0xcc);
  if (title < 1 || title > _u16(b, parts) || chapters < 1) invalidDisc();
  final ptt = parts + _u32(b, parts + 8 + (title - 1) * 4);
  final limit = title == _u16(b, parts)
      ? _tableEnd(b, parts)
      : parts + _u32(b, parts + 8 + title * 4);
  if (ptt < parts + 8 + 4 * _u16(b, parts) ||
      ptt + chapters * 4 > limit ||
      limit > _tableEnd(b, parts)) {
    invalidDisc();
  }
  final pgcn = _u16(b, ptt), chainCount = _u16(b, chains);
  final headerEnd = chains + 8 + chainCount * 8;
  var end = _tableEnd(b, chains);
  if (pgcn < 1 || pgcn > chainCount || headerEnd > end) invalidDisc();
  final pgc = chains + _u32(b, chains + 8 + (pgcn - 1) * 8 + 4);
  // Program chains share the table. Keep each offset within its own chain.
  for (var i = 0; i < chainCount; i++) {
    final other = chains + _u32(b, chains + 12 + i * 8);
    if (other > pgc && other < end) end = other;
  }
  if (pgc < headerEnd || pgc + 236 > end) invalidDisc();
  if (b[pgc + 162] != 0 || b[pgc + 163] != 0) return null;
  final programs = b[pgc + 2], count = b[pgc + 3];
  final map = pgc + _u16(b, pgc + 230), firstCell = pgc + _u16(b, pgc + 232);
  if (programs == 0 ||
      count == 0 ||
      map < pgc + 236 ||
      map + programs > end ||
      firstCell < pgc + 236 ||
      firstCell + 24 * count > end) {
    invalidDisc();
  }
  // Only complete, sequential program chains are supported. Titles sharing
  // this PGC can describe different slices of its cells.
  for (var other = 1; other <= _u16(b, parts); other++) {
    if (other == title) continue;
    final entry = parts + _u32(b, parts + 8 + (other - 1) * 4);
    if (entry + 4 > _tableEnd(b, parts)) invalidDisc();
    if (_u16(b, entry) == pgcn) return null;
  }
  if (_u16(b, ptt + 2) != 1 || b[map] != 1) return null;
  var prev = 0;
  for (int c = 0; c < chapters; c++) {
    final p = _u16(b, ptt + c * 4 + 2);
    if (_u16(b, ptt + c * 4) != pgcn || p <= prev || p > programs) return null;
    prev = p;
  }
  final cells = <_Cell>[];
  for (int c = 0; c < count; c++) {
    final at = firstCell + c * 24;
    if (b[at] & 0xf5 != 0 ||
        b[at + 1] & 0x40 != 0 ||
        b[at + 2] != 0 ||
        b[at + 3] != 0) {
      return null;
    }
    final first = _u32(b, at + 8),
        lastNav = _u32(b, at + 16),
        last = _u32(b, at + 20);
    if (first > lastNav || lastNav > last) invalidDisc();
    cells.add((
      first: first,
      lastNav: lastNav,
      last: last,
      ticks: _time(b, at + 4),
    ));
  }
  DvdAudio? audio;
  final nAudio = _u16(b, 0x202);
  if (nAudio > 8) invalidDisc();
  for (var i = 0; i < nAudio; i++) {
    final control = _u16(b, pgc + 12 + 2 * i);
    if (control & 0x8000 == 0) continue;
    final stream = (control >> 8) & 7;
    final coding = b[0x204 + 8 * i] >> 5;
    if (coding == 0) {
      audio = (stream: 0x80 + stream, ac3: true);
      break;
    }
    if (coding == 2 || coding == 3) {
      audio = (stream: 0xc0 + stream, ac3: false);
      break;
    }
  }
  if (nAudio > 0 && audio == null) return null;
  final video = b[0x200] >> 6;
  if (video > 1) return null;
  return (set: set, ifo: b, cells: cells, audio: audio, mpeg1: video == 0);
}

final class _Vobs {
  _Vobs(this.files);
  final List<DiscFile> files;
  Future<Uint8List> read(int first, int count, {bool readAhead = true}) async {
    var off = first * _sector, remaining = count;
    final builder = BytesBuilder(copy: false);
    for (final file in files) {
      if (off >= file.length) {
        off -= file.length;
        continue;
      }
      final n = remaining.clamp(0, file.length - off);
      builder.add(await file.read(off, n, readAhead: readAhead));
      remaining -= n;
      if (remaining == 0) return builder.takeBytes();
      off = 0;
    }
    return invalidDisc();
  }

  Future<({int start, int end})> clock(int sector) async {
    // Only the PCI prefix contains the clock. Sparse NAV packs in a feature
    // can be megabytes apart, so fetching a metadata page per pack wastes I/O.
    final nav = await read(sector, 65, readAhead: false);
    // PCI follows the 14-byte pack and system header. Its presentation
    // interval is expressed in the DVD 90 kHz clock.
    if (_u32(nav, 38) != 0x1bf ||
        _u16(nav, 42) != 0x3d4 ||
        nav[44] != 0 ||
        _u32(nav, 45) != sector) {
      invalidDisc();
    }
    return (start: _u32(nav, 57), end: _u32(nav, 61));
  }
}

final class _Payload implements IsoPayload {
  _Payload(this.bytes);
  final Uint8List bytes;
  @override
  int get length => bytes.length;
  @override
  Stream<Uint8List> read(int start, int stop) async* {
    yield Uint8List.sublistView(bytes, start, stop);
  }
}

final class _Segment implements IsoSegment {
  _Segment(
    this.vobs,
    this.first,
    this.stop,
    this.ticks,
    this.discontinuity,
    this.audio,
    this.mpeg1,
    this.clockOffset,
  );
  final _Vobs vobs;
  final int first, stop;
  @override
  final int ticks;
  @override
  final bool discontinuity;
  final DvdAudio? audio;
  final bool mpeg1;
  final int clockOffset;
  @override
  Future<IsoPayload> openPayload({bool fullNetworkRead = false}) async {
    final mux = DvdTransport(audio, clockOffset, mpeg1: mpeg1);
    for (var i = first; i < stop; i += 256) {
      mux.addSectors(await vobs.read(i, (stop - i).clamp(1, 256) * _sector));
    }
    return _Payload(mux.finish());
  }
}

Future<List<IsoSegment>> openDvdTitle(
  UdfVolume volume,
  UdfAddress directory, {
  int? number,
}) async {
  final files = await volume.directory(await volume.file(directory));
  final manager = await (await volume.child(files, 'VIDEO_TS.IFO')).metadata();
  if (String.fromCharCodes(manager, 0, 12) != 'DVDVIDEO-VMG') invalidDisc();
  final titles = _tableOffset(manager, 0xc4), count = _u16(manager, titles);
  if (count < 1 ||
      count > 99 ||
      titles + 8 + count * 12 > _tableEnd(manager, titles)) {
    invalidDisc();
  }
  _Title? best;
  var longest = 0, cachedSet = 0, metadataBytes = 0;
  Uint8List? ifo;
  for (var i = 1; i <= count; i++) {
    if (number != null && i != number) continue;
    final at = titles + 8 + (i - 1) * 12, set = manager[at + 6];
    if (manager[at] & 0x40 != 0 || manager[at + 1] != 1) continue;
    if (set < 1 || set > 99) invalidDisc();
    if (set != cachedSet) {
      final file = await volume.child(files, '${_prefix(set)}_0.IFO');
      metadataBytes += file.length;
      if (metadataBytes > 64 * 1024 * 1024) invalidDisc();
      ifo = await file.metadata();
      cachedSet = set;
    }
    final candidate = _title(ifo!, set, manager[at + 7], _u16(manager, at + 2));
    if (candidate == null) continue;
    final duration = candidate.cells.fold(0, (v, c) => v + c.ticks);
    if (duration > longest) {
      longest = duration;
      best = candidate;
    }
  }
  if (best == null) invalidDisc();
  final title = best;
  final vobs = <DiscFile>[];
  for (var i = 1; i <= 9; i++) {
    final address = files['${_prefix(title.set)}_$i.VOB'];
    if (address == null) break;
    final f = await volume.file(address);
    if (f.length % _sector != 0) invalidDisc();
    vobs.add(f);
  }
  final source = _Vobs(vobs);
  final sectors = vobs.fold(0, (n, v) => n + v.length ~/ _sector);
  final b = title.ifo, map = _tableOffset(b, 0xe4);
  final size = _u32(b, map) + 1;
  if (size < 8 || size % 4 != 0 || map + size > b.length) invalidDisc();
  final units = <int>[];
  for (int at = map + 4; at < map + size; at += 4) {
    final sector = _u32(b, at);
    if (sector >= sectors || units.isNotEmpty && units.last >= sector) {
      invalidDisc();
    }
    units.add(sector);
  }
  final segments = <IsoSegment>[];
  var elapsed = 0;
  for (final cell in title.cells) {
    var low = 0, high = units.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (units[mid] < cell.first) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    if (low == units.length || units[low] != cell.first) invalidDisc();
    if (cell.last >= sectors) invalidDisc();
    final starts = <int>[];
    var index = low;
    while (index < units.length && units[index] <= cell.lastNav) {
      final first = units[index];
      starts.add(first);
      if (segments.length + starts.length > 100000) invalidDisc();
      // Keep the first segment of each cell short. Later segments can cover
      // more VOBUs within the same sector budget, reducing sparse NAV reads.
      final maxUnits = starts.length == 1 ? 8 : 16;
      var next = index + 1;
      while (next < units.length &&
          units[next] <= cell.lastNav &&
          next - index < maxUnits &&
          units[next] - first < 2048) {
        next++;
      }
      index = next;
    }
    if (units[index - 1] != cell.lastNav) invalidDisc();
    // Read only the navigation pack at each segment boundary. Bound parallel
    // range requests so network startup does not incur one RTT per segment.
    final boundaries = [
      ...starts,
      if (starts.last != cell.lastNav) cell.lastNav,
    ];
    final clocks = <({int start, int end})>[];
    for (var i = 0; i < boundaries.length; i += 4) {
      clocks.addAll(
        await Future.wait(boundaries.skip(i).take(4).map(source.clock)),
      );
    }
    final offset = 180000 + elapsed - clocks.first.start;
    for (var i = 0; i < starts.length; i++) {
      final last = i + 1 == starts.length;
      final stop = last ? cell.last + 1 : starts[i + 1];
      if (stop <= starts[i] || stop - starts[i] > 4096) invalidDisc();
      final end = last ? clocks.last.end : clocks[i + 1].start;
      final duration = (end - clocks[i].start) & 0xffffffff;
      if (duration == 0 || duration > 90000 * 30) invalidDisc();
      final ticks = ((elapsed + duration) ~/ 2) - (elapsed ~/ 2);
      segments.add(
        _Segment(
          source,
          starts[i],
          stop,
          ticks,
          segments.isNotEmpty && i == 0,
          title.audio,
          title.mpeg1,
          offset,
        ),
      );
      elapsed += duration;
    }
  }
  if (segments.isEmpty) invalidDisc();
  return segments;
}
