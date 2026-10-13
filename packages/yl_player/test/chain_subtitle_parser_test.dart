import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'support/chain_subtitle_fixture.dart';
import 'private_subtitle_parser_test.dart' show parse, reason;
import 'support/embedded_vobsub_fixture.dart';
import 'support/embedded_pgs_fixture.dart';
import 'support/pgs_fixture.dart';
import 'support/vobsub_fixture.dart';
import 'support/ass_fixture.dart';

void main() {
  for (final scope in [1, 2, 3]) {
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
        test('chain scope$scope algorithm$algo restores $codec', () async {
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
          final stages = [
            EncodingStage(7, scope: scope, algo: algo, header: settings),
            EncodingStage(2, scope: scope, algo: algo),
          ];
          final stored = encodedChain(bytes, stages, 1);
          final e = (await parse(
            mkv(
              tracks: chainTrack(codec: codec, stages: stages, header: header),
              clusters: cluster(
                vobBlock(stored, time: 1234, duration: 500),
                time: 0,
              ),
            ),
          )).single;
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
  for (final reversed in [false, true]) {
    test(
      'noncommuting stripping/zlib follows gapped order (reversed=$reversed)',
      () async {
        final stages = [
          EncodingStage(2, scope: 1, algo: 3, header: utf8.encode('he')),
          const EncodingStage(9, scope: 1),
        ];
        final e = (await parse(
          chainMkv(stages: reversed ? stages.reversed.toList() : stages),
        )).single;
        expect(e.packets.single.text, 'hello');
        // Stored zlib('llo')11 + intermediate3 + stripping settings2.
        expect(e.compressionBytes, 16);
      },
    );
  }
  test('four stages decode in order regardless of physical order', () async {
    const stages = [
      EncodingStage(7),
      EncodingStage(1),
      EncodingStage(9),
      EncodingStage(3),
    ];
    expect(
      (await parse(chainMkv(stages: stages))).single.packets.single.text,
      'hello',
    );
  });
  test('a single nonzero encoding order is valid', () async {
    expect(
      (await parse(
        chainMkv(stages: [EncodingStage(9)]),
      )).single.packets.single.text,
      'hello',
    );
  });
  test('mixed private/block/both scopes filter independent chains', () async {
    final stages = [
      const EncodingStage(2, scope: 2),
      EncodingStage(5, scope: 1, algo: 3, header: utf8.encode('he')),
      const EncodingStage(9),
    ];
    final e = (await parse(chainMkv(stages: stages))).single;
    expect(e.packets.single.text, 'hello');
    expect(e.sourceBytes, 11);
  });
  test('five stages exceed the bounded chain count', () async {
    await expectLater(
      parse(chainMkv(stages: [for (var i = 0; i < 5; i++) EncodingStage(i)])),
      reason(SubtitleParseReason.limitExceeded),
    );
  });
  test('duplicate explicit orders reject before publishing', () async {
    await expectLater(
      parse(chainMkv(stages: [EncodingStage(2), EncodingStage(2)])),
      reason(SubtitleParseReason.malformed),
    );
  });
  for (final scope in [0, 4, 5, 8]) {
    test('chain stage scope$scope remains unsupported', () async {
      await expectLater(
        parse(
          chainMkv(
            stages: [
              EncodingStage(0),
              EncodingStage(3, scope: scope),
            ],
          ),
        ),
        reason(SubtitleParseReason.unsupported),
      );
    });
  }
  test('all private stages require CodecPrivate', () async {
    await expectLater(
      parse(
        mkv(
          tracks: track(
            extra: element(0x6d80, [for (final s in doubleZlib) ...s.bytes]),
          ),
        ),
      ),
      reason(SubtitleParseReason.malformed),
    );
  });
  test('WebM chains remain unsupported', () async {
    await expectLater(
      parse(
        mkv(
          docType: 'webm',
          tracks: chainTrack(codec: 'D_WEBVTT/SUBTITLES', header: []),
        ),
      ),
      reason(SubtitleParseReason.unsupported),
    );
  });
  for (final malformed in [
    <int>[1, 2, 3],
    [...zlib.encode(utf8.encode('hello')), 0],
  ]) {
    test(
      'strict inner zlib rejects ${malformed.length} bytes after valid outer restore',
      () async {
        await expectLater(
          parse(
            mkv(
              tracks: chainTrack(),
              clusters: cluster(
                vobBlock(zlib.encode(malformed), duration: 1000),
              ),
            ),
          ),
          reason(SubtitleParseReason.malformed),
        );
      },
    );
  }
  test(
    'intermediate compressed stream can exceed final block limit within stage cap',
    () async {
      const stages = [EncodingStage(0, scope: 1), EncodingStage(1, scope: 1)];
      final plain = List.filled(65535, 65);
      final e = (await parse(
        mkv(
          tracks: chainTrack(
            stages: stages,
            codec: 'S_VOBSUB',
            header: utf8.encode(vobPrivate()),
          ),
          clusters: cluster(
            vobBlock(
              encodedChain(plain, stages, 1, stored: true),
              duration: 1000,
            ),
          ),
        ),
      )).single;
      expect(e.vobSubPackets.single.bytes.length, 65535);
      expect(e.compressionBytes, greaterThan(131072));
    },
  );
  test(
    'intermediate stage over256KiB rejects even if final output would be empty',
    () async {
      // Valid RFC1950 stream with many empty stored DEFLATE blocks, Adler32(empty)=1.
      final large = [
        120,
        1,
        for (var i = 0; i < 53000; i++) ...[0, 0, 0, 255, 255],
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
      const stages = [EncodingStage(0, scope: 1), EncodingStage(1, scope: 1)];
      await expectLater(
        parse(
          mkv(
            tracks: chainTrack(
              stages: stages,
              codec: 'S_VOBSUB',
              header: utf8.encode(vobPrivate()),
            ),
            clusters: cluster(vobBlock(zlib.encode(large), duration: 1000)),
          ),
        ),
        reason(SubtitleParseReason.limitExceeded),
      );
    },
  );
  test('intermediate outputs count in global parser allowance', () async {
    const stages = [EncodingStage(0, scope: 1), EncodingStage(1, scope: 1)];
    final bytes = encodedChain(List.filled(16000, 65), stages, 1, stored: true);
    await expectLater(
      parse(
        mkv(
          tracks: chainTrack(stages: stages),
          clusters: cluster([
            for (var i = 0; i < 90; i++)
              ...vobBlock(bytes, time: i, duration: 1),
          ], time: 0),
        ),
      ),
      reason(SubtitleParseReason.limitExceeded),
    );
  });
}
