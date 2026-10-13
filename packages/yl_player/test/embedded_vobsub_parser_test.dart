import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/matroska_subtitles.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'package:yl_player/src/subtitles/subtitle_resource.dart';
import 'support/matroska_fixture.dart';
import 'support/vobsub_fixture.dart';
import 'support/embedded_vobsub_fixture.dart';

Future<List<EmbeddedSubtitleData>> parse(List<int> b) => MatroskaSubtitles(
  b.length,
  (p, n) async => b.sublist(p, p + n),
  SubtitleCancellation(),
).parse();
SubtitleDocument doc(
  List<EmbeddedVobSubPacket> p, {
  String? header,
  SubtitleLimits limits = const SubtitleLimits(),
}) => SubtitleDocument.fromEmbeddedVobSub(
  p,
  codecPrivate: header ?? vobPrivate(),
  limits: limits,
);
EmbeddedVobSubPacket packet({
  List<int>? bytes,
  int start = 1000000,
  int? end,
}) => EmbeddedVobSubPacket(
  Duration(microseconds: start),
  bytes ?? vobSpu(),
  end: end == null ? null : Duration(microseconds: end),
);
Matcher reason(SubtitleParseReason r) =>
    throwsA(isA<SubtitleParseException>().having((e) => e.reason, 'reason', r));
void main() {
  test(
    'private header without v7 comment and legacy IDX metadata uses container time',
    () {
      final header =
          "${vobPrivate().split('\n').skip(1).join('\n')}"
          '\nid: xx, index: 31\nlangidx: 31\ntimestamp: 999:00:00:000, filepos: FFFFFFFFF\n';
      final d = doc([packet()], header: header);
      expect(d.cues.single.start, const Duration(seconds: 1));
      expect(d.cues.single.end, const Duration(milliseconds: 2024));
      expect(d.inputBytes, utf8.encode(header).length + vobSpu().length);
    },
  );
  test(
    'scale and CodecDelay preserve microseconds with explicit clipping',
    () async {
      final d = (await parse(
        mkv(
          scale: 1000,
          tracks: track(
            codec: 'S_VOBSUB',
            private: vobPrivate(),
            extra: uint(0x56aa, 500),
          ),
          clusters: cluster(
            vobBlock(vobSpu(), time: 1234, duration: 567),
            time: 0,
          ),
        ),
      )).single;
      expect(d.packets, isEmpty);
      expect(d.pgsPackets, isEmpty);
      final c = doc(d.vobSubPackets).cues.single;
      expect(c.start.inMicroseconds, 1233);
      expect(c.end.inMicroseconds, 1800);
    },
  );
  for (final simple in [true, false]) {
    test(
      'duration absent simple=$simple uses SPU stop and track default caps it',
      () async {
        for (final defaultNs in [null, 500000000]) {
          final d = (await parse(
            mkv(
              tracks: track(
                codec: 'S_VOBSUB',
                private: vobPrivate(),
                extra: defaultNs == null ? [] : uint(0x23e383, defaultNs),
              ),
              clusters: cluster(vobBlock(vobSpu(), simple: simple), time: 0),
            ),
          )).single;
          expect(
            doc(d.vobSubPackets).cues.single.end.inMicroseconds,
            defaultNs == null ? 2024000 : 1500000,
          );
        }
      },
    );
  }
  test('SPU start delay and forced bit survive container timing', () {
    final c = doc([
      packet(bytes: vobSpu(startTicks: 45, forced: true), end: 1800000),
    ]).cues.single;
    expect(c.start.inMicroseconds, 1512000);
    expect(c.end.inMicroseconds, 1800000);
    expect(c.pgs!.bitmaps.single.forced, true);
  });
  test('next packet caps preceding SPU and explicit longer duration', () {
    final d = doc([
      packet(bytes: vobSpu(stop: false), end: 6000000),
      packet(start: 1500000),
    ]);
    expect(d.cues.map((c) => c.end.inMicroseconds), [1500000, 2524000]);
  });
  test('equal timestamps replace previous packet', () {
    final d = doc([packet(), packet(bytes: vobSpu(x: 40))]);
    expect(d.cues, hasLength(1));
    expect(d.cues.single.pgs!.bitmaps.single.x, 40);
  });
  test(
    'no stop or duration ends at horizon without 32bit clock conversion',
    () {
      final start = const Duration(hours: 20, microseconds: 7);
      final c = doc([
        packet(bytes: vobSpu(stop: false), start: start.inMicroseconds),
      ]).cues.single;
      expect(c.start, start);
      expect(c.end, const Duration(days: 7));
    },
  );
  test('container cap before delayed start yields empty track', () {
    expect(
      doc([packet(bytes: vobSpu(startTicks: 45), end: 1100000)]).cues,
      isEmpty,
    );
  });
  test('empty track retains valid palette and encoded header budget', () {
    expect(doc([]).cues, isEmpty);
    expect(doc([]).inputBytes, utf8.encode(vobPrivate()).length);
  });
  test('raw packet immutable and diagnostics redact payload', () {
    final b = vobSpu(), p = packet(bytes: b);
    b[0] = 99;
    expect(p.bytes.first, 0);
    expect(() => p.bytes[0] = 1, throwsUnsupportedError);
    expect(p.toString(), contains('<redacted>'));
  });
  for (final e in <String, String>{
    'missing size': vobPrivate().replaceFirst('size: 100x100', ''),
    'missing palette': vobPrivate()
        .split('\n')
        .where((r) => !r.startsWith('palette:'))
        .join('\n'),
    'duplicate size': '${vobPrivate()}\nsize: 100x100',
    'bad colors': vobPrivate().replaceFirst('ffffff', 'zzzzzz'),
    'control': '${vobPrivate()}\norg:\x00',
  }.entries) {
    test(
      'malformed header ${e.key}',
      () => expect(
        () => doc([packet()], header: e.value),
        reason(SubtitleParseReason.malformed),
      ),
    );
  }
  for (final setting in [
    'scale: 50%, 100%',
    'delay: +00:00:01:000',
    'fadein/out: 50, 50',
    'forced subs: ON',
    'unknown: 1',
  ]) {
    test(
      'unsupported header $setting',
      () => expect(
        () => doc([packet()], header: '${vobPrivate()}\n$setting'),
        reason(SubtitleParseReason.unsupported),
      ),
    );
  }
  for (final e in <String, List<int>>{
    'truncated': vobSpu().sublist(0, 9),
    'multiple': [...vobSpu(), ...vobSpu()],
    'PS': vobSub(),
    'broken RLE': vobSpu(top: [0xff]),
  }.entries) {
    test(
      'raw SPU ${e.key} rejected',
      () => expect(
        () => doc([packet(bytes: e.value)]),
        reason(SubtitleParseReason.malformed),
      ),
    );
  }
  test(
    'advanced DVD command rejects explicitly',
    () => expect(
      () => doc([
        packet(bytes: vobSpu(extra: [7])),
      ]),
      reason(SubtitleParseReason.unsupported),
    ),
  );
  for (final p in [
    packet(start: -1),
    packet(end: 1000000),
    packet(end: 604800000001),
    packet(start: 604800000000),
  ]) {
    test(
      'invalid packet time ${p.start}/${p.end}',
      () => expect(() => doc([p]), reason(SubtitleParseReason.malformed)),
    );
  }
  test(
    'decreasing timestamps reject before decoding',
    () => expect(
      () => doc([packet(start: 2000000), packet()]),
      reason(SubtitleParseReason.malformed),
    ),
  );
  test(
    'expanded bitmap budget enforced before RGBA allocation',
    () => expect(
      () =>
          doc([packet()], limits: const SubtitleLimits(maxPgsBitmapBytes: 47)),
      reason(SubtitleParseReason.limitExceeded),
    ),
  );
  test(
    'input budget includes CodecPrivate',
    () => expect(
      () => doc([
        packet(),
      ], limits: SubtitleLimits(maxInputBytes: vobSpu().length)),
      reason(SubtitleParseReason.limitExceeded),
    ),
  );
  test(
    'header size bound applies even for empty track',
    () => expect(
      () => doc([], header: List.filled(256 * 1024 + 1, '#').join()),
      reason(SubtitleParseReason.limitExceeded),
    ),
  );
  test(
    'packet count bounded before decoding',
    () => expect(
      () => doc(List.filled(10001, packet())),
      reason(SubtitleParseReason.limitExceeded),
    ),
  );
  for (final kind in [
    'webm',
    'compressed',
    'additions',
    'laced',
    'missing-private',
    'empty-private',
    'zero-duration',
  ]) {
    test('container rejects $kind', () async {
      final b = mkv(
        docType: kind == 'webm' ? 'webm' : 'matroska',
        tracks: track(
          codec: 'S_VOBSUB',
          private: kind == 'missing-private'
              ? null
              : kind == 'empty-private'
              ? ''
              : vobPrivate(),
          extra: kind == 'compressed' ? element(0x6d80, []) : [],
        ),
        clusters: cluster(
          vobBlock(
            vobSpu(),
            flags: kind == 'laced' ? 2 : 0,
            duration: kind == 'zero-duration' ? 0 : null,
            extra: kind == 'additions' ? element(0x75a1, []) : [],
          ),
          time: 0,
        ),
      );
      await expectLater(
        parse(b),
        reason(
          ['missing-private', 'empty-private', 'zero-duration'].contains(kind)
              ? SubtitleParseReason.malformed
              : SubtitleParseReason.unsupported,
        ),
      );
    });
  }
  test('large SPU rejects before payload read', () async {
    final bytes = mkv(
      tracks: track(codec: 'S_VOBSUB', private: vobPrivate()),
      clusters: cluster(vobBlock(List.filled(65536, 255)), time: 0),
    );
    var maxRead = 0;
    final parser = MatroskaSubtitles(bytes.length, (p, n) async {
      if (n > maxRead) maxRead = n;
      return bytes.sublist(p, p + n);
    }, SubtitleCancellation());
    await expectLater(
      parser.parse(),
      reason(SubtitleParseReason.limitExceeded),
    );
    expect(maxRead, lessThan(65536));
  });
  test('VobSub metadata and text retain independent UID identity', () async {
    final d = await parse(
      mkv(
        tracks: [
          ...track(
            codec: 'S_VOBSUB',
            private: vobPrivate(),
            ietf: 'zh-Hant',
            forced: true,
          ),
          ...track(number: 2, uid: 202),
        ],
        clusters: cluster([
          ...vobBlock(vobSpu()),
          ...block(number: 2, text: 'text'),
        ], time: 0),
      ),
    );
    expect(d.map((d) => d.track.id), ['mkv:101', 'mkv:202']);
    expect(d.first.track.language, 'zh-Hant');
    expect(d.first.track.role, 'forced');
    expect(d.last.packets.single.text, 'text');
  });
  test('global text and VobSub packet cap enforced across tracks', () async {
    final b = mkv(
      tracks: [
        ...track(codec: 'S_VOBSUB', private: vobPrivate()),
        ...track(number: 2, uid: 202),
      ],
      clusters: cluster([
        for (var i = 0; i < 5000; i++) ...vobBlock(vobSpu(), time: i),
        for (var i = 0; i < 5001; i++) ...block(number: 2, time: i),
      ], time: 0),
    );
    await expectLater(parse(b), reason(SubtitleParseReason.limitExceeded));
  });
  test('global encoded budget charged across VobSub tracks', () async {
    final bytes = List.filled(65000, 255);
    final b = mkv(
      tracks: [
        ...track(codec: 'S_VOBSUB', private: vobPrivate()),
        ...track(number: 2, uid: 202, codec: 'S_VOBSUB', private: vobPrivate()),
      ],
      clusters: cluster([
        for (final number in [1, 2])
          for (var i = 0; i < 33; i++)
            ...vobBlock(bytes, number: number, time: i),
      ], time: 0),
    );
    await expectLater(parse(b), reason(SubtitleParseReason.limitExceeded));
  });
}
