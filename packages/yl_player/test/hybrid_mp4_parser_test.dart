import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'support/fmp4_fixture.dart';
import 'mp4_parser_test.dart' show parse, bad, edits;
import 'fmp4_parser_test.dart' show change;

List<int> hybrid({Mp4Track? track, FragmentTrack? fragment}) => fragmented(
  tracks: [track ?? Mp4Track()],
  fragments: [
    Fragment(
      tracks: [
        fragment ?? FragmentTrack(time: 1000, samples: [textSample('later')]),
      ],
    ),
  ],
);
int field(List<int> b, String type, int offset) => b
    .sublist(
      ascii.decode(b, allowInvalid: true).indexOf(type) + 4 + offset,
      ascii.decode(b, allowInvalid: true).indexOf(type) + 8 + offset,
    )
    .fold(0, (n, v) => n * 256 + v);
void main() {
  for (final format in ['tx3g', 'wvtt', 'stpp']) {
    test('$format initial-only mvex track remains available', () async {
      final entry = switch (format) {
        'wvtt' => wvttEntry(),
        'stpp' => stppEntry(),
        _ => description(),
      };
      final sample = switch (format) {
        'wvtt' => vttCue('initial'),
        'stpp' => stppSample('<p begin="0s" end="1s">initial</p>'),
        _ => textSample('initial'),
      };
      final d = await parse(
        fragmented(
          tracks: [
            Mp4Track(entry: entry, samples: [sample]),
          ],
          fragments: [],
        ),
      );
      expect(d.single.packets.single.text, 'initial');
      expect(d.single.packets.single.end, const Duration(seconds: 1));
    });
  }
  for (final cto in [-500, 10000]) {
    test('initial ctts=$cto does not define fragment decode floor', () async {
      final d = await parse(
        hybrid(
          track: Mp4Track(
            ctts: full('ctts', [...num(1), ...num(1), ...num(cto)], version: 1),
          ),
        ),
      );
      expect(d.single.packets.first.start.inMilliseconds, cto < 0 ? 0 : 10000);
      expect(d.single.packets.last.start, const Duration(seconds: 1));
    });
  }
  for (final initialEdit in [false, true]) {
    test(
      'reject decode overlap even when initial ${initialEdit ? 'edited out' : 'presentation shortened'}',
      () async {
        await expectLater(
          parse(
            hybrid(
              track: Mp4Track(
                edits: initialEdit ? edits([(0, 1000)]) : null,
                ctts: initialEdit
                    ? null
                    : full('ctts', [
                        ...num(1),
                        ...num(1),
                        ...num(-500),
                      ], version: 1),
              ),
              fragment: FragmentTrack(
                time: 500,
                samples: [textSample('later')],
              ),
            ),
          ),
          bad(),
        );
      },
    );
  }
  for (final duration in [0, 1000]) {
    test(
      'edit duration=$duration maps both portions once and retains gap',
      () async {
        final d = await parse(
          hybrid(
            track: Mp4Track(edits: edits([(500, -1), (duration, 500)])),
            fragment: FragmentTrack(time: 1500, samples: [textSample('later')]),
          ),
        );
        expect(d.single.packets.first.start, const Duration(milliseconds: 500));
        expect(d.single.packets.first.end, const Duration(seconds: 1));
        if (duration == 0) {
          expect(
            d.single.packets.last.start,
            const Duration(milliseconds: 1500),
          );
        } else {
          expect(d.single.packets.length, 1);
        }
      },
    );
  }
  test(
    'trex/tfhd description selects different style than initial stsc',
    () async {
      final d = await parse(
        hybrid(
          track: Mp4Track(
            entries: [
              description(defaults: style(face: 1)),
              description(defaults: style(face: 2)),
            ],
          ),
          fragment: FragmentTrack(
            time: 1000,
            description: 2,
            samples: [textSample('later')],
          ),
        ),
      );
      expect(d.single.packets.first.textRuns!.single.bold, true);
      expect(d.single.packets.last.textRuns!.single.italic, true);
      expect(d.single.packets.last.textRuns!.single.bold, false);
    },
  );
  test(
    'TTML region ids and raw bytes remain distinct across both portions',
    () async {
      List<int> xml(String begin, String end, String x) => stppSample(
        '<p begin="$begin" end="$end" region="r">text</p>',
        head:
            '<head><layout><region xml:id="r" tts:origin="$x% 60%" tts:extent="40% 30%"/></layout></head>',
      );
      final a = xml('0s', '2s', '10'), b = xml('0s', '2s', '50');
      final d = await parse(
        hybrid(
          track: Mp4Track(entry: stppEntry(), samples: [a]),
          fragment: FragmentTrack(time: 1000, cts: [-500], samples: [b]),
        ),
      );
      expect(d.single.sourceBytes, a.length + b.length);
      final p = d.single.packets;
      expect(p.map((c) => c.region!.id).toSet().length, 2);
      expect(p.first.region!.x, .1);
      expect(p.last.region!.x, .5);
      expect(p.last.start, const Duration(milliseconds: 500));
    },
  );
  test('empty initial sample still advances decode floor', () async {
    await expectLater(
      parse(
        hybrid(
          track: Mp4Track(samples: [textSample('')]),
          fragment: FragmentTrack(time: 0, samples: [textSample('later')]),
        ),
      ),
      bad(),
    );
  });
  test('zero-duration empty initial sample permits fragment at zero', () async {
    final d = await parse(
      hybrid(
        track: Mp4Track(samples: [textSample('')], durations: [0]),
        fragment: FragmentTrack(time: 0, samples: [textSample('later')]),
      ),
    );
    expect(d.single.packets.single.text, 'later');
  });
  test('fragment cannot reuse initial sample bytes', () async {
    final b = hybrid();
    final offset = field(b, 'stco', 8);
    await expectLater(
      parse(
        hybrid(
          fragment: FragmentTrack(
            time: 1000,
            base: 'explicit',
            baseValue: offset,
            omitFirstOffset: true,
            samples: [textSample('hello')],
          ),
        ),
      ),
      bad(),
    );
  });
  test('initial subtitle byte extents cannot overlap across tracks', () async {
    var b = fragmented(tracks: [Mp4Track(), Mp4Track(id: 2)], fragments: []);
    b = change(b, 'stco', 8, num(field(b, 'stco', 8)), occurrence: 1);
    await expectLater(parse(b), bad());
  });
  test('nonoverlapping initial and fragment extents remain accepted', () async {
    final d = await parse(hybrid());
    expect(d.single.packets.map((p) => p.text), ['hello', 'later']);
  });
  test(
    'subtitle tracks with different initial durations keep separate decode floors',
    () async {
      final d = await parse(
        fragmented(
          tracks: [
            Mp4Track(id: 4, durations: [3000]),
            Mp4Track(id: 7, durations: [1000]),
          ],
          fragments: [
            Fragment(
              tracks: [
                FragmentTrack(
                  id: 7,
                  time: 1000,
                  samples: [textSample('short')],
                ),
                FragmentTrack(id: 4, time: 3000, samples: [textSample('long')]),
              ],
            ),
          ],
        ),
      );
      expect(d.map((t) => t.track.id), ['mp4:4', 'mp4:7']);
      expect(d.map((t) => t.packets.last.start.inMilliseconds), [3000, 1000]);
    },
  );
  test(
    'sample count budget accumulates initial and fragment samples',
    () async {
      final empty = box('vtte', []);
      await expectLater(
        parse(
          hybrid(
            track: Mp4Track(
              entry: wvttEntry(),
              samples: List.filled(11000, empty),
              durations: List.filled(11000, 1),
            ),
            fragment: FragmentTrack(
              time: 11000,
              samples: List.filled(10000, empty),
              durations: List.filled(10000, 1),
            ),
          ),
        ),
        bad(SubtitleParseReason.limitExceeded),
      );
    },
  );
  test('cue budget accumulates initial and fragment samples', () async {
    final cue = vttCue('x');
    await expectLater(
      parse(
        hybrid(
          track: Mp4Track(
            entry: wvttEntry(),
            samples: List.filled(5500, cue),
            durations: List.filled(5500, 1),
          ),
          fragment: FragmentTrack(
            time: 5500,
            samples: List.filled(5000, cue),
            durations: List.filled(5000, 1),
          ),
        ),
      ),
      bad(SubtitleParseReason.limitExceeded),
    );
  });
  test(
    'raw XML budget counts empty initial and fragmented documents',
    () async {
      final empty = stppSample('<!--${'x' * 150000}-->');
      await expectLater(
        parse(
          hybrid(
            track: Mp4Track(
              entry: stppEntry(),
              samples: List.filled(14, empty),
              durations: List.filled(14, 1),
            ),
            fragment: FragmentTrack(
              time: 14,
              samples: List.filled(15, empty),
              durations: List.filled(15, 1),
            ),
          ),
        ),
        bad(SubtitleParseReason.limitExceeded),
      );
    },
  );
  test(
    'bad initial text cannot be hidden by an edit before valid fragments',
    () async {
      await expectLater(
        parse(
          hybrid(
            track: Mp4Track(
              samples: [
                [0, 1, 255],
              ],
              edits: edits([(0, 1000)]),
            ),
          ),
        ),
        bad(),
      );
    },
  );
}
