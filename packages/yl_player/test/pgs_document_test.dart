import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'support/pgs_fixture.dart';

SubtitleDocument parse(
  List<int> bytes, {
  SubtitleLimits limits = const SubtitleLimits(),
}) => SubtitleDocument.parse(bytes, format: SubtitleFormat.pgs, limits: limits);
Matcher reason(SubtitleParseReason r) =>
    throwsA(isA<SubtitleParseException>().having((e) => e.reason, 'reason', r));
List<int> single({
  List<int>? object,
  List<int>? pcs,
  List<int>? palette,
  List<int>? window,
}) => [
  ...pcs ?? pgsPcs(),
  ...window ?? pgsWindow(),
  ...palette ?? pgsPalette(),
  ...object ?? pgsObject(),
  ...pgsEnd(),
];
void main() {
  test(
    'binary framing, palette update and clear make nonoverlapping media cues',
    () {
      final d = parse(pgsFixture());
      expect(d.cues, hasLength(2));
      expect(d.cues[0].start, const Duration(seconds: 1));
      expect(d.cues[0].end, const Duration(seconds: 2));
      expect(d.cues[1].end, const Duration(seconds: 3));
      expect(d.cuesAt(const Duration(milliseconds: 999)), isEmpty);
      expect(d.cuesAt(const Duration(seconds: 2)).single, d.cues[1]);
      expect(d.cuesAt(const Duration(seconds: 3)), isEmpty);
      expect(
        d
            .cuesAt(
              const Duration(seconds: 2),
              offset: const Duration(milliseconds: 500),
            )
            .single,
        d.cues[0],
      );
      expect(d.cuesAt(Duration.zero), isEmpty);
      expect(d.cuesAt(const Duration(seconds: 1)).single, d.cues[0]);
    },
  );
  test(
    'decoded premultiplied RGBA, partial palette versions preserve old cues',
    () {
      final d = parse(pgsFixture()),
          a = d.cues.first.pgs!.bitmaps.single,
          b = d.cues.last.pgs!.bitmaps.single;
      expect([a.x, a.y, a.width, a.height], [20, 30, 4, 2]);
      expect(a.rgba.take(4), [255, 255, 255, 255]);
      expect(a.rgba.sublist(8, 12), [127, 0, 0, 128]);
      expect(b.rgba.take(4), [0, 0, 0, 255]);
      expect(b.rgba.sublist(8, 12), a.rgba.sublist(8, 12));
      expect(() => a.rgba[0] = 0, throwsUnsupportedError);
    },
  );
  test(
    'palette-only PCS placeholder does not move or clear existing plane',
    () {
      final d = parse([
        ...single(),
        ...pgsPcs(
          pts: 180000,
          state: 0,
          update: true,
          objects: [pgsRef(id: 999, x: 70, y: 80)],
        ),
        ...pgsPalette(version: 1, pts: 180000),
        ...pgsEnd(180000),
      ]);
      expect(d.cues.last.pgs!.bitmaps.single.x, 20);
      final empty = parse([
        ...single(),
        ...pgsPcs(pts: 180000, state: 0, update: true, objects: []),
        ...pgsPalette(version: 1, pts: 180000),
        ...pgsEnd(180000),
      ]);
      expect(empty.cues.last.pgs!.bitmaps, hasLength(1));
    },
  );
  test('last display persists until bounded timeline/session termination', () {
    expect(parse(single()).cues.single.end, const Duration(days: 7));
  });
  test(
    'fragmented ODS checks version/length and assembles before publication',
    () {
      final d = parse(
        single(
          object: [
            ...pgsObject(flags: 0x80, length: 15, data: [1, 1, 2]),
            ...pgsObject(flags: 0x40, data: [2, 0, 0, 0, 0x84, 1, 0, 0]),
          ],
        ),
      );
      expect(d.cues.single.pgs!.bitmaps.single.rgba.length, 32);
    },
  );
  test('all RLE run forms and transparent defaults decode exact rows', () {
    final d = parse(
      single(
        object: pgsObject(
          w: 70,
          h: 2,
          data: [0, 0xc0, 70, 1, 0, 0, 0, 0x40, 65, 0, 5, 0, 0],
        ),
      ),
    );
    final b = d.cues.single.pgs!.bitmaps.single;
    expect(b.width, 70);
    expect(b.rgba.take(4), [255, 255, 255, 255]);
    expect(b.rgba.skip(70 * 4).every((v) => v == 0), true);
  });
  test(
    'crop source and window clipping produce exact pixels and destination',
    () {
      final d = parse(
        single(
          pcs: pgsPcs(
            objects: [
              pgsRef(x: 20, y: 30, crop: [1, 0, 3, 2], forced: true),
            ],
          ),
          window: pgsWindow(x: 21, y: 30, w: 2, h: 1),
        ),
      );
      final b = d.cues.single.pgs!.bitmaps.single;
      expect([b.x, b.y, b.width, b.height], [21, 30, 2, 1]);
      expect(b.forced, true);
      expect(b.rgba, [127, 0, 0, 128, 127, 0, 0, 128]);
    },
  );
  test('two object references retain paint order', () {
    final d = parse(
      single(
        pcs: pgsPcs(objects: [pgsRef(), pgsRef(id: 2, x: 21)]),
        object: [...pgsObject(), ...pgsObject(id: 2)],
      ),
    );
    expect(d.cues.single.pgs!.bitmaps.map((b) => b.x), [20, 21]);
  });
  test('same PTS replaces previous frame without zero-length cue', () {
    final d = parse([
      ...single(),
      ...pgsPcs(state: 0, update: true),
      ...pgsPalette(
        version: 1,
        entries: [
          [1, 16, 128, 128, 255],
        ],
      ),
      ...pgsEnd(),
    ]);
    expect(d.cues, hasLength(1));
    expect(d.cues.single.pgs!.bitmaps.single.rgba[0], 0);
  });
  test(
    'PCS 32-bit rollover unwraps while segment DTS is not subtitle time',
    () {
      final d = parse([
        ...single(pcs: pgsPcs(pts: 0xfffffff0)),
        ...pgsPcs(pts: 90000, state: 0, objects: []),
        ...pgsEnd(),
      ]);
      expect(d.cues.single.start.inMicroseconds, 0xfffffff0 * 1000000 ~/ 90000);
      expect(
        d.cues.single.end.inMicroseconds,
        (0x100000000 + 90000) * 1000000 ~/ 90000,
      );
    },
  );
  test('epoch reset cannot resolve stale objects, palettes or windows', () {
    expect(
      () => parse([
        ...single(),
        ...pgsPcs(pts: 180000),
        ...pgsWindow(),
        ...pgsEnd(),
      ]),
      reason(SubtitleParseReason.malformed),
    );
  });
  test('epoch dimension change with fresh state is valid', () {
    final d = parse([
      ...single(),
      ...pgsPcs(pts: 180000, width: 200, height: 200),
      ...pgsWindow(w: 200, h: 200),
      ...pgsPalette(),
      ...pgsObject(),
      ...pgsEnd(),
    ]);
    expect(d.cues.last.pgs!.width, 200);
  });
  test(
    'all strict first-display truncations reject with sanitized failure',
    () {
      final bytes = single();
      for (var i = 0; i < bytes.length; i++) {
        expect(
          () => parse(bytes.sublist(0, i)),
          reason(SubtitleParseReason.malformed),
          reason: 'prefix $i',
        );
      }
    },
  );
  for (final (name, bytes) in [
    ('magic', [1, 2, ...single().skip(2)]),
    ('byte range', [-1, ...single().skip(1)]),
    ('duplicate PCS', [...pgsPcs(), ...single()]),
    ('orphan END', pgsEnd()),
    (
      'END payload',
      [
        ...single().take(single().length - 13),
        ...pgsSegment(0x80, [1]),
      ],
    ),
    ('incomplete ODS', single(object: pgsObject(flags: 0x80, length: 16))),
    ('orphan continuation', single(object: pgsObject(flags: 0x40))),
    (
      'fragment mismatch',
      single(
        object: [
          ...pgsObject(flags: 0x80, length: 16),
          ...pgsObject(flags: 0x40, version: 1, data: [1]),
        ],
      ),
    ),
    ('declared undersize', single(object: pgsObject(length: 4))),
    ('row overflow', single(object: pgsObject(data: [0, 0x85, 1, 0, 0]))),
    ('short row', single(object: pgsObject(data: [1, 0, 0]))),
    ('no final EOL', single(object: pgsObject(w: 1, h: 1, data: [1]))),
    ('zero run', single(object: pgsObject(data: [0, 0x80, 1]))),
    ('truncated run', single(object: pgsObject(data: [0, 0x40]))),
    (
      'extra row',
      single(object: pgsObject(w: 1, h: 1, data: [1, 0, 0, 1, 0, 0])),
    ),
    ('missing palette', single(palette: [])),
    ('missing object', single(object: [])),
    ('bad palette length', single(palette: pgsSegment(0x14, [0, 0, 1]))),
    (
      'duplicate palette entry',
      single(
        palette: pgsPalette(
          entries: [
            [1, 0, 0, 0, 0],
            [1, 0, 0, 0, 0],
          ],
        ),
      ),
    ),
    ('bad window', single(window: pgsWindow(x: 99, w: 2))),
    ('missing window', single(pcs: pgsPcs(objects: [pgsRef(window: 2)]))),
    (
      'crop outside object',
      single(
        pcs: pgsPcs(
          objects: [
            pgsRef(crop: [2, 0, 4, 2]),
          ],
        ),
      ),
    ),
    (
      'backward PCS',
      [...single(), ...pgsPcs(pts: 80000, state: 0, objects: []), ...pgsEnd()],
    ),
  ]) {
    test(
      'malformed $name',
      () => expect(() => parse(bytes), reason(SubtitleParseReason.malformed)),
    );
  }
  for (final (name, bytes) in [
    ('reserved state', single(pcs: pgsPcs(state: 0xc0))),
    ('unknown segment', [...pgsPcs(), ...pgsSegment(0x99, []), ...pgsEnd()]),
    ('cache-only redraw', single(window: [])),
    (
      'palette-only ODS',
      [
        ...single(),
        ...pgsPcs(pts: 180000, state: 0, update: true),
        ...pgsObject(),
        ...pgsEnd(),
      ],
    ),
    (
      'dimension change within epoch',
      [...single(), ...pgsPcs(pts: 180000, state: 0, width: 200), ...pgsEnd()],
    ),
  ]) {
    test(
      'unsupported $name',
      () => expect(() => parse(bytes), reason(SubtitleParseReason.unsupported)),
    );
  }
  test('preallocation bitmap budget counts all palette-expanded frames', () {
    expect(
      () => parse(
        pgsFixture(),
        limits: const SubtitleLimits(maxPgsBitmapBytes: 63),
      ),
      reason(SubtitleParseReason.limitExceeded),
    );
    expect(
      parse(
        pgsFixture(),
        limits: const SubtitleLimits(maxPgsBitmapBytes: 64),
      ).pgsBitmapBytes,
      64,
    );
    expect(
      () => parse(single(), limits: const SubtitleLimits(maxPgsBitmapBytes: 0)),
      reason(SubtitleParseReason.limitExceeded),
    );
  });
  test('dimension/product checks precede RLE allocation', () {
    expect(
      () => parse(
        single(
          pcs: pgsPcs(width: 8192, height: 8192),
          object: pgsObject(w: 8192, h: 8192),
        ),
      ),
      reason(SubtitleParseReason.limitExceeded),
    );
  });
  test('object reference budget and cue budget', () {
    expect(
      () => parse(single(pcs: pgsPcs(objects: [pgsRef(), pgsRef(), pgsRef()]))),
      reason(SubtitleParseReason.limitExceeded),
    );
    expect(
      () => parse(pgsFixture(), limits: const SubtitleLimits(maxCues: 1)),
      reason(SubtitleParseReason.limitExceeded),
    );
  });
}
