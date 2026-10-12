import 'dart:convert';
import 'package:yl_player/yl_player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'package:yl_player/src/subtitles/subtitle_resource.dart';
import 'support/fmp4_fixture.dart';
import 'mp4_parser_test.dart' show parse, bad, edits;

Mp4Track init({
  int id = 1,
  int scale = 1000,
  List<int>? entry,
  List<int>? edit,
}) => Mp4Track(
  id: id,
  scale: scale,
  entry: entry ?? wvttEntry(),
  edits: edit,
  samples: [],
  durations: [],
);
List<int> defaults({
  int id = 1,
  int description = 1,
  int duration = 0,
  int size = 0,
  int flags = 0,
}) => full('trex', [
  ...num(id),
  ...num(description),
  ...num(duration),
  ...num(size),
  ...num(flags),
]);
List<int> change(
  List<int> b,
  String type,
  int offset,
  List<int> value, {
  int occurrence = 0,
}) {
  final out = [...b], tag = ascii.encode(type);
  final starts = [
    for (var i = 0; i < b.length - 4; i++)
      if (List.generate(4, (k) => b[i + k] == tag[k]).every((x) => x)) i + 4,
  ];
  final start = starts[occurrence] + offset;
  out.setRange(start, start + value.length, value);
  return out;
}

List<int> one(
  FragmentTrack t, {
  List<int>? trex,
  List<Mp4Track>? tracks,
  bool large = false,
  bool dataFirst = false,
}) => fragmented(
  tracks: tracks,
  trex: trex,
  fragments: [
    Fragment(tracks: [t], large: large, dataFirst: dataFirst),
  ],
);
void main() {
  for (final leading in [0, 1, 2, 3]) {
    test('legal is_leading=$leading sample flags', () async {
      expect(
        (await parse(
          one(FragmentTrack(sampleFlags: [leading << 26])),
        )).single.packets.single.text,
        'hello',
      );
    });
  }
  for (final base in ['moof', 'explicit', 'implicit']) {
    for (final large in [false, true]) {
      test(
        '$base base with ${large ? 64 : 32}-bit boxes and negative data offset',
        () async {
          final d = (await parse(
            one(
              FragmentTrack(
                base: base,
                baseValue: base == 'explicit' ? 0 : null,
                time: 2000,
              ),
              large: large,
              dataFirst: true,
            ),
          )).single;
          expect(d.packets.single.start, const Duration(seconds: 2));
          expect(d.packets.single.end, const Duration(seconds: 3));
        },
      );
    }
  }
  test(
    'trex defaults inherited, tfhd overrides, then per-sample overrides',
    () async {
      final sample = vttCue('hello');
      for (final mode in [0, 1, 2]) {
        final d = (await parse(
          one(
            FragmentTrack(
              writeDurations: mode == 2,
              writeSizes: mode == 2,
              defaultDuration: mode == 1 ? 1000 : null,
              defaultSize: mode == 1 ? sample.length : null,
            ),
            trex: defaults(
              duration: mode == 0 ? 1000 : 7,
              size: mode == 0 ? sample.length : 2,
            ),
          ),
        )).single;
        expect(d.packets.single.end, const Duration(seconds: 1));
        expect(d.packets.single.text, 'hello');
      }
    },
  );
  test(
    'multiple truns continue byte cursor, composition offsets remain independent of dts',
    () async {
      final d = (await parse(
        one(
          FragmentTrack(
            time: 1000,
            samples: [vttCue('a'), vttCue('b'), vttCue('c')],
            durations: [1000, 1000, 1000],
            cts: [-500, 500, 0],
            runCounts: [1, 2],
          ),
        ),
      )).single;
      expect(d.packets.map((p) => p.text), ['a', 'b', 'c']);
      expect(d.packets.map((p) => p.start.inMilliseconds), [500, 2500, 3000]);
    },
  );
  test('unsigned v0 composition offset and v0 decode time', () async {
    final d = (await parse(
      one(
        FragmentTrack(time: 1000, timeVersion: 0, runVersion: 0, cts: [1500]),
      ),
    )).single;
    expect(d.packets.single.start, const Duration(milliseconds: 2500));
  });
  test('64-bit tfdt exceeds uint32 without losing precision', () async {
    final d = (await parse(
      one(
        FragmentTrack(time: 0x100000001, durations: [90000]),
        tracks: [init(scale: 90000)],
      ),
    )).single;
    expect(
      d.packets.single.start.inMicroseconds,
      0x100000001 * 1000000 ~/ 90000,
    );
  });
  for (final duration in [0, 1500]) {
    test(
      'TTML composition clock clipped then edited once; edit duration $duration',
      () async {
        final d = (await parse(
          one(
            FragmentTrack(
              time: 2000,
              durations: [2000],
              cts: [-500],
              samples: [stppSample('<p begin="1.75s" end="6s">text</p>')],
            ),
            tracks: [
              init(
                entry: stppEntry(),
                edit: edits([(500, -1), (duration, 1000)]),
              ),
            ],
          ),
        )).single;
        expect(d.packets.single.start, const Duration(milliseconds: 1250));
        expect(
          d.packets.single.end,
          Duration(milliseconds: duration == 0 ? 3000 : 2000),
        );
      },
    );
  }
  test('decode gaps and sequence gaps retain absolute time', () async {
    final d = (await parse(
      fragmented(
        fragments: [
          Fragment(),
          Fragment(sequence: 3, tracks: [FragmentTrack(time: 5000)]),
        ],
      ),
    )).single;
    expect(d.packets.map((p) => p.start.inMilliseconds), [0, 5000]);
  });
  test(
    'audio traf payload skipped; following subtitle has explicit moof base',
    () async {
      final d = await parse(
        fragmented(
          tracks: [
            init(id: 4),
            Mp4Track(id: 8, handler: 'vide', samples: [], durations: []),
          ],
          fragments: [
            Fragment(
              tracks: [
                FragmentTrack(id: 8, samples: [List.filled(300000, 255)]),
                FragmentTrack(id: 4, time: 1000),
              ],
            ),
          ],
        ),
      );
      expect(d.single.track.id, 'mp4:4');
      expect(d.single.packets.single.text, 'hello');
    },
  );
  test(
    'initialization only and empty duration fragment yield empty catalog track',
    () async {
      for (final fs in [
        <Fragment>[],
        [
          Fragment(
            tracks: [
              FragmentTrack(
                samples: [],
                durations: [],
                durationEmpty: true,
                runCounts: [],
              ),
            ],
          ),
        ],
      ]) {
        expect(
          (await parse(fragmented(fragments: fs))).single.packets,
          isEmpty,
        );
      }
    },
  );
  test(
    'selected sample description overrides trex without changing public codec',
    () async {
      final d = await parse(
        one(
          FragmentTrack(description: 2),
          tracks: [
            Mp4Track(
              entries: [wvttEntry(), wvttEntry()],
              samples: [],
              durations: [],
            ),
          ],
        ),
      );
      expect(d.single.packets.single.text, 'hello');
    },
  );
  test(
    'empty WebVTT sample clears interval and TTML empty XML still counts raw bytes',
    () async {
      final empty = stppSample('');
      final d = (await parse(
        one(
          FragmentTrack(samples: [empty]),
          tracks: [init(entry: stppEntry())],
        ),
      )).single;
      expect(d.packets, isEmpty);
      expect(d.sourceBytes, empty.length);
      final v = (await parse(
        one(FragmentTrack(samples: [box('vtte', [])])),
      )).single;
      expect(v.packets, isEmpty);
    },
  );
  final malformed = <String, List<int>>{
    'duplicate trex': fragmented(trex: [...defaults(), ...defaults()]),
    'unknown trex track': fragmented(trex: defaults(id: 9)),
    'zero trex description': fragmented(trex: defaults(description: 0)),
    'duplicate mfhd': fragmented(
      fragments: [Fragment(extra: full('mfhd', num(1)))],
    ),
    'unknown tfhd track': one(FragmentTrack(id: 9)),
    'duplicate tfhd': one(
      FragmentTrack(extra: full('tfhd', num(1), flags: 0x020000)),
    ),
    'duplicate tfdt': one(FragmentTrack(extra: full('tfdt', num(0)))),
    'conflicting bases': one(
      FragmentTrack(base: 'explicit', tfhdExtraFlags: 0x020000),
    ),
    'description out of range': one(FragmentTrack(description: 2)),
    'zero size override does not inherit': one(
      FragmentTrack(writeSizes: false, defaultSize: 0),
      trex: defaults(size: vttCue('hello').length),
    ),
    'zero duration override does not inherit': one(
      FragmentTrack(writeDurations: false, defaultDuration: 0),
      trex: defaults(duration: 1000),
    ),
    'empty duration with samples': one(FragmentTrack(durationEmpty: true)),
    'both first and per sample flags': one(
      FragmentTrack(firstFlags: 0, sampleFlags: [0]),
    ),
    'reserved flags': one(FragmentTrack(defaultFlags: 0x80000000)),
    'reserved depends on': one(FragmentTrack(sampleFlags: [3 << 24])),
    'reserved depended on': one(FragmentTrack(firstFlags: 3 << 22)),
    'reserved redundancy': one(FragmentTrack(defaultFlags: 3 << 20)),
    'data points to moof': one(FragmentTrack(omitFirstOffset: true)),
    'duplicate sequence': fragmented(fragments: [Fragment(), Fragment()]),
    'overlapping decode timeline': fragmented(
      fragments: [
        Fragment(),
        Fragment(sequence: 2, tracks: [FragmentTrack(time: 500)]),
      ],
    ),
    'wrong tfdt length': change(fragmented(), 'tfdt', 0, [0]),
    'wrong trun length': change(fragmented(), 'trun', 4, num(2)),
    'mdat byte extent overflow': change(fragmented(), 'trun', 16, num(9999)),
    'no traf': fragmented(fragments: [Fragment(tracks: [])]),
    'missing trex for subtitle': fragmented(
      tracks: [init(), init(id: 2)],
      trex: defaults(),
    ),
  };
  for (final e in malformed.entries) {
    test(
      'reject malformed ${e.key}',
      () async => expectLater(parse(e.value), bad()),
    );
  }
  final unsupported = <String, List<int>>{
    'missing tfdt': one(FragmentTrack(omitTime: true)),
    'unknown tfhd flags': one(FragmentTrack(tfhdExtraFlags: 0x40)),
    'unknown trun flags': one(FragmentTrack(trunExtraFlags: 0x10)),
    'unsupported trun version': one(FragmentTrack(runVersion: 2)),
    'unsupported tfdt version': one(FragmentTrack(timeVersion: 2)),
    'encrypted samples': one(FragmentTrack(extra: box('senc', []))),
    'subsample table': one(FragmentTrack(extra: box('subs', []))),
    'hybrid subtitle samples': fragmented(
      tracks: [
        Mp4Track(entry: wvttEntry(), samples: [vttCue('x')]),
      ],
    ),
    'fragmented unknown codec': fragmented(
      tracks: [init(entry: description(codec: 'text'))],
    ),
    'implicit base after audio': fragmented(
      tracks: [
        init(),
        Mp4Track(id: 2, handler: 'soun', samples: [], durations: []),
      ],
      fragments: [
        Fragment(
          tracks: [
            FragmentTrack(id: 2),
            FragmentTrack(base: 'implicit'),
          ],
        ),
      ],
    ),
  };
  for (final e in unsupported.entries) {
    test(
      'reject unsupported ${e.key}',
      () async =>
          expectLater(parse(e.value), bad(SubtitleParseReason.unsupported)),
    );
  }
  for (final e in <String, List<int>>{
    'sample count': change(fragmented(), 'trun', 4, num(20001)),
    'decode time': one(FragmentTrack(time: 604800001)),
    'composition time': one(FragmentTrack(cts: [604800001])),
    'top level fragments': fragmented(
      fragments: [
        for (var i = 0; i < 1400; i++)
          Fragment(
            sequence: i + 1,
            tracks: [FragmentTrack(time: i * 1000)],
          ),
      ],
    ),
  }.entries) {
    test(
      'bounded ${e.key}',
      () async =>
          expectLater(parse(e.value), bad(SubtitleParseReason.limitExceeded)),
    );
  }
  test('overlapping byte extents between subtitle trafs reject', () async {
    var b = fragmented(
      tracks: [init(), init(id: 2)],
      fragments: [
        Fragment(tracks: [FragmentTrack(), FragmentTrack(id: 2)]),
      ],
    );
    final at = ascii.decode(b, allowInvalid: true).indexOf('trun') + 4;
    b = change(b, 'trun', 8, b.sublist(at + 8, at + 12), occurrence: 1);
    await expectLater(parse(b), bad());
  });
  test(
    'sample flags default can be replaced by first sample override',
    () async {
      final d = await parse(
        one(FragmentTrack(defaultFlags: 0xf0000000, firstFlags: 0)),
      );
      expect(d.single.packets.single.text, 'hello');
    },
  );
  test('empty TTML raw samples enforce shared four MiB budget', () async {
    final sample = stppSample('<!--${'x' * 150000}-->');
    await expectLater(
      parse(
        one(
          FragmentTrack(
            samples: List.filled(29, sample),
            durations: List.filled(29, 1000),
          ),
          tracks: [init(entry: stppEntry())],
        ),
      ),
      bad(SubtitleParseReason.limitExceeded),
    );
  });
  test('global sample budget spans fragments', () async {
    final a = FragmentTrack(
      samples: List.filled(11000, box('vtte', [])),
      durations: List.filled(11000, 1),
    );
    final b = FragmentTrack(
      time: 11000,
      samples: List.filled(10000, box('vtte', [])),
      durations: List.filled(10000, 1),
    );
    await expectLater(
      parse(
        fragmented(
          fragments: [
            Fragment(tracks: [a]),
            Fragment(sequence: 2, tracks: [b]),
          ],
        ),
      ),
      bad(SubtitleParseReason.limitExceeded),
    );
  });
  test('all truncated prefixes reject without untyped errors', () async {
    final b = fragmented();
    for (var n = 0; n < b.length; n++) {
      try {
        await parse(b.sublist(0, n));
      } on SubtitleParseException {
        continue;
      }
      // Complete initialization / top-level boundaries may legally have no fragments.
      expect(n, greaterThan(500));
    }
  });
  test('cancellation is checked between fragment reads', () async {
    final token = SubtitleCancellation()..cancel();
    await expectLater(
      parse(fragmented(), token: token),
      throwsA(
        isA<YlPlayerException>().having(
          (e) => e.failure.code,
          'code',
          YlFailureCodes.loadCancelled,
        ),
      ),
    );
  });
}
