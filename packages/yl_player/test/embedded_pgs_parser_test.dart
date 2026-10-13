import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/matroska_subtitles.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'package:yl_player/src/subtitles/subtitle_resource.dart';
import 'support/matroska_fixture.dart';
import 'support/pgs_fixture.dart';
import 'support/embedded_pgs_fixture.dart';

Future<List<EmbeddedSubtitleData>> parse(List<int> b) => MatroskaSubtitles(
  b.length,
  (p, n) async => b.sublist(p, p + n),
  SubtitleCancellation(),
).parse();
List<int> display() => pgsPackets(
  pgsFixture(paletteUpdate: false, clear: false),
).expand((p) => p.bytes).toList();
SubtitleDocument doc(
  List<EmbeddedPgsPacket> p, {
  SubtitleLimits limits = const SubtitleLimits(),
}) => SubtitleDocument.fromEmbeddedPgs(p, limits: limits);
Matcher reason(SubtitleParseReason r) =>
    throwsA(isA<SubtitleParseException>().having((e) => e.reason, 'reason', r));
void main() {
  test(
    'container nanosecond scale and CodecDelay preserve microseconds',
    () async {
      final d = (await parse(
        mkv(
          scale: 1000,
          tracks: track(codec: 'S_HDMV/PGS', extra: uint(0x56aa, 500)),
          clusters: cluster(
            pgsBlock(display(), time: 1234, duration: 567),
            time: 0,
          ),
        ),
      )).single;
      final c = doc(d.pgsPackets).cues.single;
      expect(c.start.inMicroseconds, 1233);
      expect(c.end.inMicroseconds, 1800);
    },
  );
  test('explicit duration caps a display before next presentation', () {
    final d = doc([
      EmbeddedPgsPacket(
        const Duration(seconds: 1),
        display(),
        end: const Duration(milliseconds: 1500),
      ),
      EmbeddedPgsPacket(const Duration(seconds: 2), display()),
    ]);
    expect(d.cues.first.end, const Duration(milliseconds: 1500));
    expect(d.cuesAt(const Duration(milliseconds: 1750)), isEmpty);
    expect(d.cues.last.end, const Duration(days: 7));
  });
  test('following presentation caps a longer explicit duration', () {
    final d = doc([
      EmbeddedPgsPacket(
        const Duration(seconds: 1),
        display(),
        end: const Duration(seconds: 5),
      ),
      EmbeddedPgsPacket(
        const Duration(seconds: 2),
        display(),
        end: const Duration(seconds: 3),
      ),
    ]);
    expect(d.cues.map((c) => c.end.inSeconds), [2, 3]);
  });
  test('duration on END packet also clips split display', () {
    final packets = pgsPackets(pgsFixture(paletteUpdate: false, clear: false));
    final d = doc([
      for (var i = 0; i < packets.length; i++)
        EmbeddedPgsPacket(
          const Duration(seconds: 1),
          packets[i].bytes,
          end: i == packets.length - 1
              ? const Duration(milliseconds: 1500)
              : null,
        ),
    ]);
    expect(d.cues.single.end, const Duration(milliseconds: 1500));
  });
  test('container timing beyond SUP wrap does not round through 90kHz', () {
    final start = const Duration(hours: 20, microseconds: 7);
    final d = doc([
      EmbeddedPgsPacket(
        start,
        display(),
        end: start + const Duration(microseconds: 19),
      ),
    ]);
    expect(d.cues.single.start, start);
    expect(d.cues.single.end, start + const Duration(microseconds: 19));
  });
  test('equal time displays replace instead of overlaying stale frame', () {
    final packets = pgsPackets(pgsFixture());
    final d = doc([
      for (final p in packets)
        EmbeddedPgsPacket(
          Duration(milliseconds: p.time == 2000 ? 1000 : p.time),
          p.bytes,
        ),
    ]);
    expect(d.cues, hasLength(1));
    expect(d.cues.single.pgs!.bitmaps.single.rgba.take(4), [0, 0, 0, 255]);
  });
  test('empty track is a valid empty document', () {
    expect(doc([]).cues, isEmpty);
  });
  for (final (name, packets) in <(String, List<EmbeddedPgsPacket>)>[
    (
      'truncated segment',
      [
        EmbeddedPgsPacket(Duration.zero, [0x16, 0, 20, 0]),
      ],
    ),
    (
      'orphan END',
      [
        EmbeddedPgsPacket(Duration.zero, [0x80, 0, 0]),
      ],
    ),
    (
      'incomplete display',
      [EmbeddedPgsPacket(Duration.zero, pgsPackets(pgsPcs()).single.bytes)],
    ),
    (
      'backwards PCS',
      [
        EmbeddedPgsPacket(const Duration(seconds: 2), display()),
        EmbeddedPgsPacket(const Duration(seconds: 1), display()),
      ],
    ),
    (
      'zero duration',
      [EmbeddedPgsPacket(Duration.zero, display(), end: Duration.zero)],
    ),
    (
      'negative start',
      [EmbeddedPgsPacket(const Duration(microseconds: -1), display())],
    ),
    (
      'seven day start',
      [EmbeddedPgsPacket(const Duration(days: 7), display())],
    ),
    (
      'expired split display',
      [
        EmbeddedPgsPacket(
          const Duration(seconds: 2),
          pgsPackets(pgsPcs()).single.bytes,
        ),
        EmbeddedPgsPacket(Duration.zero, [
          0x80,
          0,
          0,
        ], end: const Duration(seconds: 1)),
      ],
    ),
  ]) {
    test(
      'malformed $name',
      () => expect(() => doc(packets), reason(SubtitleParseReason.malformed)),
    );
  }
  test(
    'unknown binary segment remains unsupported',
    () => expect(
      () => doc([
        EmbeddedPgsPacket(Duration.zero, [
          0x16,
          ...display().skip(1).take(21),
          0xff,
          0,
          0,
        ]),
      ]),
      throwsA(isA<SubtitleParseException>()),
    ),
  );
  for (final limit in [0, 31]) {
    test(
      'expanded limit $limit checks before bitmap allocation',
      () => expect(
        () => doc([
          EmbeddedPgsPacket(Duration.zero, display()),
        ], limits: SubtitleLimits(maxPgsBitmapBytes: limit)),
        reason(SubtitleParseReason.limitExceeded),
      ),
    );
  }
  test('encoded document budget includes all binary segments', () {
    final b = display();
    expect(
      () => doc([
        EmbeddedPgsPacket(Duration.zero, b),
      ], limits: SubtitleLimits(maxInputBytes: b.length - 1)),
      reason(SubtitleParseReason.limitExceeded),
    );
    expect(doc([EmbeddedPgsPacket(Duration.zero, b)]).inputBytes, b.length);
  });
  test('segment count is bounded independently of packet count', () {
    final b = <int>[for (var i = 0; i < 300; i++) ...display()];
    expect(
      () => doc([
        for (var i = 0; i < 34; i++)
          EmbeddedPgsPacket(Duration(milliseconds: i), b),
      ]),
      reason(SubtitleParseReason.limitExceeded),
    );
  });
  test('large raw Matroska block rejected before payload read', () async {
    final b = mkv(
      tracks: track(codec: 'S_HDMV/PGS'),
      clusters: cluster(pgsBlock(List.filled(262145, 0))),
    );
    var largest = 0;
    await expectLater(
      MatroskaSubtitles(b.length, (p, n) async {
        if (n > largest) largest = n;
        return b.sublist(p, p + n);
      }, SubtitleCancellation()).parse(),
      reason(SubtitleParseReason.limitExceeded),
    );
    expect(largest, lessThan(262145));
  });
  for (final (name, extra, private, docType)
      in <(String, List<int>, String?, String)>[
        ('private', [], 'unsupported', 'matroska'),
        ('compressed', element(0x6d80, []), null, 'matroska'),
        ('WebM', [], null, 'webm'),
      ]) {
    test(
      'unsupported $name track',
      () async => expectLater(
        parse(
          mkv(
            docType: docType,
            tracks: track(codec: 'S_HDMV/PGS', private: private, extra: extra),
            clusters: [],
          ),
        ),
        reason(SubtitleParseReason.unsupported),
      ),
    );
  }
  test(
    'PGS block additions are still unsupported',
    () async => expectLater(
      parse(
        mkv(
          tracks: track(codec: 'S_HDMV/PGS'),
          clusters: cluster(pgsBlock(display(), extra: element(0x75a1, []))),
        ),
      ),
      reason(SubtitleParseReason.unsupported),
    ),
  );
  test('text and PGS tracks share stable UID catalog', () async {
    final d = await parse(
      mkv(
        tracks: [
          ...track(number: 2, uid: 202),
          ...track(codec: 'S_HDMV/PGS', forced: true),
        ],
        clusters: cluster([
          ...block(number: 2),
          ...pgsBlock(display(), time: 0),
        ]),
      ),
    );
    expect(d.map((e) => e.track.id), ['mkv:202', 'mkv:101']);
    expect(d.last.track.role, 'forced');
    expect(d.last.track.format, YlSubtitleFormat.pgs);
    expect(d.last.packets, isEmpty);
    expect(d.first.pgsPackets, isEmpty);
  });
}
