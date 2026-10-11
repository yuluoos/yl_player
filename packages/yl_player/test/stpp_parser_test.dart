import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/mp4_subtitles.dart';
import 'package:yl_player/src/subtitles/matroska_subtitles.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'package:yl_player/src/subtitles/subtitle_resource.dart';
import 'support/stpp_fixture.dart';
import 'support/wvtt_fixture.dart' show wvttTrack, wvttEntry;

Future<List<EmbeddedSubtitleData>> parse(List<int> b) => Mp4Subtitles(
  b.length,
  (p, n) async => b.sublist(p, p + n),
  SubtitleCancellation(),
).parse();
Future<SubtitleDocument> document(List<int> b) async {
  final d = (await parse(b)).single;
  return SubtitleDocument.fromEmbeddedPackets(
    d.packets,
    format: SubtitleFormat.ttml,
    sourceBytes: d.sourceBytes,
  );
}

Matcher bad([SubtitleParseReason reason = SubtitleParseReason.malformed]) =>
    throwsA(
      isA<SubtitleParseException>().having((e) => e.reason, 'reason', reason),
    );
void main() {
  test(
    'independent FFmpeg stpp with cell font styling is explicitly unsupported',
    () async {
      final fixture = File(
        'packages/yl_player/test/fixtures/stpp-ffmpeg-owned.mp4',
      );
      await expectLater(
        parse(await fixture.readAsBytes()),
        bad(SubtitleParseReason.unsupported),
      );
    },
  );
  test(
    'three codecs preserve same-language identities and public formats',
    () async {
      final d = await parse(
        mp4(tracks: [stppTrack(id: 8), wvttTrack(id: 9), Mp4Track(id: 3)]),
      );
      expect(d.map((v) => v.track.id), ['mp4:8', 'mp4:9', 'mp4:3']);
      expect(d.map((v) => v.track.format), [
        YlSubtitleFormat.ttml,
        YlSubtitleFormat.webvtt,
        YlSubtitleFormat.srt,
      ]);
    },
  );
  test('literal XML sample independent of TTML fixture wrapper', () async {
    final sample = utf8.encode(
      '<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="0.25s" dur="0.5s">literal &lt;b&gt;</p></div></body></tt>',
    );
    final d = await document(
      mp4(
        tracks: [
          stppTrack(samples: [sample]),
        ],
      ),
    );
    expect(d.cues.single.start.inMicroseconds, 250000);
    expect(d.cues.single.end.inMicroseconds, 750000);
    expect(d.cues.single.payload, 'literal <b>');
    expect(d.cues.single.textRuns!.every((r) => !r.bold), true);
  });
  test(
    'nonzero samples clip absolute TTML times, never add sample start',
    () async {
      final d = await document(
        mp4(
          tracks: [
            stppTrack(
              samples: [
                stppSample(''),
                stppSample(
                  '<p begin="0.5s" end="1.5s">early</p><p begin="1.75s" end="4s">late</p>',
                ),
              ],
              durations: [1000, 1000],
            ),
          ],
        ),
      );
      expect(
        d.cues.map((c) => [c.start.inMicroseconds, c.end.inMicroseconds]),
        [
          [1000000, 1500000],
          [1750000, 2000000],
        ],
      );
      expect(d.cuesAt(const Duration(milliseconds: 1600)), isEmpty);
    },
  );
  test('simple edit trims and maps cue composition times exactly once', () async {
    final edits = full('elst', [
      ...num(2),
      ...num(500),
      ...num(-1),
      ...num(0x10000),
      ...num(1000),
      ...num(1000),
      ...num(0x10000),
    ]);
    final d = await document(
      mp4(
        tracks: [
          stppTrack(
            samples: [
              stppSample(
                '<p begin="0.75s" end="1.25s">a</p><p begin="1.75s" end="3s">b</p>',
              ),
            ],
            durations: [3000],
            edits: edits,
          ),
        ],
      ),
    );
    expect(d.cues.map((c) => [c.start.inMicroseconds, c.end.inMicroseconds]), [
      [500000, 750000],
      [1250000, 1500000],
    ]);
  });
  test(
    'ctts clips document on composition interval without shifting XML coordinates',
    () async {
      final d = await document(
        mp4(
          tracks: [
            stppTrack(
              samples: [stppSample('<p begin="0s" end="2s">a</p>')],
              ctts: full('ctts', [...num(1), ...num(1), ...num(500)]),
            ),
          ],
        ),
      );
      expect(d.cues.single.start.inMicroseconds, 500000);
      expect(d.cues.single.end.inMicroseconds, 1500000);
    },
  );
  test('fractional edit ratios combine before microsecond rounding', () async {
    final d = await document(
      mp4(
        tracks: [
          stppTrack(
            scale: 3,
            durations: [6],
            edits: full('elst', [
              ...num(2),
              ...num(333),
              ...num(-1),
              ...num(0x10000),
              ...num(1000),
              ...num(1),
              ...num(0x10000),
            ]),
            samples: [stppSample('<p begin="0.5s" end="1s">a</p>')],
          ),
        ],
      ),
    );
    expect(d.cues.single.start.inMicroseconds, 499666);
    expect(d.cues.single.end.inMicroseconds, 999666);
  });
  test(
    'untimed paragraph lasts only its sample and external parser stays strict',
    () async {
      final sample = stppSample('<p>forever</p>');
      final d = await document(
        mp4(
          tracks: [
            stppTrack(
              samples: [stppSample(''), sample],
              durations: [1000, 1000],
            ),
          ],
        ),
      );
      expect(d.cues.single.start, const Duration(seconds: 1));
      expect(d.cues.single.end, const Duration(seconds: 2));
      expect(
        () => SubtitleDocument.parse(sample, format: SubtitleFormat.ttml),
        bad(SubtitleParseReason.unsupported),
      );
    },
  );
  test(
    'same document repeated in adjacent samples does not overlap at boundary',
    () async {
      final sample = stppSample(
        '<p xml:id="same" begin="0s" end="3s">same</p>',
      );
      final d = await document(
        mp4(
          tracks: [
            stppTrack(
              samples: [sample, sample, stppSample('')],
              durations: [1000, 1000, 1000],
            ),
          ],
        ),
      );
      expect(d.cues.map((c) => c.identifier), ['same', 'same']);
      expect(d.cuesAt(const Duration(milliseconds: 999)), hasLength(1));
      expect(d.cuesAt(const Duration(seconds: 1)), hasLength(1));
      expect(d.cuesAt(const Duration(seconds: 2)), isEmpty);
    },
  );
  test(
    'region definitions and style IDs are local to each overlapping document',
    () async {
      List<int> sample(String x) => stppSample(
        '<p region="r" style="s" begin="0s" end="2s">$x</p>',
        head:
            '<head><styling><style xml:id="s" tts:fontWeight="bold"/></styling><layout><region xml:id="r" tts:origin="$x% 0%" tts:extent="10% 10%"/></layout></head>',
      );
      final d = await document(
        mp4(
          tracks: [
            stppTrack(
              samples: [sample('10'), sample('50')],
              durations: [1000, 1000],
              ctts: full('ctts', [
                ...num(2),
                ...num(1),
                ...num(0),
                ...num(1),
                ...num(-1000),
              ], version: 1),
            ),
          ],
        ),
      );
      expect(d.cuesAt(const Duration(milliseconds: 500)), hasLength(2));
      expect(d.cues.map((c) => c.region!.x), [.1, .5]);
      expect(d.cues.map((c) => c.region!.id).toSet(), hasLength(2));
    },
  );
  test(
    'raw XML metadata including empty documents counts in catalog budget',
    () async {
      final sample = stppSample('', head: '<!--${'a' * 4000}-->');
      final data = (await parse(
        mp4(
          tracks: [
            stppTrack(samples: [sample]),
          ],
        ),
      )).single;
      final d = SubtitleDocument.fromEmbeddedPackets(
        data.packets,
        format: SubtitleFormat.ttml,
        sourceBytes: data.sourceBytes,
      );
      expect(d.inputBytes, sample.length);
      expect(
        () => SubtitleDocument.fromEmbeddedPackets(
          data.packets,
          format: SubtitleFormat.ttml,
          sourceBytes: data.sourceBytes,
          limits: const SubtitleLimits(maxInputBytes: 100),
        ),
        bad(SubtitleParseReason.limitExceeded),
      );
    },
  );
  test(
    'BOM declaration, namespace aliases, parent timing and inherited style',
    () async {
      final sample = utf8.encode(
        '\uFEFF<?xml version="1.0" encoding="UTF-8"?><t:tt xmlns:t="$ttmlNamespace" xmlns:s="$ttmlNamespace#styling"><t:body begin="0.25s" end="1s" s:fontStyle="italic"><t:div begin="0.25s"><t:p dur="1s">one<t:br/>two</t:p></t:div></t:body></t:tt>',
      );
      final d = await document(
        mp4(
          tracks: [
            stppTrack(
              samples: [sample],
              entry: stppEntry(
                schema: 'https://invalid.example/schema',
                extra: box('btrt', List.filled(12, 0)),
              ),
            ),
          ],
        ),
      );
      expect(d.cues.single.start.inMicroseconds, 500000);
      expect(d.cues.single.end.inMicroseconds, 1000000);
      expect(d.cues.single.payload, 'one\ntwo');
      expect(d.cues.single.textRuns!.every((r) => r.italic), true);
    },
  );
  test(
    'empty sample documents and zero-duration empty terminal sample emit no cue',
    () async {
      final d = await document(
        mp4(
          tracks: [
            stppTrack(
              samples: [stppSample(''), stppSample('')],
              durations: [1000, 0],
            ),
          ],
        ),
      );
      expect(d.cues, isEmpty);
    },
  );
  test(
    'stpp sample descriptions may switch schema metadata within one codec',
    () async {
      final d = await document(
        mp4(
          tracks: [
            Mp4Track(
              entries: [
                stppEntry(),
                stppEntry(schema: 'urn:owned'),
              ],
              samples: [stppSample('<p>a</p>'), stppSample('<p>b</p>')],
              durations: [1000, 1000],
              chunkSizes: [1, 1],
              descriptionIndices: [1, 2],
            ),
          ],
        ),
      );
      expect(d.cues.map((c) => c.payload), ['a', 'b']);
    },
  );
  final malformed = <String, List<int>>{
    'missing string terminator': box('stpp', [
      ...List.filled(6, 0),
      ...num(1, 2),
      ...utf8.encode(ttmlNamespace),
    ]),
    'invalid header UTF8': box('stpp', [
      ...List.filled(6, 0),
      ...num(1, 2),
      255,
      0,
      0,
      0,
    ]),
    'header control': stppEntry(schema: 'a\nb'),
    'bad bitrate length': stppEntry(extra: box('btrt', [0])),
    'duplicate bitrate': stppEntry(
      extra: [
        ...box('btrt', List.filled(12, 0)),
        ...box('btrt', List.filled(12, 0)),
      ],
    ),
  };
  for (final e in malformed.entries) {
    test('malformed sample entry ${e.key}', () async {
      await expectLater(parse(mp4(tracks: [stppTrack(entry: e.value)])), bad());
    });
  }
  final unsupported = <String, List<int>>{
    'namespace': stppEntry(namespace: 'urn:other'),
    'aux images': stppEntry(auxiliary: 'image/png'),
    'encrypted': stppEntry(extra: box('sinf', [])),
    'unknown child': stppEntry(extra: box('abcd', [])),
  };
  for (final e in unsupported.entries) {
    test('unsupported sample entry ${e.key}', () async {
      await expectLater(
        parse(mp4(tracks: [stppTrack(entry: e.value)])),
        bad(SubtitleParseReason.unsupported),
      );
    });
  }
  final badXml = <String, List<int>>{
    'UTF8': [255, 255],
    'NUL': utf8.encode('${ttmlDocument('')}\u0000'),
    'truncated': utf8.encode('<tt xmlns="$ttmlNamespace"><body>'),
    'duplicate ID': stppSample('<p xml:id="a">a</p><p xml:id="a">b</p>'),
    'unknown entity': stppSample('<p>&unknown;</p>'),
  };
  for (final e in badXml.entries) {
    test('malformed XML ${e.key}', () async {
      await expectLater(
        parse(
          mp4(
            tracks: [
              stppTrack(samples: [e.value]),
            ],
          ),
        ),
        bad(),
      );
    });
  }
  final unsupportedXml = <String, List<int>>{
    'wrong nesting': stppSample('<p><div>x</div></p>'),
    'doctype': utf8.encode(
      '<!DOCTYPE tt SYSTEM "https://invalid.example/entity">${ttmlDocument('')}',
    ),
    'image': stppSample('<p><image src="https://invalid.example/a.png"/></p>'),
    'clock timebase': stppSample(
      '<p>a</p>',
      attributes: 'ttp:timeBase="clock"',
    ),
    'timed span': stppSample('<p><span begin="1s">a</span></p>'),
  };
  for (final e in unsupportedXml.entries) {
    test('unsupported XML ${e.key}', () async {
      await expectLater(
        parse(
          mp4(
            tracks: [
              stppTrack(samples: [e.value]),
            ],
          ),
        ),
        bad(SubtitleParseReason.unsupported),
      );
    });
  }
  test('mixed codecs in one track fail atomically', () async {
    await expectLater(
      parse(
        mp4(
          tracks: [
            Mp4Track(
              entries: [stppEntry(), wvttEntry()],
              samples: [],
              durations: [],
            ),
          ],
        ),
      ),
      bad(SubtitleParseReason.unsupported),
    );
  });
  test(
    'subsample resources are rejected before treating binary data as XML',
    () async {
      await expectLater(
        parse(
          mp4(
            tracks: [
              Mp4Track(
                entry: stppEntry(),
                samples: [stppSample('')],
                stblExtra: full('subs', [...num(0)]),
              ),
            ],
          ),
        ),
        bad(SubtitleParseReason.unsupported),
      );
    },
  );
  test('malformed XML outside edit still rejects the discovery', () async {
    await expectLater(
      parse(
        mp4(
          tracks: [
            stppTrack(
              samples: [utf8.encode('<tt broken')],
              edits: full('elst', [
                ...num(1),
                ...num(1000),
                ...num(2000),
                ...num(0x10000),
              ]),
            ),
          ],
        ),
      ),
      bad(),
    );
  });
  test('nonempty zero-duration sample is rejected', () async {
    await expectLater(
      parse(
        mp4(
          tracks: [
            stppTrack(durations: [0]),
          ],
        ),
      ),
      bad(),
    );
  });
  for (final e in <String, List<int>>{
    'field': stppEntry(schema: 'a' * 4097),
  }.entries) {
    test('bounded header ${e.key}', () async {
      await expectLater(
        parse(mp4(tracks: [stppTrack(entry: e.value)])),
        bad(SubtitleParseReason.limitExceeded),
      );
    });
  }
  for (final e in <String, List<int>>{
    'sample bytes': stppSample('', head: '<!--${'a' * 262144}-->'),
    'text': stppSample('<p>${'a' * 16385}</p>'),
    'active cues': stppSample(List.filled(65, '<p>x</p>').join()),
    'XML depth': stppSample('${'<div>' * 32}<p>x</p>${'</div>' * 32}'),
  }.entries) {
    test('bounded ${e.key}', () async {
      await expectLater(
        parse(
          mp4(
            tracks: [
              stppTrack(samples: [e.value]),
            ],
          ),
        ),
        bad(SubtitleParseReason.limitExceeded),
      );
    });
  }
  test('multi-document cue total is bounded across tracks', () async {
    final sample = stppSample(List.filled(64, '<p>x</p>').join());
    await expectLater(
      parse(
        mp4(
          tracks: [
            stppTrack(
              id: 1,
              samples: List.filled(79, sample),
              durations: List.filled(79, 1),
            ),
            stppTrack(
              id: 2,
              samples: List.filled(79, sample),
              durations: List.filled(79, 1),
            ),
          ],
        ),
      ),
      bad(SubtitleParseReason.limitExceeded),
    );
  });
  test(
    '64 simultaneously active paragraphs accepted at half-open boundary',
    () async {
      final d = await document(
        mp4(
          tracks: [
            stppTrack(
              samples: [stppSample(List.filled(64, '<p>x</p>').join())],
            ),
          ],
        ),
      );
      expect(d.cuesAt(Duration.zero), hasLength(64));
      expect(d.cuesAt(const Duration(seconds: 1)), isEmpty);
    },
  );
  test('every truncated prefix gives classified failure', () async {
    final b = mp4(tracks: [stppTrack()]);
    for (var i = 0; i < b.length; i++) {
      await expectLater(
        parse(b.sublist(0, i)),
        throwsA(isA<SubtitleParseException>()),
        reason: 'prefix $i',
      );
    }
  });
}
