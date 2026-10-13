import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'support/wvtt_structure_fixture.dart';
import 'mp4_parser_test.dart' show parse, bad;

void main() {
  for (final layout in ['ordinary', 'fragmented', 'hybrid']) {
    test(
      '$layout rejects aggregate nested boxes above resource limit',
      () async {
        await expectLater(
          parse(structureFile(layout, 200000)),
          bad(SubtitleParseReason.limitExceeded),
        );
      },
    );
  }
  for (final layout in ['ordinary', 'fragmented', 'hybrid']) {
    // Ordinary fixture: 5 common boxes + 17 track/configuration boxes.
    // Fragmented/hybrid: add mvex, trex, free and 8 fragment boxes.
    final overhead = layout == 'ordinary' ? 22 : 33;
    test('$layout admits exactly 200000 boxes without phantom cues', () async {
      final tracks = await parse(structureFile(layout, 200000 - overhead));
      expect(tracks.single.packets, isEmpty);
      expect(tracks.single.track.id, 'mp4:1');
    });
    test('$layout rejects the first box over the exact boundary', () async {
      await expectLater(
        parse(structureFile(layout, 200001 - overhead)),
        bad(SubtitleParseReason.limitExceeded),
      );
    });
    test(
      '$layout counts extra configuration children in shared allowance',
      () async {
        await expectLater(
          parse(
            structureFile(
              layout,
              200000 - overhead,
              entry: wvttEntry(extra: box('vlab', [])),
            ),
          ),
          bad(SubtitleParseReason.limitExceeded),
        );
      },
    );
    test('$layout shares outer container and sample box allowance', () async {
      await expectLater(
        parse([
          ...structureFile(layout, 200000 - overhead),
          ...box('free', []),
        ]),
        bad(SubtitleParseReason.limitExceeded),
      );
    });
  }
  test('all tracks share nested box allowance', () async {
    final samples = structureSamples(100000);
    await expectLater(
      parse(
        mp4(
          tracks: [
            for (final id in [1, 2])
              Mp4Track(
                id: id,
                entry: wvttEntry(),
                samples: samples,
                durations: List.filled(samples.length, 1),
              ),
          ],
        ),
      ),
      bad(SubtitleParseReason.limitExceeded),
    );
  });
  test('separate fragments share nested box allowance', () async {
    final samples = structureSamples(100000);
    await expectLater(
      parse(
        fragmented(
          fragments: [
            for (var i = 0; i < 2; i++)
              Fragment(
                sequence: i + 1,
                tracks: [
                  FragmentTrack(
                    time: i * samples.length,
                    samples: samples,
                    durations: List.filled(samples.length, 1),
                  ),
                ],
              ),
          ],
        ),
      ),
      bad(SubtitleParseReason.limitExceeded),
    );
  });
  test(
    'changing sample descriptions does not reset nested box allowance',
    () async {
      final samples = structureSamples(100000);
      await expectLater(
        parse(
          mp4(
            tracks: [
              Mp4Track(
                entries: [
                  wvttEntry(),
                  wvttEntry(config: 'WEBVTT second'),
                ],
                samples: [...samples, ...samples],
                durations: List.filled(samples.length * 2, 1),
                chunkSizes: [samples.length, samples.length],
                descriptionIndices: [1, 2],
              ),
            ],
          ),
        ),
        bad(SubtitleParseReason.limitExceeded),
      );
    },
  );
  for (final extra in [false, true]) {
    test(
      'TTML configuration shares resource allowance (extra=$extra)',
      () async {
        final samples = structureSamples(199962);
        final file = mp4(
          tracks: [
            Mp4Track(
              entry: wvttEntry(),
              samples: samples,
              durations: List.filled(samples.length, 1),
            ),
            Mp4Track(
              id: 2,
              samples: [],
              durations: [],
              entry: stppEntry(
                extra: extra ? box('btrt', List.filled(12, 0)) : [],
              ),
            ),
          ],
        );
        // Common 5 + WebVTT 17 + TTML 16 boxes; optional btrt is the 200001st.
        if (extra) {
          await expectLater(
            parse(file),
            bad(SubtitleParseReason.limitExceeded),
          );
        } else {
          expect((await parse(file)).map((t) => t.track.id), [
            'mp4:1',
            'mp4:2',
          ]);
        }
      },
    );
  }
}
