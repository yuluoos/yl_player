import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/matroska_subtitles.dart';
import 'package:yl_player/src/subtitles/subtitle_resource.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'support/matroska_fixture.dart';
import 'support/compressed_subtitle_fixture.dart';
import 'support/embedded_vobsub_fixture.dart';
import 'support/embedded_pgs_fixture.dart';
import 'support/pgs_fixture.dart';
import 'support/vobsub_fixture.dart';
import 'support/ass_fixture.dart';

Future<List<EmbeddedSubtitleData>> parse(List<int> b) => MatroskaSubtitles(
  b.length,
  (p, n) async => b.sublist(p, p + n),
  SubtitleCancellation(),
).parse();
Matcher reason(SubtitleParseReason r) =>
    throwsA(isA<SubtitleParseException>().having((e) => e.reason, 'reason', r));
void main() {
  for (final algo in [0, 3]) {
    for (final codec in [
      'S_TEXT/UTF8',
      'S_TEXT/ASS',
      'S_TEXT/SSA',
      'S_TEXT/WEBVTT',
      'D_WEBVTT/SUBTITLES',
      'S_HDMV/PGS',
      'S_VOBSUB',
    ]) {
      test('algorithm $algo restores $codec before existing decoder', () async {
        final ssa = codec == 'S_TEXT/SSA', ass = codec == 'S_TEXT/ASS' || ssa;
        final bytes = codec == 'S_HDMV/PGS'
            ? pgsPackets(
                pgsFixture(paletteUpdate: false, clear: false),
              ).expand((p) => p.bytes).toList()
            : codec == 'S_VOBSUB'
            ? vobSpu()
            : utf8.encode(
                ass
                    ? '0,${ssa ? '' : '0'},Default,,0,0,0,,hello'
                    : codec.startsWith('D_')
                    ? '\n\nhello'
                    : 'hello',
              );
        final header = codec == 'S_VOBSUB'
            ? vobPrivate()
            : ass
            ? assFixture(ssa: ssa).split('[Events]').first
            : codec == 'S_TEXT/WEBVTT'
            ? 'WEBVTT'
            : null;
        final settings = bytes.take(3).toList(),
            stored = algo == 0 ? zlib.encode(bytes) : bytes.skip(3).toList();
        final e = (await parse(
          mkv(
            tracks: track(
              codec: codec,
              private: header,
              extra: compressionEncoding(
                algo: algo,
                settings: algo == 3 ? settings : null,
              ),
            ),
            clusters: cluster(
              vobBlock(stored, time: 1234, duration: 500),
              time: 0,
            ),
          ),
        )).single;
        expect(
          e.compressionBytes,
          stored.length + (algo == 3 ? settings.length : 0),
        );
        final d = codec == 'S_HDMV/PGS'
            ? SubtitleDocument.fromEmbeddedPgs(e.pgsPackets)
            : codec == 'S_VOBSUB'
            ? SubtitleDocument.fromEmbeddedVobSub(
                e.vobSubPackets,
                codecPrivate: e.codecPrivate!,
              )
            : SubtitleDocument.fromEmbeddedPackets(
                e.packets,
                format: ass
                    ? (ssa ? SubtitleFormat.ssa : SubtitleFormat.ass)
                    : e.track.format == YlSubtitleFormat.webvtt
                    ? SubtitleFormat.webvtt
                    : SubtitleFormat.srt,
                codecPrivate: e.codecPrivate,
                sourceBytes: e.sourceBytes,
              );
        expect(d.cues.single.start.inMilliseconds, 1234);
        expect(d.cues.single.end.inMilliseconds, 1734);
        if (codec == 'S_HDMV/PGS' || codec == 'S_VOBSUB') {
          expect(d.cues.single.pgs!.bitmaps.single.rgba.take(4), [
            255,
            255,
            255,
            255,
          ]);
        } else {
          expect(d.cues.single.payload, 'hello');
        }
      });
    }
  }
  test('default algorithm/scope/type/order mean zlib block', () async {
    final e = (await parse(
      mkv(
        tracks: track(extra: compressionEncoding(algo: null)),
        clusters: cluster(
          vobBlock(zlib.encode(utf8.encode('hello')), time: 0, duration: 1000),
        ),
      ),
    )).single;
    expect(e.packets.single.text, 'hello');
  });
  test('header-only block may have no stored payload', () async {
    final e = (await parse(
      mkv(
        tracks: track(
          extra: compressionEncoding(algo: 3, settings: utf8.encode('hello')),
        ),
        clusters: cluster(vobBlock([], time: 0, duration: 1000)),
      ),
    )).single;
    expect(e.packets.single.text, 'hello');
  });
  test('empty stripping header restores unchanged block', () async {
    final e = (await parse(
      mkv(
        tracks: track(extra: compressionEncoding(algo: 3, settings: [])),
        clusters: cluster(block()),
      ),
    )).single;
    expect(e.packets.single.text, 'hello');
  });
  for (final entry in <String, List<int>>{
    'algorithm': compressionEncoding(algo: 1),
    'scope0': compressionEncoding(scope: 0),
    'scope5': compressionEncoding(scope: 5),
    'scope8': compressionEncoding(scope: 8),
    'scope4': compressionEncoding(scope: 4),
    'type': compressionEncoding(type: 1),
    'algorithm2': compressionEncoding(algo: 2),
    'zlib settings': compressionEncoding(settings: [1]),
    'encryption': compressionEncoding(extra: element(0x5035, [])),
  }.entries) {
    test(
      'unsupported encoding ${entry.key}',
      () => expectLater(
        parse(mkv(tracks: track(extra: entry.value))),
        reason(SubtitleParseReason.unsupported),
      ),
    );
  }
  test(
    'duplicate default encoding order is malformed',
    () => expectLater(
      parse(
        mkv(
          tracks: track(
            extra: element(0x6d80, [
              ...element(0x6240, element(0x5034, [])),
              ...element(0x6240, element(0x5034, [])),
            ]),
          ),
        ),
      ),
      reason(SubtitleParseReason.malformed),
    ),
  );
  test(
    'stripping requires settings',
    () => expectLater(
      parse(mkv(tracks: track(extra: compressionEncoding(algo: 3)))),
      reason(SubtitleParseReason.malformed),
    ),
  );
  test(
    'encoding requires compression element',
    () => expectLater(
      parse(mkv(tracks: track(extra: element(0x6d80, element(0x6240, []))))),
      reason(SubtitleParseReason.malformed),
    ),
  );
  test(
    'WebM compression remains unsupported',
    () => expectLater(
      parse(
        mkv(
          docType: 'webm',
          tracks: track(
            codec: 'D_WEBVTT/SUBTITLES',
            extra: compressionEncoding(),
          ),
        ),
      ),
      reason(SubtitleParseReason.unsupported),
    ),
  );
  test('non-subtitle compressed media does not allocate or decode', () async {
    final media = element(0xae, [
      ...uint(0xd7, 2),
      ...uint(0x73c5, 202),
      ...uint(0x83, 1),
      ...str(0x86, 'V_VP9'),
      ...compressionEncoding(algo: 99),
    ]);
    final d = await parse(
      mkv(
        tracks: [...track(), ...media],
        clusters: cluster([
          ...block(),
          ...vobBlock([1, 2, 3], number: 2),
        ]),
      ),
    );
    expect(d.single.packets.single.text, 'hello');
  });
  for (final algo in [0, 3]) {
    test('restored text per-block limit algorithm $algo', () async {
      final plain = List.filled(65537, 65),
          stored = algo == 0 ? zlib.encode(plain) : [65];
      await expectLater(
        parse(
          mkv(
            tracks: track(
              extra: compressionEncoding(
                algo: algo,
                settings: algo == 3 ? plain.sublist(1) : null,
              ),
            ),
            clusters: cluster(vobBlock(stored, time: 0, duration: 1000)),
          ),
        ),
        reason(SubtitleParseReason.limitExceeded),
      );
    });
  }
  test('stored compressed block capped before payload read', () async {
    final b = mkv(
      tracks: track(extra: compressionEncoding()),
      clusters: cluster(vobBlock(List.filled(262145, 0), duration: 1000)),
    );
    var max = 0;
    final p = MatroskaSubtitles(b.length, (p, n) async {
      if (n > max) max = n;
      return b.sublist(p, p + n);
    }, SubtitleCancellation());
    await expectLater(p.parse(), reason(SubtitleParseReason.limitExceeded));
    expect(max, lessThan(262145));
  });
  test(
    'restored bytes count globally even with tiny stored compressed payload',
    () async {
      final bytes = zlib.encode(List.filled(16000, 65));
      await expectLater(
        parse(
          mkv(
            tracks: track(extra: compressionEncoding()),
            clusters: cluster([
              for (var i = 0; i < 270; i++)
                ...vobBlock(bytes, time: i, duration: 1),
            ], time: 0),
          ),
        ),
        reason(SubtitleParseReason.limitExceeded),
      );
    },
  );
  test('stored plus restored bytes share global budget', () async {
    final bytes = ZLibEncoder(level: 0).convert(List.filled(16000, 65));
    await expectLater(
      parse(
        mkv(
          tracks: track(extra: compressionEncoding()),
          clusters: cluster([
            for (var i = 0; i < 132; i++)
              ...vobBlock(bytes, time: i, duration: 1),
          ], time: 0),
        ),
      ),
      reason(SubtitleParseReason.limitExceeded),
    );
  });
  test('cancelled demux cannot publish decoded packets', () async {
    final b = compressedMkv();
    final token = SubtitleCancellation()..cancel();
    await expectLater(
      MatroskaSubtitles(
        b.length,
        (p, n) async => b.sublist(p, p + n),
        token,
      ).parse(),
      throwsA(isA<YlPlayerException>()),
    );
  });
}
