import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'support/tx3g_structure_fixture.dart';
import 'mp4_parser_test.dart' show parse, bad;

void main() {
  test('tx3g configuration children accumulate across tracks', () async {
    await expectLater(
      parse(configurationFile(200000)),
      bad(SubtitleParseReason.limitExceeded),
    );
  });
  for (final layout in ['ordinary', 'fragmented', 'hybrid']) {
    test('$layout tx3g modifiers share the WVTT resource allowance', () async {
      // No styles would be exactly200000. Each style is one additional box.
      final overhead = layout == 'ordinary' ? 39 : 51;
      await expectLater(
        parse(modifierFile(layout, 200000 - overhead)),
        bad(SubtitleParseReason.limitExceeded),
      );
    });
  }
  for (final over in [false, true]) {
    test('tx3g configuration exact boundary (overflow=$over)', () async {
      final file = configurationFile(over ? 199707 : 199706);
      if (over) {
        await expectLater(parse(file), bad(SubtitleParseReason.limitExceeded));
      } else {
        final tracks = await parse(file);
        expect(tracks.length, 17);
        expect(tracks.every((t) => t.packets.isEmpty), true);
      }
    });
  }
  for (final layout in ['ordinary', 'fragmented', 'hybrid']) {
    final overhead = layout == 'ordinary' ? 39 : 51;
    final styles = layout == 'hybrid' ? 2 : 1;
    for (final spare in [0, 1]) {
      test('$layout modifier boundary with $spare boxes remaining', () async {
        final tracks = await parse(
          modifierFile(layout, 200000 - overhead - styles - spare),
        );
        expect(tracks.map((t) => t.track.id), ['mp4:1', 'mp4:2']);
        expect(tracks.every((t) => t.packets.isEmpty), true);
      });
    }
    test('$layout plain text is not charged as a modifier box', () async {
      expect(
        (await parse(
          modifierFile(layout, 200000 - overhead, styled: false),
        )).length,
        2,
      );
    });
  }
  for (final over in [false, true]) {
    test(
      'description switches share modifier allowance (overflow=$over)',
      () async {
        final filler = structureSamples(over ? 199958 : 199957);
        final file = mp4(
          tracks: [
            Mp4Track(
              entry: wvttEntry(),
              samples: filler,
              durations: List.filled(filler.length, 1),
            ),
            Mp4Track(
              id: 2,
              entries: [
                description(),
                description(defaults: style(face: 1)),
              ],
              samples: [styledEmpty(), styledEmpty()],
              durations: [1, 1],
              chunkSizes: [1, 1],
              descriptionIndices: [1, 2],
            ),
          ],
        );
        // Common5 + WVTT17 + tx3g19 + two styl =43; remaining199957.
        if (over) {
          await expectLater(
            parse(file),
            bad(SubtitleParseReason.limitExceeded),
          );
        } else {
          expect((await parse(file)).length, 2);
        }
      },
    );
    test(
      'separate fragments share modifier allowance (overflow=$over)',
      () async {
        final filler = structureSamples(over ? 199940 : 199939);
        final file = fragmented(
          tracks: [
            Mp4Track(
              entry: wvttEntry(),
              samples: filler,
              durations: List.filled(filler.length, 1),
            ),
            Mp4Track(id: 2, samples: [], durations: []),
          ],
          fragments: [
            for (var i = 0; i < 2; i++)
              Fragment(
                sequence: i + 1,
                tracks: [
                  FragmentTrack(
                    id: 2,
                    time: i,
                    samples: [styledEmpty()],
                    durations: [1],
                  ),
                ],
              ),
          ],
        );
        // Common/track39 + mvex/trex/free4 + two fragments16 + two styl =61.
        if (over) {
          await expectLater(
            parse(file),
            bad(SubtitleParseReason.limitExceeded),
          );
        } else {
          expect((await parse(file)).length, 2);
        }
      },
    );
  }
}
