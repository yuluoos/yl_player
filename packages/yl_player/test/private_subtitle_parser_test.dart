import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/matroska_subtitles.dart';
import 'package:yl_player/src/subtitles/subtitle_resource.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'support/matroska_fixture.dart';
import 'support/compressed_subtitle_fixture.dart';
import 'support/private_subtitle_fixture.dart';
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
  for (final scope in [2, 3]) {
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
        test('private scope$scope algorithm$algo restores $codec', () async {
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
          final header = utf8.encode(
            codec == 'S_VOBSUB'
                ? vobPrivate()
                : ass
                ? assFixture(ssa: ssa).split('[Events]').first
                : codec == 'S_TEXT/WEBVTT'
                ? 'WEBVTT\n\nNOTE restored private'
                : '',
          );
          final settings = scope == 2 && algo == 3
              ? header.take(3).toList()
              : <int>[];
          final stored = scope == 3 && algo == 0 ? zlib.encode(bytes) : bytes;
          final e = (await parse(
            mkv(
              tracks: privateTrack(
                codec: codec,
                scope: scope,
                algo: algo,
                header: header,
                settings: settings,
              ),
              clusters: cluster(
                vobBlock(stored, time: 1234, duration: 500),
                time: 0,
              ),
            ),
          )).single;
          final encodedHeader = algo == 0
              ? zlib.encode(header).length
              : header.length - settings.length;
          expect(
            e.compressionBytes,
            settings.length + encodedHeader + (scope == 3 ? stored.length : 0),
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
          if (codec == 'S_TEXT/WEBVTT') {
            expect(d.inputBytes, header.length + bytes.length);
          }
        });
      }
    }
  }
  test(
    'both-scope stripping restores the same nonempty prefix independently',
    () async {
      final e = (await parse(
        mkv(
          tracks: privateTrack(
            scope: 3,
            algo: 3,
            settings: utf8.encode('WEB'),
            header: utf8.encode('WEBVTT'),
          ),
          clusters: cluster(vobBlock(utf8.encode('hello'), duration: 1000)),
        ),
      )).single;
      expect(e.packets.single.text, 'WEBhello');
      expect(e.sourceBytes, 6 + 8);
    },
  );
  test('header-only private element may have zero stored bytes', () async {
    final e = (await parse(
      mkv(
        tracks: privateTrack(algo: 3, settings: utf8.encode('WEBVTT')),
        clusters: cluster(block()),
      ),
    )).single;
    expect(e.packets.single.text, 'hello');
    expect(e.sourceBytes, 11);
  });
  test('scope2 does not reinterpret block bytes beginning like zlib', () async {
    final e = (await parse(
      mkv(
        tracks: privateTrack(),
        clusters: cluster(block(text: 'x valid literal')),
      ),
    )).single;
    expect(e.packets.single.text, 'x valid literal');
  });
  for (final scope in [2, 3]) {
    test(
      'private scope$scope requires a CodecPrivate element',
      () => expectLater(
        parse(
          mkv(
            tracks: track(extra: compressionEncoding(scope: scope)),
          ),
        ),
        reason(SubtitleParseReason.malformed),
      ),
    );
  }
  test('scope1 keeps CodecPrivate uncompressed', () async {
    final b = mkv(
      tracks: privateTrack(
        scope: 1,
        header: zlib.encode(utf8.encode('WEBVTT')),
      ),
    );
    await expectLater(parse(b), reason(SubtitleParseReason.malformed));
  });
  test('restored malformed UTF8 rejects before codec parser', () async {
    final b = mkv(tracks: privateTrack(header: [255]));
    await expectLater(parse(b), reason(SubtitleParseReason.malformed));
  });
  test('restored header semantics cannot inject cues', () async {
    final b = mkv(
      tracks: privateTrack(
        header: utf8.encode(
          'WEBVTT\n\n00:00:00.000 --> 00:00:01.000\ninjected',
        ),
      ),
    );
    await expectLater(parse(b), reason(SubtitleParseReason.unsupported));
  });
  test(
    'nonempty restored private remains unsupported for UTF8 subtitles',
    () async {
      final b = mkv(
        tracks: privateTrack(
          codec: 'S_TEXT/UTF8',
          header: utf8.encode('unexpected'),
        ),
      );
      await expectLater(parse(b), reason(SubtitleParseReason.unsupported));
    },
  );
  test('restored private output ceiling enforced', () async {
    final b = mkv(tracks: privateTrack(header: List.filled(262145, 65)));
    await expectLater(parse(b), reason(SubtitleParseReason.limitExceeded));
  });
  test('stored private size checked before payload read', () async {
    final b = mkv(
      tracks: track(
        extra: [
          ...compressionEncoding(scope: 2),
          ...element(0x63a2, List.filled(262145, 65)),
        ],
      ),
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
    'restored private global budget applies across tracks before decoding all',
    () async {
      final header = utf8.encode(
        'WEBVTT\n\nNOTE ${List.filled(250000, 'x').join()}',
      );
      await expectLater(
        parse(
          mkv(
            tracks: [
              for (var i = 1; i <= 17; i++)
                ...privateTrack(number: i, uid: i, header: header),
            ],
            clusters: cluster([]),
          ),
        ),
        reason(SubtitleParseReason.limitExceeded),
      );
    },
  );
  for (final kind in ['truncated', 'checksum', 'trailing']) {
    test('damaged compressed private $kind rejects', () async {
      var b = zlib.encode(utf8.encode('WEBVTT'));
      if (kind == 'truncated') {
        b = b.sublist(0, b.length - 1);
      } else if (kind == 'checksum') {
        b[b.length - 1] ^= 1;
      } else {
        b = [...b, 0];
      }
      await expectLater(
        parse(
          mkv(
            tracks: track(
              codec: 'S_TEXT/WEBVTT',
              extra: [...element(0x63a2, b), ...compressionEncoding(scope: 2)],
            ),
          ),
        ),
        reason(SubtitleParseReason.malformed),
      );
    });
  }
}
