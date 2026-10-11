import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'support/vobsub_fixture.dart';

SubtitleDocument parse({
  List<int>? sub,
  String? idx,
  SubtitleLimits limits = const SubtitleLimits(),
  String? language,
}) => SubtitleDocument.parseVobSub(
  sub ?? vobSub(),
  utf8.encode(idx ?? vobIdxText()),
  limits: limits,
  language: language,
);
Matcher bad(SubtitleParseReason reason) => throwsA(
  isA<SubtitleParseException>()
      .having((e) => e.reason, 'reason', reason)
      .having((e) => e.toString().contains('filepos'), 'sanitized', false),
);
void main() {
  test('DVD fields, RGB palette and 4-bit alpha are premultiplied exactly', () {
    final d = parse(), b = d.cues.single.pgs!.bitmaps.single;
    expect(d.inputBytes, vobSub().length + vobIdx().length);
    expect(d.pgsBitmapBytes, 48);
    expect(b.rgba, [
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      136,
      0,
      0,
      136,
      136,
      0,
      0,
      136,
      for (var i = 0; i < 4; i++) ...[255, 255, 255, 255],
      for (var i = 0; i < 4; i++) ...[0, 255, 0, 255],
    ]);
    expect(() => b.rgba[0] = 0, throwsUnsupportedError);
    expect(d.cues.single.start, const Duration(seconds: 1));
    expect(d.cues.single.end, const Duration(milliseconds: 2024));
  });
  test('control updates split frames and stop on exact 1024/90000 clock', () {
    final d = parse(sub: vobSub(spu: vobAnimated()));
    expect(d.cues, hasLength(2));
    expect(d.cues[0].end, const Duration(milliseconds: 1512));
    expect(d.cues[1].pgs!.bitmaps.single.rgba.sublist(8, 12), [0, 0, 0, 0]);
    expect(d.cuesAt(const Duration(milliseconds: 2024)), isEmpty);
  });
  test('forced-start is retained without implicit filtering', () {
    expect(
      parse(
        sub: vobSub(spu: vobSpu(forced: true)),
      ).cues.single.pgs!.bitmaps.single.forced,
      true,
    );
  });
  test('fragment assembly works at every legal first-fragment split', () {
    final unit = vobSpu();
    for (var i = 4; i < unit.length; i++) {
      expect(
        parse(
          sub: vobSub(spu: unit, split: i),
        ).cues,
        hasLength(1),
        reason: 'split$i',
      );
    }
  });
  test(
    'default stream and caller language choose independently of multiplex order',
    () {
      final en = vobSub(), fr = vobSub(spu: vobSpu(x: 40), stream: 1);
      final idx = vobIdxText(
        settings: 'langidx: 1',
        tail:
            'id: fr, index: 1\ntimestamp: 00:00:01:000, filepos: ${en.length.toRadixString(16)}',
      );
      final sub = [...en, ...fr];
      expect(parse(sub: sub, idx: idx).cues.single.pgs!.bitmaps.single.x, 40);
      expect(
        parse(
          sub: sub,
          idx: idx,
          language: 'en-US',
        ).cues.single.pgs!.bitmaps.single.x,
        20,
      );
      expect(
        () => parse(sub: sub, idx: idx, language: 'de'),
        bad(SubtitleParseReason.unsupported),
      );
    },
  );
  test('interleaved fragments stay associated with their own substream', () {
    final a = vobSpu(), b = vobSpu(x: 40);
    final first = [...vobPack, ...vobPes(a.sublist(0, 10))];
    final second = [...vobPack, ...vobPes(b, stream: 1)];
    final sub = [
      ...first,
      ...second,
      ...vobPack,
      ...vobPes(a.sublist(10), pts: false),
    ];
    final idx = vobIdxText(
      tail:
          'id: fr, index: 1\ntimestamp: 00:00:01:000, filepos: ${first.length.toRadixString(16)}',
    );
    expect(
      parse(
        sub: sub,
        idx: idx,
        language: 'en',
      ).cues.single.pgs!.bitmaps.single.x,
      20,
    );
  });
  test(
    'IDX times override structural PES PTS; exact PES filepos also works',
    () {
      final sub = vobSub();
      sub[18 + 6] = 0x2f; // valid PTS marker, unrelated clock.
      expect(
        parse(
          sub: sub,
          idx: vobIdxText(pos: 14, time: '00:00:03:000'),
        ).cues.single.start,
        const Duration(seconds: 3),
      );
    },
  );
  test(
    'delay plus public offset, negative clip and missing stop next entry bound',
    () {
      final a = vobSub(spu: vobSpu(stop: false)),
          b = vobSub(spu: vobSpu(x: 40));
      final d = parse(
        sub: [...a, ...b],
        idx: vobIdxText(
          settings: 'delay: -00:00:01:500',
          tail:
              'timestamp: 00:00:03:000, filepos: ${a.length.toRadixString(16)}',
        ),
      );
      expect(d.cues.first.start, Duration.zero);
      expect(d.cues.first.end, const Duration(milliseconds: 1500));
      expect(
        d
            .cuesAt(
              const Duration(seconds: 2),
              offset: const Duration(seconds: 1),
            )
            .single
            .pgs!
            .bitmaps
            .single
            .x,
        20,
      );
      expect(
        parse(sub: vobSub(spu: vobSpu(stop: false))).cues.single.end,
        const Duration(days: 7),
      );
    },
  );
  test('UTF8 BOM and CR-only index with conventional neutral settings', () {
    final s = vobIdxText(
      settings:
          'org: 0, 0\nscale: 100%, 100%\nalpha: 100%\nsmooth: OFF\nfadein/out: 0, 0\nalign: OFF at LEFT TOP\ntime offset: 0\nforced subs: OFF\ncustom colors: OFF, tridx: 1000, colors: 000000, ffffff, 808080, 000000',
    );
    expect(parse(idx: '\uFEFF${s.replaceAll('\n', '\r')}').cues, hasLength(1));
  });
  for (final (w, encoded) in [
    (1, [0x50]),
    (4, [0x11]),
    (16, [0x04, 0x10]),
    (64, [0x01, 0x01]),
    (100, [0, 1]),
  ]) {
    test('nibble RLE width $w including fill and byte padding', () {
      final d = parse(
        sub: vobSub(
          spu: vobSpu(w: w, h: 1, x: 0, top: encoded, bottom: []),
        ),
        idx: vobIdxText(),
      );
      expect(d.cues.single.pgs!.bitmaps.single.rgba, [
        for (var i = 0; i < w; i++) ...[255, 255, 255, 255],
      ]);
    });
  }
  final invalidIndex = <String, String>{
    'signature': 'bad',
    'missing size': vobIdxText().replaceFirst('size: 100x100', ''),
    'bad palette': vobIdxText().replaceFirst('ffffff', 'zzzzzz'),
    'duplicate size': vobIdxText(settings: 'size: 100x100'),
    'timestamp without stream': vobIdxText().replaceFirst(
      'id: en, index: 0',
      '',
    ),
    'invalid minute': vobIdxText(time: '00:60:00:000'),
    'out of range filepos': vobIdxText(pos: 9999),
    'middle of packet offset': vobIdxText(pos: 15),
    'wrong substream': vobIdxText(stream: 1),
    'duplicate timestamp': vobIdxText(
      tail: 'timestamp: 00:00:01:000, filepos: 10',
    ),
    'duplicate stream': vobIdxText(tail: 'id: en, index: 0'),
    'absent default stream': vobIdxText(settings: 'langidx: 2'),
  };
  for (final entry in invalidIndex.entries) {
    test('malformed idx ${entry.key}', () {
      expect(() => parse(idx: entry.value), bad(SubtitleParseReason.malformed));
    });
  }
  for (final setting in [
    'scale: 90%, 100%',
    'custom colors: ON, tridx: 0000',
    'forced subs: ON',
    'alpha: 50%',
    'unknown: external',
  ]) {
    test('unsupported effect $setting', () {
      expect(
        () => parse(idx: vobIdxText(settings: setting)),
        bad(SubtitleParseReason.unsupported),
      );
    });
  }
  test('strict packet prefixes reject every truncation', () {
    final s = vobSub();
    for (var i = 0; i < s.length; i++) {
      expect(
        () => parse(sub: s.sublist(0, i)),
        throwsA(isA<SubtitleParseException>()),
        reason: 'prefix$i',
      );
    }
  });
  for (final (name, mutate) in <(String, void Function(List<int>))>[
    ('PS magic', (b) => b[2] = 2),
    ('pack marker', (b) => b[4] = 0x40),
    ('PES declared length', (b) => b[19] = 0xff),
    ('PTS marker', (b) => b[23] = 0x20),
  ]) {
    test('malformed $name', () {
      final b = vobSub();
      mutate(b);
      expect(() => parse(sub: b), bad(SubtitleParseReason.malformed));
    });
  }
  for (final (name, mutate) in <(String, void Function(List<int>))>[
    ('control before bitmap', (b) => b[3] = 3),
    ('backward link', (b) => b[11] = 4),
    ('missing terminator', (b) => b[b.length - 1] = 0),
    (
      'backward date',
      (b) {
        b[8] = 0;
        b[9] = 100;
      },
    ),
    ('field points into control', (b) => b[27] = 8),
    ('row overflow', (b) => b[4] = 0xfd),
    ('nibble padding', (b) => b[7] = 0x15),
  ]) {
    test('malformed SPU $name', () {
      final b = vobSpu();
      mutate(b);
      expect(
        () => parse(sub: vobSub(spu: b)),
        bad(SubtitleParseReason.malformed),
      );
    });
  }
  test('CHG_COLCON fails explicitly', () {
    expect(
      () => parse(
        sub: vobSub(spu: vobSpu(extra: [7])),
      ),
      bad(SubtitleParseReason.unsupported),
    );
  });
  test('bitmap and combined input limits reject before expansion', () {
    expect(
      () => parse(limits: const SubtitleLimits(maxPgsBitmapBytes: 47)),
      bad(SubtitleParseReason.limitExceeded),
    );
    expect(
      parse(limits: const SubtitleLimits(maxPgsBitmapBytes: 48)).pgsBitmapBytes,
      48,
    );
    expect(
      () => parse(
        limits: SubtitleLimits(
          maxInputBytes: vobSub().length + vobIdx().length - 1,
        ),
      ),
      bad(SubtitleParseReason.limitExceeded),
    );
    expect(
      () => parse(
        sub: vobSub(spu: vobAnimated()),
        limits: const SubtitleLimits(maxPgsBitmapBytes: 95),
      ),
      bad(SubtitleParseReason.limitExceeded),
    );
  });
  test('canvas, time and line limits are enforced', () {
    expect(
      () => parse(idx: vobIdxText(width: 8193)),
      bad(SubtitleParseReason.limitExceeded),
    );
    expect(
      () => parse(idx: vobIdxText(time: '999:00:00:000')),
      bad(SubtitleParseReason.limitExceeded),
    );
    expect(
      () => parse(idx: vobIdxText(settings: '#${'a' * 2049}')),
      bad(SubtitleParseReason.limitExceeded),
    );
  });
  test('invalid byte values and UTF8 do not leak inputs', () {
    expect(
      () => SubtitleDocument.parseVobSub([-1], vobIdx()),
      bad(SubtitleParseReason.malformed),
    );
    expect(
      () => SubtitleDocument.parseVobSub(vobSub(), [255]),
      bad(SubtitleParseReason.malformed),
    );
  });
  test('oversized bitmap rejects before tiny RLE can allocate', () {
    expect(
      () => parse(
        sub: vobSub(spu: vobSpu(x: 0, y: 0, w: 4096, h: 4096)),
        idx: vobIdxText(width: 4096, height: 4096),
      ),
      bad(SubtitleParseReason.limitExceeded),
    );
  });
  test('two field offsets may be in reverse physical order', () {
    final b = vobSpu(top: [0x11], bottom: [0x9a, 0, 3]);
    b[27] = 5;
    b[29] = 4; // even field starts after the odd field data.
    expect(
      parse(sub: vobSub(spu: b)).cues.single.pgs!.bitmaps.single.rgba,
      parse().cues.single.pgs!.bitmaps.single.rgba,
    );
  });
  test('pack stuffing, system and padding packets do not alter offsets', () {
    final prefix = [...vobPack];
    prefix[13] = 0xfa;
    prefix.addAll([255, 255]);
    final sub = [
      ...prefix,
      0,
      0,
      1,
      0xbb,
      0,
      2,
      0x80,
      0,
      0,
      0,
      1,
      0xbe,
      0,
      3,
      255,
      255,
      255,
      ...vobPes(vobSpu()),
      0,
      0,
      1,
      0xb9,
    ];
    expect(parse(sub: sub).cues, hasLength(1));
  });
  test('PTS+DTS fields and absent PTS are structural, not cue timing', () {
    final body = [
      0x80,
      0xc0,
      10,
      0x31,
      0,
      1,
      0,
      1,
      0x11,
      0,
      1,
      0,
      1,
      0x20,
      ...vobSpu(),
    ];
    expect(
      parse(
        sub: [
          ...vobPack,
          0,
          0,
          1,
          0xbd,
          body.length >> 8,
          body.length & 255,
          ...body,
        ],
      ).cues.single.start,
      const Duration(seconds: 1),
    );
    expect(
      parse(sub: [...vobPack, ...vobPes(vobSpu(), pts: false)]).cues,
      hasLength(1),
    );
  });
  test('same-language ambiguity is explicit, default selection still valid', () {
    final a = vobSub(), b = vobSub(stream: 1);
    final idx = vobIdxText(
      tail:
          'id: en, index: 1\ntimestamp: 00:00:01:000, filepos: ${a.length.toRadixString(16)}',
    );
    expect(parse(sub: [...a, ...b], idx: idx).cues, hasLength(1));
    expect(
      () => parse(sub: [...a, ...b], idx: idx, language: 'en'),
      bad(SubtitleParseReason.unsupported),
    );
  });
  test('MPEG1, HD SPU and unrelated private stream reject explicitly', () {
    final one = vobSub();
    one[4] = 0x21;
    expect(() => parse(sub: one), bad(SubtitleParseReason.unsupported));
    final hd = vobSpu();
    hd[0] = hd[1] = 0;
    expect(
      () => parse(sub: vobSub(spu: hd)),
      bad(SubtitleParseReason.unsupported),
    );
    final audio = vobSub();
    audio[28] = 0x80;
    expect(() => parse(sub: audio), bad(SubtitleParseReason.unsupported));
  });
  test('signature line obeys the same preallocation line budget', () {
    final oversized = vobIdxText().replaceFirst('\n', '${'x' * 2049}\n');
    expect(() => parse(idx: oversized), bad(SubtitleParseReason.limitExceeded));
  });
  test('ordinary producer P-STD extension preserves bitmap and timing', () {
    final d = parse(sub: [...vobPack, ...vobExtendedPes(vobSpu())]),
        original = parse();
    expect(
      d.cues.single.pgs!.bitmaps.single.rgba,
      original.cues.single.pgs!.bitmaps.single.rgba,
    );
    expect(d.cues.single.start, original.cues.single.start);
    expect(d.cues.single.end, original.cues.single.end);
  });
  test('ordinary producer SPU terminal alignment byte is accepted', () {
    final unit = vobSpu(w: 1, h: 1, top: [0x50], bottom: []);
    expect(unit.length.isOdd, true);
    final d = parse(sub: vobSub(spu: vobPad(unit, [0xff])));
    expect(d.cues.single.pgs!.bitmaps.single.rgba, [255, 255, 255, 255]);
    expect(d.cues.single.end, const Duration(milliseconds: 2024));
  });
  for (final ext in [
    [0x1e],
    [0x1e, 0x60],
    [0x1e, 0xe0, 0x3a],
    [0x1e, 0x60, 0x3a, 0],
  ]) {
    test('malformed P-STD extension $ext', () {
      expect(
        () => parse(
          sub: [
            ...vobPack,
            ...vobExtendedPes(vobSpu(), extension: ext),
          ],
        ),
        bad(SubtitleParseReason.malformed),
      );
    });
  }
  test('SPU padding cannot hide extra commands or arbitrary bytes', () {
    final odd = vobSpu(w: 1, h: 1, top: [0x50], bottom: []);
    for (final unit in [
      vobPad(odd, [0]),
      vobPad(odd, [0xff, 0xff]),
      vobPad(vobSpu(), [0xff]),
    ]) {
      expect(
        () => parse(sub: vobSub(spu: unit)),
        bad(SubtitleParseReason.malformed),
      );
    }
  });
}
