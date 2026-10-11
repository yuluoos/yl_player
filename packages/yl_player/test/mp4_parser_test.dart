import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/mp4_subtitles.dart';
import 'package:yl_player/src/subtitles/matroska_subtitles.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'package:yl_player/src/subtitles/subtitle_resource.dart';
import 'support/mp4_fixture.dart';

Future<List<EmbeddedSubtitleData>> parse(
  List<int> b, {
  SubtitleCancellation? token,
}) => Mp4Subtitles(
  b.length,
  (p, n) async => b.sublist(p, p + n),
  token ?? SubtitleCancellation(),
).parse();
SubtitleDocument doc(EmbeddedSubtitleData d) =>
    SubtitleDocument.fromEmbeddedPackets(d.packets, format: SubtitleFormat.srt);
Matcher bad([SubtitleParseReason r = SubtitleParseReason.malformed]) =>
    throwsA(isA<SubtitleParseException>().having((e) => e.reason, 'reason', r));
List<int> field(List<int> b, String type, int offset, List<int> value) {
  final out = [...b];
  final tag = ascii.encode(type);
  final at = [
    for (var i = 0; i < b.length - 4; i++)
      if (List.generate(4, (k) => b[i + k] == tag[k]).every((v) => v)) i,
  ].single;
  out.setRange(at + 4 + offset, at + 4 + offset + value.length, value);
  return out;
}

List<int> edits(List<(int, int)> rows, {int version = 0, int rate = 0x10000}) =>
    full('elst', [
      ...num(rows.length),
      for (final row in rows) ...[
        ...num(row.$1, version == 1 ? 8 : 4),
        ...num(row.$2, version == 1 ? 8 : 4),
        ...num(rate),
      ],
    ], version: version);
void main() {
  test(
    'independent FFmpeg muxed video and tx3g sample timing/styles',
    () async {
      final entries = await parse(
        await File(
          'packages/yl_player/test/fixtures/embedded-owned.mp4',
        ).readAsBytes(),
      );
      expect(entries.single.track.id, 'mp4:2');
      expect(entries.single.track.language, 'eng');
      final c = doc(entries.single).cues;
      expect(c.map((c) => c.payload), ['bold and 中文', 'second']);
      expect(c.map((c) => c.start.inMicroseconds), [1000000, 3123000]);
      expect(c.map((c) => c.end.inMicroseconds), [2500000, 4567000]);
      expect(c.first.textRuns!.first.bold, true);
    },
  );
  for (final fast in [false, true]) {
    test(
      'moov ${fast ? 'before' : 'after'} mdat; track identity independent of order and enabled flag',
      () async {
        final d = await parse(
          mp4(
            fastStart: fast,
            tracks: [
              Mp4Track(id: 9, enabled: false),
              Mp4Track(
                id: 3,
                language: 'fra',
                entry: description(display: 0xc0000000),
              ),
            ],
          ),
        );
        expect(d.map((t) => t.track.id), ['mp4:9', 'mp4:3']);
        expect(d.last.track.language, 'fra');
        expect(d.last.track.role, 'forced');
      },
    );
  }
  for (final compact in [false, true]) {
    test(
      'co64 and ${compact ? 'stz2' : 'stsz'} retain exact media times',
      () async {
        final d = await parse(
          mp4(
            tracks: [
              Mp4Track(
                co64: true,
                compact: compact,
                scale: 3000,
                durations: [1, 2],
                samples: [textSample('a'), textSample('b')],
              ),
            ],
          ),
        );
        expect(doc(d.single).cues.map((c) => c.end.inMicroseconds), [
          333,
          1000,
        ]);
      },
    );
  }
  for (final version in [0, 1]) {
    test('edit v$version leading gap, trim and duration clipping', () async {
      final d = await parse(
        mp4(
          tracks: [
            Mp4Track(
              samples: [
                textSample('trimmed'),
                textSample('a'),
                textSample('b'),
              ],
              durations: [1000, 1000, 1000],
              edits: edits([(500, -1), (1500, 1000)], version: version),
            ),
          ],
        ),
      );
      final c = doc(d.single).cues;
      expect(c.map((c) => c.payload), ['a', 'b']);
      expect(c.map((c) => c.start.inMicroseconds), [500000, 1500000]);
      expect(c.last.end.inMicroseconds, 2000000);
    });
  }
  test('signed composition offsets clip before media start', () async {
    final d = await parse(
      mp4(
        tracks: [
          Mp4Track(
            ctts: full('ctts', [
              ...num(1),
              ...num(1),
              ...num(-500),
            ], version: 1),
          ),
        ],
      ),
    );
    final c = doc(d.single).cues.single;
    expect(c.start, Duration.zero);
    expect(c.end, const Duration(milliseconds: 500));
  });
  test(
    'style offsets count Unicode scalars and preserve literal markup',
    () async {
      final d = await parse(
        mp4(
          tracks: [
            Mp4Track(
              samples: [
                textSample(
                  '😀<b>中',
                  extra: box('styl', [
                    ...num(1, 2),
                    ...style(
                      start: 1,
                      end: 4,
                      face: 7,
                      color: 0xff000080,
                      size: 24,
                    ),
                  ]),
                ),
              ],
            ),
          ],
        ),
      );
      final runs = doc(d.single).cues.single.textRuns!;
      expect(runs.map((r) => r.text), ['😀', '<b>', '中']);
      expect(runs[1].bold, true);
      expect(runs[1].italic, true);
      expect(runs[1].underline, true);
      expect(runs[1].color, 0x80ff0000);
      expect(runs[1].fontSize, 24);
      expect(runs[1].fontFamily, 'Arial');
    },
  );
  for (final le in [false, true]) {
    test('strict UTF16 ${le ? 'LE' : 'BE'} BOM with surrogate pair', () async {
      final bytes = [
        ...(le ? [255, 254] : [254, 255]),
        for (final n in 'A😀中'.codeUnits)
          ...(le ? num(n, 2).reversed : num(n, 2)),
      ];
      final d = await parse(
        mp4(
          tracks: [
            Mp4Track(
              samples: [
                [...num(bytes.length, 2), ...bytes],
              ],
            ),
          ],
        ),
      );
      expect(doc(d.single).cues.single.payload, 'A😀中');
    });
  }
  test('empty terminal sample with zero duration creates no cue', () async {
    final d = await parse(
      mp4(
        tracks: [
          Mp4Track(
            samples: [textSample('a'), textSample('')],
            durations: [1000, 0],
          ),
        ],
      ),
    );
    expect(doc(d.single).cues.length, 1);
  });
  test('empty subtitle track is discovered', () async {
    final d = await parse(
      mp4(
        tracks: [Mp4Track(samples: [], durations: [])],
      ),
    );
    expect(d.length, 1);
    expect(doc(d.single).cues, isEmpty);
  });
  test('audio/video data and sparse free payload are not read', () async {
    final b = mp4(
      padding: 5000000,
      tracks: [
        Mp4Track(
          handler: 'vide',
          entry: description(codec: 'avc1'),
        ),
        Mp4Track(id: 2),
      ],
    );
    var total = 0;
    final d = await Mp4Subtitles(b.length, (p, n) async {
      total += n;
      return b.sublist(p, p + n);
    }, SubtitleCancellation()).parse();
    expect(d.single.track.id, 'mp4:2');
    expect(total, lessThan(10000));
  });

  test('chunk mapping changes sample count and description', () async {
    final d = await parse(
      mp4(
        tracks: [
          Mp4Track(
            samples: [textSample('a'), textSample('b'), textSample('c')],
            durations: [100, 200, 300],
            chunkSizes: [2, 1],
            entries: [
              description(),
              description(defaults: style(face: 1)),
            ],
            descriptionIndices: [1, 2],
          ),
        ],
      ),
    );
    final c = doc(d.single).cues;
    expect(c.map((c) => c.payload), ['a', 'b', 'c']);
    expect(c.map((c) => c.start.inMilliseconds), [0, 100, 300]);
    expect(c.last.textRuns!.single.bold, true);
    expect(c.first.textRuns!.single.bold, false);
  });
  for (final bits in [4, 8]) {
    test('compact sample sizes $bits bits including odd nibble', () async {
      final d = await parse(
        mp4(
          tracks: [
            Mp4Track(
              compact: true,
              sizeBits: bits,
              samples: [textSample('x'), textSample('yy'), textSample('zzz')],
              durations: [1, 1, 1],
            ),
          ],
        ),
      );
      expect(doc(d.single).cues.map((c) => c.payload), ['x', 'yy', 'zzz']);
    });
  }
  test('constant stsz size decodes all samples', () async {
    final d = await parse(
      mp4(
        tracks: [
          Mp4Track(
            commonSize: 3,
            samples: [textSample('x'), textSample('y')],
            durations: [1, 1],
          ),
        ],
      ),
    );
    expect(doc(d.single).cues.length, 2);
  });
  test(
    'edit subtraction preserves exact tick before microsecond conversion',
    () async {
      final d = await parse(
        mp4(
          tracks: [
            Mp4Track(
              scale: 3,
              samples: [textSample(''), textSample('x')],
              durations: [3, 3],
              edits: edits([(1000, 2)]),
            ),
          ],
        ),
      );
      expect(doc(d.single).cues.single.start.inMicroseconds, 333333);
    },
  );
  test('invalid sync sample table is rejected', () async {
    await expectLater(
      parse(
        mp4(
          tracks: [
            Mp4Track(stblExtra: full('stss', [...num(1), ...num(2)])),
          ],
        ),
      ),
      bad(),
    );
  });
  test('64bit top-level box size and EOF mdat work', () async {
    final b = mp4(fastStart: true);
    final eof = field(b, 'mdat', -8, num(0));
    final d = await parse([...eof]);
    expect(doc(d.single).cues.single.payload, 'hello');
    expect(
      (await parse(mp4(extra: box('free', [1, 2, 3], large: true)))).length,
      1,
    );
  });

  for (final range in <(int, int)?>[null, (0, 2), (2, 3)]) {
    test('CRLF content is independent of style boundary $range', () async {
      final data = await parse(
        mp4(
          tracks: [
            Mp4Track(
              samples: [
                textSample(
                  String.fromCharCodes([97, 13, 10, 98]),
                  extra: range == null
                      ? []
                      : box('styl', [
                          ...num(1, 2),
                          ...style(start: range.$1, end: range.$2, face: 1),
                        ]),
                ),
              ],
            ),
          ],
        ),
      );
      final c = doc(data.single).cues.single;
      expect(c.payload, String.fromCharCodes([97, 10, 98]));
      expect(
        c.textRuns!.map((r) => r.text).join(),
        String.fromCharCodes([97, 10, 98]),
      );
      if (range == (0, 2)) expect(c.textRuns!.first.bold, true);
    });
  }
  final cases = <String, List<int>>{
    'duplicate IDs': mp4(tracks: [Mp4Track(), Mp4Track()]),
    'zero ID': mp4(tracks: [Mp4Track(id: 0)]),
    'zero timescale': mp4(tracks: [Mp4Track(scale: 0)]),
    'stts sample mismatch': field(mp4(), 'stts', 8, num(2)),
    'stsc first chunk gap': field(mp4(), 'stsc', 8, num(2)),
    'stsc description missing': field(mp4(), 'stsc', 16, num(2)),
    'chunk outside mdat': field(mp4(), 'stco', 8, num(1)),
    'sample crosses mdat': field(mp4(), 'stsz', 12, num(100000)),
    'truncated text': mp4(
      tracks: [
        Mp4Track(
          samples: [
            [0, 20, 65],
          ],
        ),
      ],
    ),
    'invalid UTF8': mp4(
      tracks: [
        Mp4Track(
          samples: [
            [0, 1, 255],
          ],
        ),
      ],
    ),
    'invalid UTF16 surrogate': mp4(
      tracks: [
        Mp4Track(
          samples: [
            [0, 4, 254, 255, 216, 0],
          ],
        ),
      ],
    ),
    'odd UTF16': mp4(
      tracks: [
        Mp4Track(
          samples: [
            [0, 3, 254, 255, 0],
          ],
        ),
      ],
    ),
    'NUL': mp4(
      tracks: [
        Mp4Track(samples: [textSample('x\u0000')]),
      ],
    ),
    'zero duration text': mp4(
      tracks: [
        Mp4Track(durations: [0]),
      ],
    ),
    'style range outside text': mp4(
      tracks: [
        Mp4Track(
          samples: [
            textSample(
              'a',
              extra: box('styl', [...num(1, 2), ...style(end: 2)]),
            ),
          ],
        ),
      ],
    ),
    'overlapping styles': mp4(
      tracks: [
        Mp4Track(
          samples: [
            textSample(
              'abc',
              extra: box('styl', [
                ...num(2, 2),
                ...style(end: 2),
                ...style(start: 1, end: 3),
              ]),
            ),
          ],
        ),
      ],
    ),
    'duplicate stts': mp4(
      tracks: [
        Mp4Track(stblExtra: full('stts', [...num(0)])),
      ],
    ),
    'trailing malformed atom': mp4(extra: [0, 0, 0]),
    'duplicate moov': mp4(extra: box('moov', [])),
    'table flags': field(mp4(), 'stsz', 0, [1, 0, 0, 0]),
  };
  for (final e in cases.entries) {
    test('reject ${e.key}', () async {
      await expectLater(
        parse(e.value),
        bad(
          e.key == 'table flags'
              ? SubtitleParseReason.unsupported
              : SubtitleParseReason.malformed,
        ),
      );
    });
  }
  final unsupported = <String, List<int>>{
    'some forced only': mp4(
      tracks: [Mp4Track(entry: description(display: 0x40000000))],
    ),
    'all forced without present': mp4(
      tracks: [Mp4Track(entry: description(display: 0x80000000))],
    ),
    'fragmented': mp4(moovExtra: box('mvex', [])),
    'fragment root': mp4(extra: box('moof', [])),
    'encrypted entry': mp4(
      tracks: [Mp4Track(entry: description(codec: 'encs'))],
    ),
    'external data reference': field(mp4(), 'url ', 0, num(0)),
    'dwell rate': mp4(
      tracks: [
        Mp4Track(edits: edits([(1000, 0)], rate: 0)),
      ],
    ),
    'repeated edits': mp4(
      tracks: [
        Mp4Track(edits: edits([(1000, 0), (1000, 0)])),
      ],
    ),
    'advanced karaoke': mp4(
      tracks: [
        Mp4Track(samples: [textSample('a', extra: box('krok', []))]),
      ],
    ),
    'nonbottom alignment': mp4(
      tracks: [Mp4Track(entry: description(vertical: 0))],
    ),
    'unknown font': mp4(
      tracks: [Mp4Track(entry: description(defaults: style(font: 4)))],
    ),
    'encrypted sinf': mp4(
      tracks: [Mp4Track(entry: description(extra: box('sinf', [])))],
    ),
  };
  for (final e in unsupported.entries) {
    test('unsupported ${e.key}', () async {
      await expectLater(parse(e.value), bad(SubtitleParseReason.unsupported));
    });
  }
  test('sample count budget before table allocation', () async {
    await expectLater(
      parse(field(mp4(), 'stsz', 8, num(20001))),
      bad(SubtitleParseReason.limitExceeded),
    );
  });
  test('cue text bound before run allocation', () async {
    await expectLater(
      parse(
        mp4(
          tracks: [
            Mp4Track(samples: [textSample('a' * 16385)]),
          ],
        ),
      ),
      bad(SubtitleParseReason.limitExceeded),
    );
  });
  test('every truncated prefix rejects with sanitized parser error', () async {
    final b = mp4();
    for (var i = 0; i < b.length; i++) {
      await expectLater(
        parse(b.sublist(0, i)),
        throwsA(isA<SubtitleParseException>()),
        reason: 'prefix $i',
      );
    }
  });
  test('cancel during read rejects before publication', () async {
    final b = mp4(), token = SubtitleCancellation();
    await expectLater(
      Mp4Subtitles(b.length, (p, n) async {
        token.cancel();
        return b.sublist(p, p + n);
      }, token).parse(),
      throwsA(isA<Exception>()),
    );
  });
}
