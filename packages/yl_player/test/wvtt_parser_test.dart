import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/mp4_subtitles.dart';
import 'package:yl_player/src/subtitles/matroska_subtitles.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'package:yl_player/src/subtitles/subtitle_resource.dart';
import 'support/wvtt_fixture.dart';

Future<List<EmbeddedSubtitleData>> parse(List<int> b) => Mp4Subtitles(
  b.length,
  (p, n) async => b.sublist(p, p + n),
  SubtitleCancellation(),
).parse();
Future<SubtitleDocument> document(List<int> b) async =>
    SubtitleDocument.fromEmbeddedPackets(
      (await parse(b)).single.packets,
      format: SubtitleFormat.webvtt,
    );
Matcher bad([SubtitleParseReason r = SubtitleParseReason.malformed]) =>
    throwsA(isA<SubtitleParseException>().having((e) => e.reason, 'reason', r));
void main() {
  test(
    'literal hand-calculated vttc/payl bytes independent of box fixture',
    () async {
      final sample = [
        0,
        0,
        0,
        20,
        118,
        116,
        116,
        99,
        0,
        0,
        0,
        12,
        112,
        97,
        121,
        108,
        111,
        110,
        101,
        33,
      ];
      final d = await document(
        mp4(
          tracks: [
            wvttTrack(samples: [sample], durations: [1001], scale: 1000000),
          ],
        ),
      );
      expect(d.cues.single.payload, 'one!');
      expect(d.cues.single.end.inMicroseconds, 1001);
    },
  );
  test(
    'tx3g and wvtt tracks of same language keep independent IDs and formats',
    () async {
      final d = await parse(mp4(tracks: [wvttTrack(id: 9), Mp4Track(id: 3)]));
      expect(d.map((t) => t.track.id), ['mp4:9', 'mp4:3']);
      expect(d.map((t) => t.track.format), [
        YlSubtitleFormat.webvtt,
        YlSubtitleFormat.srt,
      ]);
    },
  );
  test(
    'sample descriptions may change wvtt config with stable format',
    () async {
      final d = await document(
        mp4(
          tracks: [
            Mp4Track(
              entries: [
                wvttEntry(),
                wvttEntry(config: 'WEBVTT owned'),
              ],
              samples: [vttCue('a'), vttCue('b')],
              durations: [500, 500],
              chunkSizes: [1, 1],
              descriptionIndices: [1, 2],
            ),
          ],
        ),
      );
      expect(d.cues.map((c) => c.payload), ['a', 'b']);
    },
  );
  test(
    'adjacent split cue samples do not overlap or deduplicate by identifier',
    () async {
      final d = await document(
        mp4(
          tracks: [
            wvttTrack(
              samples: [
                vttCue('same', id: 'id', time: '00:00:00.000'),
                vttCue('same', id: 'id', time: '00:00:00.000'),
              ],
              durations: [1000, 1000],
            ),
          ],
        ),
      );
      expect(d.cuesAt(const Duration(milliseconds: 999)).length, 1);
      expect(d.cuesAt(const Duration(seconds: 1)).length, 1);
      expect(d.cuesAt(const Duration(seconds: 2)), isEmpty);
    },
  );
  test(
    'container edit and ctts remain authoritative over ctim metadata',
    () async {
      final d = await document(
        mp4(
          tracks: [
            Mp4Track(
              entry: wvttEntry(),
              samples: [vttCue('x', time: '00:00:59.000')],
              durations: [1000],
              ctts: full('ctts', [...num(1), ...num(1), ...num(500)]),
              edits: full('elst', [
                ...num(2),
                ...num(250),
                ...num(-1),
                ...num(0x10000),
                ...num(1000),
                ...num(250),
                ...num(0x10000),
              ]),
            ),
          ],
        ),
      );
      expect(d.cues.single.start.inMicroseconds, 500000);
      expect(d.cues.single.end.inMicroseconds, 1250000);
    },
  );
  test(
    'payload blank lines and timing arrows cannot inject extra cues',
    () async {
      const text = 'one\n\n00:00:09.000 --> 00:00:10.000\nthree';
      final d = await document(
        mp4(
          tracks: [
            wvttTrack(samples: [vttCue(text)]),
          ],
        ),
      );
      expect(d.cues.single.payload, text);
      expect(d.cues.single.start, Duration.zero);
    },
  );
  test('CRLF payload normalizes once while ID is metadata', () async {
    final d = await document(
      mp4(
        tracks: [
          wvttTrack(samples: [vttCue('a\r\nb', id: 'duplicate allowed')]),
        ],
      ),
    );
    expect(d.cues.single.payload, 'a\nb');
    expect(d.cues.single.identifier, 'duplicate allowed');
  });
  test('empty payl and vtte produce no phantom cues', () async {
    final d = await document(
      mp4(
        tracks: [
          wvttTrack(samples: [vttCue(''), box('vtte', [])], durations: [1, 1]),
        ],
      ),
    );
    expect(d.cues, isEmpty);
  });
  test('64-bit sample-local boxes preserve payload', () async {
    final d = await document(
      mp4(
        tracks: [
          wvttTrack(
            samples: [
              box(
                'vttc',
                box('payl', utf8.encode('large header'), large: true),
                large: true,
              ),
            ],
          ),
        ],
      ),
    );
    expect(d.cues.single.payload, 'large header');
  });
  test('vttC BOM and comments, vlab and bitrate metadata accepted', () async {
    final d = await parse(
      mp4(
        tracks: [
          wvttTrack(
            entry: wvttEntry(
              config: '\uFEFFWEBVTT\n\nNOTE owned\ncomment\n',
              extra: [
                ...box('vlab', utf8.encode('owned')),
                ...box('btrt', List.filled(12, 0)),
              ],
            ),
          ),
        ],
      ),
    );
    expect(d.single.track.format, YlSubtitleFormat.webvtt);
  });
  for (final settings in [
    'align:start',
    'align:center',
    'align:end',
    'align:left',
    'align:right',
    'position:0%,line-left',
    'position:100%,line-right',
    'position:33.3%,center',
  ]) {
    test('supported setting $settings', () async {
      final d = await document(
        mp4(
          tracks: [
            wvttTrack(samples: [vttCue('x', settings: settings)]),
          ],
        ),
      );
      expect(d.cues.length, 1);
    });
  }

  test('64 simultaneous cues retain sample order at exact boundary', () async {
    final d = await document(
      mp4(
        tracks: [
          wvttTrack(
            samples: [
              [for (var i = 0; i < 64; i++) ...vttCue('cue$i', id: 'same')],
            ],
          ),
        ],
      ),
    );
    expect(d.cuesAt(Duration.zero).map((c) => c.payload), [
      for (var i = 0; i < 64; i++) 'cue$i',
    ]);
    expect(d.cuesAt(const Duration(seconds: 1)), isEmpty);
  });
  test(
    'cross-track multi-cue catalog bound before retaining more than10000 packets',
    () async {
      List<List<int>> samples() => [
        for (var s = 0; s < 79; s++)
          [for (var c = 0; c < 64; c++) ...vttCue('x')],
      ];
      final b = mp4(
        tracks: [
          wvttTrack(id: 1, samples: samples(), durations: List.filled(79, 1)),
          wvttTrack(id: 2, samples: samples(), durations: List.filled(79, 1)),
        ],
      );
      await expectLater(parse(b), bad(SubtitleParseReason.limitExceeded));
    },
  );
  final malformed = <String, List<int>>{
    'missing vttC': mp4(
      tracks: [
        wvttTrack(entry: box('wvtt', [...List.filled(6, 0), 0, 1])),
      ],
    ),
    'duplicate config': mp4(
      tracks: [
        wvttTrack(entry: wvttEntry(extra: box('vttC', utf8.encode('WEBVTT')))),
      ],
    ),
    'bad config signature': mp4(
      tracks: [wvttTrack(entry: wvttEntry(config: 'not vtt'))],
    ),
    'missing payl': mp4(
      tracks: [
        wvttTrack(samples: [box('vttc', [])]),
      ],
    ),
    'duplicate payl': mp4(
      tracks: [
        wvttTrack(
          samples: [
            vttCue('x', extra: box('payl', [65])),
          ],
        ),
      ],
    ),
    'duplicate iden': mp4(
      tracks: [
        wvttTrack(
          samples: [
            vttCue('x', id: 'one', extra: box('iden', [65])),
          ],
        ),
      ],
    ),
    'bad utf8': mp4(
      tracks: [
        wvttTrack(
          samples: [
            box('vttc', box('payl', [255])),
          ],
        ),
      ],
    ),
    'NUL payload': mp4(
      tracks: [
        wvttTrack(
          samples: [
            box('vttc', box('payl', [0])),
          ],
        ),
      ],
    ),
    'truncated box': mp4(
      tracks: [
        wvttTrack(
          samples: [
            [0, 0, 0, 20, 118, 116, 116, 99],
          ],
        ),
      ],
    ),
    'small box': mp4(
      tracks: [
        wvttTrack(
          samples: [
            [0, 0, 0, 4, 118, 116, 116, 99],
          ],
        ),
      ],
    ),
    'vtte body': mp4(
      tracks: [
        wvttTrack(
          samples: [
            box('vtte', [0]),
          ],
        ),
      ],
    ),
    'vtte with cue': mp4(
      tracks: [
        wvttTrack(
          samples: [
            [...box('vtte', []), ...vttCue('x')],
          ],
        ),
      ],
    ),
    'ID newline': mp4(
      tracks: [
        wvttTrack(samples: [vttCue('x', id: 'a\nb')]),
      ],
    ),
    'ID arrow': mp4(
      tracks: [
        wvttTrack(samples: [vttCue('x', id: 'a-->b')]),
      ],
    ),
    'ctim syntax': mp4(
      tracks: [
        wvttTrack(samples: [vttCue('x', time: '00:70:00.000')]),
      ],
    ),
    'setting newline': mp4(
      tracks: [
        wvttTrack(samples: [vttCue('x', settings: 'align:left\n')]),
      ],
    ),
    'setting duplicate': mp4(
      tracks: [
        wvttTrack(samples: [vttCue('x', settings: 'align:left align:right')]),
      ],
    ),
    'setting out of range': mp4(
      tracks: [
        wvttTrack(samples: [vttCue('x', settings: 'position:101%')]),
      ],
    ),
  };
  for (final e in malformed.entries) {
    test('malformed ${e.key}', () async {
      await expectLater(parse(e.value), bad());
    });
  }
  final unsupported = <String, List<int>>{
    'mixed codecs in one track': mp4(
      tracks: [
        Mp4Track(entries: [wvttEntry(), description()], samples: [vttCue('x')]),
      ],
    ),
    'config CSS': mp4(
      tracks: [
        wvttTrack(
          entry: wvttEntry(config: 'WEBVTT\n\nSTYLE\n::cue { color:red }'),
        ),
      ],
    ),
    'config cue injection': mp4(
      tracks: [
        wvttTrack(
          entry: wvttEntry(
            config: 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nx',
          ),
        ),
      ],
    ),
    'region': mp4(
      tracks: [
        wvttTrack(samples: [vttCue('x', settings: 'region:owned')]),
      ],
    ),
    'vertical': mp4(
      tracks: [
        wvttTrack(samples: [vttCue('x', settings: 'vertical:rl')]),
      ],
    ),
    'vtta': mp4(
      tracks: [
        wvttTrack(
          samples: [
            box('vtta', [65]),
          ],
        ),
      ],
    ),
    'encrypted config': mp4(
      tracks: [wvttTrack(entry: wvttEntry(extra: box('sinf', [])))],
    ),
    'zero box size': mp4(
      tracks: [
        wvttTrack(
          samples: [
            [0, 0, 0, 0, 118, 116, 116, 99],
          ],
        ),
      ],
    ),
  };
  for (final e in unsupported.entries) {
    test('unsupported ${e.key}', () async {
      await expectLater(parse(e.value), bad(SubtitleParseReason.unsupported));
    });
  }
  for (final kind in [
    'payload',
    'id',
    'settings',
    'configuration',
    'active cues',
  ]) {
    test('bounded $kind', () async {
      final bytes = mp4(
        tracks: [
          wvttTrack(
            entry: kind == 'configuration'
                ? wvttEntry(config: 'WEBVTT ${'a' * 16384}')
                : null,
            samples: [
              kind == 'active cues'
                  ? [for (var i = 0; i < 65; i++) ...vttCue('x')]
                  : vttCue(
                      kind == 'payload' ? 'a' * 16385 : 'x',
                      id: kind == 'id' ? 'a' * 1025 : null,
                      settings: kind == 'settings' ? ' ' * 1025 : null,
                    ),
            ],
          ),
        ],
      );
      await expectLater(parse(bytes), bad(SubtitleParseReason.limitExceeded));
    });
  }
  test('every truncated wvtt MP4 prefix gives classified error', () async {
    final b = mp4(
      tracks: [
        wvttTrack(samples: [vttCue('x', settings: 'align:left')]),
      ],
    );
    for (var n = 0; n < b.length; n++) {
      await expectLater(
        parse(b.sublist(0, n)),
        throwsA(isA<SubtitleParseException>()),
        reason: 'prefix $n',
      );
    }
  });
}
