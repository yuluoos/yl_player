import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/subtitle_inflate.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';

Matcher reason(SubtitleParseReason r) =>
    throwsA(isA<SubtitleParseException>().having((e) => e.reason, 'reason', r));
void main() {
  final rng = Random(739);
  final inputs = <List<int>>[
    [],
    [65, 66, 67],
    List.filled(65536, 65),
    List.generate(150000, (i) => i % 251),
    List.generate(65536, (_) => rng.nextInt(256)),
  ];
  for (final level in [0, 1, 6, 9]) {
    test('strict inflate agrees with SDK encoder level $level', () {
      for (final input in inputs) {
        final b = ZLibEncoder(level: level).convert(input);
        expect(inflateSubtitle(b, input.length), input);
      }
    });
  }
  for (final strategy in [
    ZLibOption.strategyFixed,
    ZLibOption.strategyHuffmanOnly,
    ZLibOption.strategyRle,
  ]) {
    test('strict inflate accepts independent strategy $strategy', () {
      for (final input in inputs) {
        final b = ZLibEncoder(strategy: strategy).convert(input);
        expect(inflateSubtitle(b, input.length), input);
      }
    });
  }
  test('exact output ceiling succeeds and one byte less rejects', () {
    final b = zlib.encode(List.filled(262144, 65));
    expect(inflateSubtitle(b, 262144), hasLength(262144));
    expect(
      () => inflateSubtitle(b, 262143),
      reason(SubtitleParseReason.limitExceeded),
    );
  });
  test(
    'high-ratio bomb stopped before declared output bound',
    () => expect(
      () => inflateSubtitle(zlib.encode(List.filled(2000000, 65)), 65536),
      reason(SubtitleParseReason.limitExceeded),
    ),
  );
  test('every truncated prefix of a valid stream rejects', () {
    final b = zlib.encode(List.generate(300, (i) => i % 256));
    for (var i = 0; i < b.length; i++) {
      expect(
        () => inflateSubtitle(b.sublist(0, i), 1000),
        reason(SubtitleParseReason.malformed),
        reason: 'prefix$i',
      );
    }
  });
  test('checksum mismatch rejects', () {
    final b = zlib.encode([65, 66, 67]);
    b[b.length - 1] ^= 1;
    expect(
      () => inflateSubtitle(b, 100),
      reason(SubtitleParseReason.malformed),
    );
  });
  test('trailing bytes with copied valid checksum reject', () {
    final b = zlib.encode([65, 66, 67]);
    expect(
      () => inflateSubtitle([...b, 0, ...b.sublist(b.length - 4)], 100),
      reason(SubtitleParseReason.malformed),
    );
  });
  test('concatenated identical streams reject', () {
    final b = zlib.encode([65, 66, 67]);
    expect(
      () => inflateSubtitle([...b, ...b], 100),
      reason(SubtitleParseReason.malformed),
    );
  });
  test(
    'gzip is not Matroska zlib',
    () => expect(
      () => inflateSubtitle(gzip.encode([65]), 100),
      reason(SubtitleParseReason.malformed),
    ),
  );
  test('invalid header checkbits reject', () {
    final b = zlib.encode([65]);
    b[1] ^= 1;
    expect(
      () => inflateSubtitle(b, 100),
      reason(SubtitleParseReason.malformed),
    );
  });
  test(
    'preset dictionary rejected explicitly',
    () => expect(
      () => inflateSubtitle([0x78, 0x20, 0, 0, 0, 0], 100),
      reason(SubtitleParseReason.unsupported),
    ),
  );
  test(
    'reserved DEFLATE block rejects',
    () => expect(
      () => inflateSubtitle([0x78, 0x9c, 7, 0, 0, 0, 1], 100),
      reason(SubtitleParseReason.malformed),
    ),
  );
  test(
    'stored length complement rejects',
    () => expect(
      () => inflateSubtitle([0x78, 0x01, 1, 1, 0, 1, 0, 65, 0, 0, 0, 1], 100),
      reason(SubtitleParseReason.malformed),
    ),
  );
  test(
    'empty dynamic Huffman alphabet rejects',
    () => expect(
      () => inflateSubtitle([0x78, 0x9c, 5, 0, 0, 0, 0, 0, 0, 1], 100),
      reason(SubtitleParseReason.malformed),
    ),
  );
  test(
    'missing end-of-block rejects',
    () => expect(
      () => inflateSubtitle([0x78, 0x9c, 3, 0, 0, 0, 1], 100),
      reason(SubtitleParseReason.malformed),
    ),
  );
  for (final bound in [-1, 262145]) {
    test(
      'invalid output bound $bound',
      () => expect(
        () => inflateSubtitle(zlib.encode([]), bound),
        reason(SubtitleParseReason.limitExceeded),
      ),
    );
  }
  test('Python zlib golden streams restore exact independent bytes', () {
    final fixture =
        jsonDecode(
              File(
                'packages/yl_player/test/fixtures/subtitle-zlib-owned.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    for (final r in fixture['records'] as List<dynamic>) {
      expect(
        inflateSubtitle(base64Decode(r['compressed'] as String), 7000),
        base64Decode(r['decoded'] as String),
        reason: r['kind'] as String,
      );
    }
  });
  test('oversubscribed dynamic code-length alphabet rejects', () {
    final w = _Writer()
      ..bits(1, 1)
      ..bits(2, 2)
      ..bits(0, 5)
      ..bits(0, 5)
      ..bits(0, 4);
    for (var i = 0; i < 4; i++) {
      w.bits(1, 3);
    }
    expect(
      () => inflateSubtitle(w.stream(), 100),
      reason(SubtitleParseReason.malformed),
    );
  });
  test('repeat previous length before any length rejects', () {
    final w = _Writer()
      ..bits(1, 1)
      ..bits(2, 2)
      ..bits(0, 5)
      ..bits(0, 5)
      ..bits(0, 4);
    for (final n in [1, 0, 0, 1]) {
      w.bits(n, 3);
    }
    w.bits(1, 1); // symbol16, but no preceding code length exists.
    expect(
      () => inflateSubtitle(w.stream(), 100),
      reason(SubtitleParseReason.malformed),
    );
  });
  test('repeat zero lengths beyond declared alphabets rejects', () {
    final w = _Writer()
      ..bits(1, 1)
      ..bits(2, 2)
      ..bits(0, 5)
      ..bits(0, 5)
      ..bits(0, 4);
    for (final n in [0, 0, 1, 1]) {
      w.bits(n, 3);
    }
    for (var i = 0; i < 2; i++) {
      w.bits(1, 1);
      w.bits(127, 7);
    } // two repeats138 exceed258.
    expect(
      () => inflateSubtitle(w.stream(), 100),
      reason(SubtitleParseReason.malformed),
    );
  });
  test('fixed length cannot refer before beginning of output', () {
    final w = _Writer()
      ..bits(1, 1)
      ..bits(1, 2)
      ..huffman(1, 7)
      ..huffman(0, 5);
    expect(
      () => inflateSubtitle(w.stream(), 100),
      reason(SubtitleParseReason.malformed),
    );
  });
  test('reserved fixed literal code rejects', () {
    final w = _Writer()
      ..bits(1, 1)
      ..bits(1, 2)
      ..huffman(198, 8);
    expect(
      () => inflateSubtitle(w.stream(), 100),
      reason(SubtitleParseReason.malformed),
    );
  });
  test('reserved fixed distance code rejects', () {
    final w = _Writer()
      ..bits(1, 1)
      ..bits(1, 2)
      ..huffman(1, 7)
      ..huffman(30, 5);
    expect(
      () => inflateSubtitle(w.stream(), 100),
      reason(SubtitleParseReason.malformed),
    );
  });
  test('DEFLATE empty block storm is bounded independently of output', () {
    final b = [
      0x78,
      0x01,
      for (var i = 0; i < 10000; i++) ...[0, 0, 0, 255, 255],
      1,
      0,
      0,
      255,
      255,
      0,
      0,
      0,
      1,
    ];
    expect(
      () => inflateSubtitle(b, 100),
      reason(SubtitleParseReason.limitExceeded),
    );
  });
}

final class _Writer {
  final b = <int>[];
  int offset = 0;
  void bits(int value, int n) {
    for (var i = 0; i < n; i++, offset++) {
      if (offset % 8 == 0) b.add(0);
      b[offset ~/ 8] |= ((value >> i) & 1) << (offset % 8);
    }
  }

  void huffman(int value, int n) {
    for (var i = n - 1; i >= 0; i--) {
      bits((value >> i) & 1, 1);
    }
  }

  List<int> stream() => [0x78, 0x9c, ...b, 0, 0, 0, 1];
}
