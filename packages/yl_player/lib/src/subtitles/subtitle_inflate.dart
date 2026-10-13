import 'dart:typed_data';
import 'subtitle_document.dart';

Never _bad() =>
    throw const SubtitleParseException(SubtitleParseReason.malformed);
Never _limit() =>
    throw const SubtitleParseException(SubtitleParseReason.limitExceeded);

/// Strict single RFC1950 stream for a bounded Matroska subtitle block.
/// No preset dictionaries, gzip, concatenated streams or trailing bytes.
/// Checks every literal/copy before growing output; never inflates then truncates.
Uint8List inflateSubtitle(List<int> bytes, int maxOutput) {
  if (maxOutput < 0 || maxOutput > 256 * 1024) _limit();
  if (bytes.length < 6 || bytes.any((b) => b < 0 || b > 255)) _bad();
  final cmf = bytes[0], flg = bytes[1];
  if (cmf & 15 != 8 || cmf >> 4 > 7 || (cmf * 256 + flg) % 31 != 0) _bad();
  if (flg & 32 != 0) {
    throw const SubtitleParseException(SubtitleParseReason.unsupported);
  }
  final r = _Bits(bytes, bytes.length - 4)..bit = 16;
  var output = Uint8List(maxOutput < 4096 ? maxOutput : 4096), used = 0;
  void reserve(int n) {
    if (used + n > maxOutput) _limit();
    if (used + n <= output.length) return;
    final grow = (output.length * 2).clamp(used + n, maxOutput);
    final next = Uint8List(grow)..setRange(0, used, output);
    output = next;
  }

  var finalBlock = false, blocks = 0;
  while (!finalBlock) {
    if (++blocks > 10000) _limit();
    finalBlock = r.read(1) == 1;
    final type = r.read(2);
    if (type == 3) _bad();
    if (type == 0) {
      r.align();
      final n = r.read(16), inverse = r.read(16);
      if (n ^ inverse != 65535) _bad();
      reserve(n);
      for (var i = 0; i < n; i++) {
        output[used++] = r.read(8);
      }
      continue;
    }
    late _Huffman literals, distances;
    if (type == 1) {
      literals = _Huffman([
        for (var i = 0; i < 288; i++)
          i < 144
              ? 8
              : i < 256
              ? 9
              : i < 280
              ? 7
              : 8,
      ]);
      distances = _Huffman(List.filled(32, 5));
    } else {
      final nl = r.read(5) + 257, nd = r.read(5) + 1, nc = r.read(4) + 4;
      if (nl > 286) _bad();
      // Code-length alphabet order from RFC1951 (19 symbols).
      const codeOrder = [
        16,
        17,
        18,
        0,
        8,
        7,
        9,
        6,
        10,
        5,
        11,
        4,
        12,
        3,
        13,
        2,
        14,
        1,
        15,
      ];
      final sizes = List.filled(19, 0);
      for (var i = 0; i < nc; i++) {
        sizes[codeOrder[i]] = r.read(3);
      }
      final codes = _Huffman(sizes, complete: true);
      final lengths = <int>[];
      while (lengths.length < nl + nd) {
        final value = codes.decode(r);
        if (value <= 15) {
          lengths.add(value);
          continue;
        }
        int repeat, length;
        if (value == 16) {
          if (lengths.isEmpty) _bad();
          repeat = r.read(2) + 3;
          length = lengths.last;
        } else if (value == 17) {
          repeat = r.read(3) + 3;
          length = 0;
        } else if (value == 18) {
          repeat = r.read(7) + 11;
          length = 0;
        } else {
          return _bad();
        }
        if (lengths.length + repeat > nl + nd) _bad();
        lengths.addAll(List.filled(repeat, length));
      }
      if (lengths[256] == 0) _bad();
      literals = _Huffman(lengths.sublist(0, nl));
      distances = _Huffman(lengths.sublist(nl), emptyAllowed: true);
    }
    while (true) {
      final symbol = literals.decode(r);
      if (symbol == 256) break;
      if (symbol < 256) {
        reserve(1);
        output[used++] = symbol;
        continue;
      }
      if (symbol > 285) _bad();
      final li = symbol - 257;
      final length = _lengthBase[li] + r.read(_lengthExtra[li]);
      final di = distances.decode(r);
      if (di >= 30) _bad();
      final distance = _distanceBase[di] + r.read(_distanceExtra[di]);
      if (distance > used || distance > (1 << (8 + (cmf >> 4)))) _bad();
      reserve(length);
      for (var i = 0; i < length; i++) {
        output[used] = output[used - distance];
        used++;
      }
    }
  }
  r.align();
  if (r.bit ~/ 8 != bytes.length - 4) _bad();
  var a = 1, b = 0;
  for (var i = 0; i < used; i++) {
    a = (a + output[i]) % 65521;
    b = (b + a) % 65521;
  }
  final n = bytes.length;
  final checksum =
      bytes[n - 4] * 16777216 +
      bytes[n - 3] * 65536 +
      bytes[n - 2] * 256 +
      bytes[n - 1];
  if (b * 65536 + a != checksum) _bad();
  return Uint8List.fromList(output.sublist(0, used));
}

final class _Bits {
  _Bits(this.bytes, this.end);
  final List<int> bytes;
  final int end;
  int bit = 0;
  int read(int count) {
    if (bit + count > end * 8) _bad();
    var result = 0;
    for (var i = 0; i < count; i++, bit++) {
      result |= ((bytes[bit ~/ 8] >> (bit % 8)) & 1) << i;
    }
    return result;
  }

  void align() => bit = (bit + 7) & ~7;
}

final class _Huffman {
  _Huffman(
    List<int> lengths, {
    bool complete = false,
    bool emptyAllowed = false,
  }) {
    final counts = List.filled(16, 0);
    for (final n in lengths) {
      if (n < 0 || n > 15) _bad();
      counts[n]++;
      if (n > max) max = n;
    }
    if (max == 0) {
      if (!emptyAllowed) _bad();
      return;
    }
    var left = 1;
    for (var bits = 1; bits <= 15; bits++) {
      left = left * 2 - counts[bits];
      if (left < 0) _bad();
    }
    if (left > 0 && (complete || max != 1)) _bad();
    final next = List.filled(16, 0);
    var code = 0;
    for (var bits = 1; bits <= 15; bits++) {
      code = (code + (bits == 1 ? 0 : counts[bits - 1])) << 1;
      next[bits] = code;
    }
    for (var symbol = 0; symbol < lengths.length; symbol++) {
      final n = lengths[symbol];
      if (n > 0) table[(1 << n) | next[n]++] = symbol;
    }
  }
  final table = <int, int>{};
  int max = 0;
  int decode(_Bits r) {
    var code = 0;
    for (var n = 1; n <= max; n++) {
      code = (code << 1) | r.read(1);
      final symbol = table[(1 << n) | code];
      if (symbol != null) return symbol;
    }
    return _bad();
  }
}

const _lengthBase = [
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  13,
  15,
  17,
  19,
  23,
  27,
  31,
  35,
  43,
  51,
  59,
  67,
  83,
  99,
  115,
  131,
  163,
  195,
  227,
  258,
];
const _lengthExtra = [
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  1,
  1,
  1,
  1,
  2,
  2,
  2,
  2,
  3,
  3,
  3,
  3,
  4,
  4,
  4,
  4,
  5,
  5,
  5,
  5,
  0,
];
const _distanceBase = [
  1,
  2,
  3,
  4,
  5,
  7,
  9,
  13,
  17,
  25,
  33,
  49,
  65,
  97,
  129,
  193,
  257,
  385,
  513,
  769,
  1025,
  1537,
  2049,
  3073,
  4097,
  6145,
  8193,
  12289,
  16385,
  24577,
];
const _distanceExtra = [
  0,
  0,
  0,
  0,
  1,
  1,
  2,
  2,
  3,
  3,
  4,
  4,
  5,
  5,
  6,
  6,
  7,
  7,
  8,
  8,
  9,
  9,
  10,
  10,
  11,
  11,
  12,
  12,
  13,
  13,
];
