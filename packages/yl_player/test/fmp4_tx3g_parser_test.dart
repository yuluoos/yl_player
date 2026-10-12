import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'support/fmp4_fixture.dart';
import 'mp4_parser_test.dart' show parse, bad, edits;
import 'fmp4_parser_test.dart' show defaults;

Mp4Track tx({int id = 1, List<int>? entry, List<int>? edit}) => Mp4Track(
  id: id,
  entry: entry ?? description(),
  edits: edit,
  samples: [],
  durations: [],
);
List<int> movie(List<int> sample, {List<int>? entry, int duration = 1000}) =>
    fragmented(
      tracks: [tx(entry: entry)],
      fragments: [
        Fragment(
          tracks: [
            FragmentTrack(samples: [sample], durations: [duration]),
          ],
        ),
      ],
    );
void main() {
  for (final le in [false, true]) {
    test(
      'fragmented UTF16 ${le ? 'LE' : 'BE'} preserves surrogate pairs',
      () async {
        final b = [
          ...(le ? [255, 254] : [254, 255]),
          for (final n in 'A😀中'.codeUnits)
            ...(le ? num(n, 2).reversed : num(n, 2)),
        ];
        final d = await parse(movie([...num(b.length, 2), ...b]));
        expect(d.single.packets.single.text, 'A😀中');
      },
    );
  }
  test(
    'sample-local styl uses Unicode scalar offsets and literal text',
    () async {
      final d = await parse(
        movie(
          textSample(
            '😀<b>中',
            extra: box('styl', [
              ...num(1, 2),
              ...style(start: 1, end: 4, face: 7, color: 0xff000080, size: 24),
            ]),
          ),
        ),
      );
      final runs = d.single.packets.single.textRuns!;
      expect(runs.map((r) => r.text), ['😀', '<b>', '中']);
      expect(runs[1].bold && runs[1].italic && runs[1].underline, true);
      expect(runs[1].color, 0x80ff0000);
      expect(runs[1].fontSize, 24);
      expect(runs[1].fontFamily, 'Arial');
    },
  );
  test(
    'tfhd description switch changes default style without stale state',
    () async {
      final d = await parse(
        fragmented(
          tracks: [
            Mp4Track(
              samples: [],
              durations: [],
              entries: [
                description(defaults: style(face: 1)),
                description(defaults: style(face: 2, color: 0xff0000ff)),
              ],
            ),
          ],
          fragments: [
            Fragment(
              tracks: [
                FragmentTrack(samples: [textSample('a')]),
              ],
            ),
            Fragment(
              sequence: 2,
              tracks: [
                FragmentTrack(
                  time: 1000,
                  description: 2,
                  samples: [textSample('b')],
                ),
              ],
            ),
          ],
        ),
      );
      final a = d.single.packets[0].textRuns!.single,
          b = d.single.packets[1].textRuns!.single;
      expect(a.bold, true);
      expect(a.italic, false);
      expect(b.bold, false);
      expect(b.italic, true);
      expect(b.color, 0xffff0000);
    },
  );
  for (final tfhd in [false, true]) {
    test(
      'tx3g sample size/duration inherited from ${tfhd ? 'tfhd' : 'trex'}',
      () async {
        final sample = textSample('inherited');
        final d = await parse(
          fragmented(
            tracks: [tx()],
            trex: defaults(
              size: tfhd ? 2 : sample.length,
              duration: tfhd ? 0 : 1500,
            ),
            fragments: [
              Fragment(
                tracks: [
                  FragmentTrack(
                    time: 2000,
                    samples: [sample],
                    writeDurations: false,
                    writeSizes: false,
                    defaultSize: tfhd ? sample.length : null,
                    defaultDuration: tfhd ? 1500 : null,
                  ),
                ],
              ),
            ],
          ),
        );
        final p = d.single.packets.single;
        expect(p.text, 'inherited');
        expect(p.start, const Duration(seconds: 2));
        expect(p.end, const Duration(milliseconds: 3500));
      },
    );
  }
  for (final duration in [0, 1500]) {
    test('fragment tx3g signed CTO and edit duration=$duration', () async {
      final d = await parse(
        fragmented(
          tracks: [
            tx(edit: edits([(500, -1), (duration, 1000)])),
          ],
          fragments: [
            Fragment(
              tracks: [
                FragmentTrack(
                  time: 2000,
                  cts: [-500],
                  samples: [textSample('clipped')],
                  durations: [2000],
                ),
              ],
            ),
          ],
        ),
      );
      final p = d.single.packets.single;
      expect(p.start, const Duration(seconds: 1));
      expect(p.end, Duration(milliseconds: duration == 0 ? 3000 : 2000));
    });
  }
  test(
    'empty terminal zero-duration sample and sparse fragment gap clear text',
    () async {
      final d = await parse(
        fragmented(
          tracks: [tx()],
          fragments: [
            Fragment(
              tracks: [
                FragmentTrack(
                  samples: [textSample('a'), textSample('')],
                  durations: [1000, 0],
                ),
              ],
            ),
            Fragment(
              sequence: 2,
              tracks: [
                FragmentTrack(time: 5000, samples: [textSample('b')]),
              ],
            ),
          ],
        ),
      );
      expect(d.single.packets.map((p) => p.text), ['a', 'b']);
      expect(d.single.packets.map((p) => p.start.inMilliseconds), [0, 5000]);
      expect(d.single.packets.first.end, const Duration(seconds: 1));
    },
  );
  test(
    'forced metadata and shared-language identities survive reordered trafs',
    () async {
      final d = await parse(
        fragmented(
          tracks: [
            tx(id: 3, entry: description(display: 0xc0000000)),
            tx(id: 8),
          ],
          fragments: [
            Fragment(
              tracks: [
                FragmentTrack(id: 8, samples: [textSample('normal')]),
                FragmentTrack(id: 3, samples: [textSample('forced')]),
              ],
            ),
          ],
        ),
      );
      expect(d.map((d) => d.track.id), ['mp4:3', 'mp4:8']);
      expect(d.first.track.role, 'forced');
      expect(d.last.track.role, isNull);
      expect(d.first.packets.single.text, 'forced');
    },
  );
  for (final range in [(0, 2), (0, 3)]) {
    test(
      'CRLF across tx3g styles $range in fragment remains one newline',
      () async {
        final d = await parse(
          movie(
            textSample(
              'a\r\nb',
              extra: box('styl', [
                ...num(1, 2),
                ...style(start: range.$1, end: range.$2, face: 1),
              ]),
            ),
          ),
        );
        expect(d.single.packets.single.text, 'a\nb');
      },
    );
  }
  for (final e in <String, List<int>>{
    'short string payload': [0, 4, 65],
    'bad UTF8': [0, 1, 255],
    'isolated UTF16 surrogate': [0, 4, 254, 255, 216, 0],
    'style outside text': textSample(
      'a',
      extra: box('styl', [...num(1, 2), ...style(end: 2)]),
    ),
    'zero visible duration': textSample('text'),
  }.entries) {
    test(
      'fragmented malformed ${e.key}',
      () async => expectLater(
        parse(
          movie(e.value, duration: e.key == 'zero visible duration' ? 0 : 1000),
        ),
        bad(),
      ),
    );
  }
  for (final e in <String, List<int>>{
    'karaoke': textSample('x', extra: box('krok', [])),
    'per-sample forced': textSample('x', extra: box('frcd', [])),
    'unknown font': textSample(
      'x',
      extra: box('styl', [...num(1, 2), ...style(end: 1, font: 2)]),
    ),
  }.entries) {
    test(
      'fragmented unsupported ${e.key}',
      () async => expectLater(
        parse(movie(e.value)),
        bad(SubtitleParseReason.unsupported),
      ),
    );
  }
  test('hybrid tx3g initial sample table still rejected', () async {
    await expectLater(
      parse(fragmented(tracks: [Mp4Track()])),
      bad(SubtitleParseReason.unsupported),
    );
  });
  test('same track cannot switch tx3g to WebVTT description', () async {
    await expectLater(
      parse(
        fragmented(
          tracks: [
            Mp4Track(
              entries: [description(), wvttEntry()],
              samples: [],
              durations: [],
            ),
          ],
        ),
      ),
      bad(SubtitleParseReason.unsupported),
    );
  });
  test('fragmented tx3g text bound is enforced', () async {
    await expectLater(
      parse(movie(textSample('x' * 16385))),
      bad(SubtitleParseReason.limitExceeded),
    );
  });
  test('raw tx3g bytes share four MiB budget across fragments', () async {
    final sample = textSample('x' * 16384);
    await expectLater(
      parse(
        fragmented(
          tracks: [tx()],
          fragments: [
            for (var n = 0; n < 2; n++)
              Fragment(
                sequence: n + 1,
                tracks: [
                  FragmentTrack(
                    time: n * 130,
                    samples: List.filled(130, sample),
                    durations: List.filled(130, 1),
                  ),
                ],
              ),
          ],
        ),
      ),
      bad(SubtitleParseReason.limitExceeded),
    );
  });
}
