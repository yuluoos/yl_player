import 'dart:typed_data';

typedef ReadBytes = Future<Uint8List> Function(int offset, int count);
typedef _Extent = ({int offset, int length});
typedef UdfAddress = ({int partition, int block});

Never invalidDisc() =>
    throw const FormatException('Invalid or unsupported disc image');
int _le16(Uint8List b, int i) =>
    ByteData.sublistView(b).getUint16(i, Endian.little);
int _le32(Uint8List b, int i) =>
    ByteData.sublistView(b).getUint32(i, Endian.little);
UdfAddress _address(Uint8List b, int i) =>
    (block: _le32(b, i + 4), partition: _le16(b, i + 8));

/// Maps a UDF file, including fragmented files, onto physical image ranges.
final class DiscFile {
  DiscFile._(this._read, this.length, this._extents);
  final ReadBytes _read;
  final int length;
  final List<_Extent> _extents;

  Iterable<_Extent> _ranges(int offset, int count) sync* {
    if (offset < 0 || count < 0 || offset > length - count) invalidDisc();
    for (final extent in _extents) {
      if (count == 0) return;
      if (offset >= extent.length) {
        offset -= extent.length;
        continue;
      }
      final n = count.clamp(0, extent.length - offset);
      yield (offset: extent.offset + offset, length: n);
      count -= n;
      offset = 0;
    }
    if (count != 0) invalidDisc();
  }

  Future<Uint8List> read(int offset, int count) async {
    final bytes = BytesBuilder(copy: false);
    for (final span in _ranges(offset, count)) {
      bytes.add(await _read(span.offset, span.length));
    }
    return bytes.takeBytes();
  }

  Future<Uint8List> metadata() {
    if (length > 4 * 1024 * 1024) invalidDisc();
    return read(0, length);
  }
}

final class UdfVolume {
  UdfVolume._(this._read, this._size);
  final ReadBytes _read;
  final int _size;
  static const _block = 2048;
  final _maps = <int, DiscFile>{};
  late final DiscFile root;

  static Future<UdfVolume> open(ReadBytes read, int size) async {
    final udf = UdfVolume._(read, size);
    await udf._mount();
    return udf;
  }

  // The anchor points to the ECMA-167 volume descriptor sequence. A type 1
  // partition maps directly to image sectors. UDF 2.50 type 2 metadata maps
  // use a file in a physical partition to locate the file set and directories.
  Future<void> _mount() async {
    final anchor = await _read(256 * _block, _block);
    if (_le16(anchor, 0) != 2) invalidDisc();
    final start = _le32(anchor, 20);
    final count = _le32(anchor, 16) ~/ _block;
    if (count < 1 || count > 256) invalidDisc();
    final partitions = <int, DiscFile>{};
    Uint8List? logical;
    for (var i = 0; i < count; i++) {
      final b = await _read((start + i) * _block, _block);
      final type = _le16(b, 0);
      if (type == 8) break;
      if (type == 6) logical = b;
      if (type == 5) {
        final offset = _le32(b, 188) * _block, length = _le32(b, 192) * _block;
        if (offset > _size - length) invalidDisc();
        partitions[_le16(b, 22)] = DiscFile._(_read, length, [
          (offset: offset, length: length),
        ]);
      }
    }
    final b = logical;
    if (b == null || _le32(b, 212) != _block) invalidDisc();
    final end = 440 + _le32(b, 264);
    if (end > b.length || _le32(b, 268) > 32) invalidDisc();
    final metadata = <int, ({int number, int block})>{};
    for (int i = 0, at = 440; i < _le32(b, 268); i++) {
      if (at + 2 > end) invalidDisc();
      final len = b[at + 1];
      if (len < 6 || at + len > end) invalidDisc();
      if (b[at] == 1 && len == 6) {
        _maps[i] = partitions[_le16(b, at + 4)] ?? invalidDisc();
      } else if (b[at] == 2 &&
          len == 64 &&
          String.fromCharCodes(b, at + 5, at + 28) ==
              '*UDF Metadata Partition') {
        metadata[i] = (number: _le16(b, at + 38), block: _le32(b, at + 40));
      } else {
        invalidDisc();
      }
      at += len;
    }
    for (final e in metadata.entries) {
      final backing = partitions[e.value.number] ?? invalidDisc();
      final physical = _maps.entries
          .firstWhere((p) => identical(p.value, backing), orElse: invalidDisc)
          .key;
      _maps[e.key] = await file((partition: physical, block: e.value.block));
    }
    final fsd = await _sector(_address(b, 248));
    if (_le16(fsd, 0) != 256) invalidDisc();
    root = await file(_address(fsd, 400));
  }

  Future<Uint8List> _sector(UdfAddress a) =>
      (_maps[a.partition] ?? invalidDisc()).read(a.block * _block, _block);

  Future<DiscFile> file(UdfAddress address) async {
    var b = await _sector(address);
    final tag = _le16(b, 0);
    if (tag != 261 && tag != 266) invalidDisc();
    final size = ByteData.sublistView(b).getUint64(56, Endian.little);
    if (size < 0 || size > _size) invalidDisc();
    // File Entry and Extended File Entry have different fixed header sizes.
    // The two lengths immediately before the variable area describe extended
    // attributes and allocation descriptors, respectively.
    final base = tag == 261 ? 176 : 216;
    var at = base + _le32(b, base - 8), end = at + _le32(b, base - 4);
    final format = _le16(b, 34) & 7;
    if (end > b.length || at > end) invalidDisc();
    if (format == 3) {
      if (size > end - at) invalidDisc();
      final data = Uint8List.sublistView(b, at, at + size);
      return DiscFile._(
        (i, n) async => Uint8List.sublistView(data, i, i + n),
        size,
        [(offset: 0, length: size)],
      );
    }
    if (format > 1) invalidDisc();
    final stride = format == 0 ? 8 : 16;
    final spans = <_Extent>[];
    final visited = <UdfAddress>{};
    var allocated = 0;
    while (at < end) {
      if (at + stride > end || spans.length > 65536) invalidDisc();
      final encoded = _le32(b, at), len = encoded & 0x3fffffff;
      final target = (
        block: _le32(b, at + 4),
        partition: format == 0 ? address.partition : _le16(b, at + 8),
      );
      at += stride;
      if (encoded >> 30 == 3) {
        if (at != end || visited.length >= 512 || !visited.add(target)) {
          invalidDisc();
        }
        b = await _sector(target);
        if (_le16(b, 0) != 258) invalidDisc();
        at = 24;
        end = at + _le32(b, 20);
        if (end > b.length) invalidDisc();
        continue;
      }
      if (encoded >> 30 != 0) invalidDisc();
      final partition = _maps[target.partition] ?? invalidDisc();
      spans.addAll(partition._ranges(target.block * _block, len));
      allocated += len;
    }
    if (allocated < size) invalidDisc();
    return DiscFile._(_read, size, spans);
  }

  Future<Map<String, UdfAddress>> directory(DiscFile dir) async {
    final b = await dir.metadata();
    final entries = <String, UdfAddress>{};
    for (var at = 0; at < b.length;) {
      if (at + 38 > b.length || _le16(b, at) != 257) invalidDisc();
      final len = b[at + 19], name = at + 38 + _le16(b, at + 36);
      if (name + len > b.length) invalidDisc();
      if ((b[at + 18] & 12) == 0 && len > 0) {
        final units = <int>[];
        if (b[name] == 8) {
          units.addAll(b.getRange(name + 1, name + len));
        } else if (b[name] == 16 && len.isOdd) {
          for (var i = name + 1; i < name + len; i += 2) {
            units.add((b[i] << 8) | b[i + 1]);
          }
        } else {
          invalidDisc();
        }
        entries[String.fromCharCodes(units).toUpperCase()] = _address(
          b,
          at + 20,
        );
      }
      at = (name + len + 3) & ~3;
    }
    return entries;
  }

  Future<DiscFile> child(Map<String, UdfAddress> parent, String name) =>
      file(parent[name] ?? invalidDisc());
}
