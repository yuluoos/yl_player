import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/matroska_subtitles.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'package:yl_player/src/subtitles/subtitle_resource.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/matroska_fixture.dart';
import 'support/ass_fixture.dart';

Future<List<EmbeddedSubtitleData>> parse(
  List<int> bytes, {
  SubtitleCancellation? token,
}) => MatroskaSubtitles(
  bytes.length,
  (p, n) async => bytes.sublist(p, p + n),
  token ?? SubtitleCancellation(),
).parse();
Matcher reason(SubtitleParseReason r) =>
    throwsA(isA<SubtitleParseException>().having((e) => e.reason, 'reason', r));
Matcher failure(String code) => throwsA(
  isA<YlPlayerException>().having((e) => e.failure.code, 'code', code),
);
SubtitleDocument document(EmbeddedSubtitleData data) =>
    SubtitleDocument.fromEmbeddedPackets(
      data.packets,
      codecPrivate: data.codecPrivate,
      format: switch (data.track.format) {
        YlSubtitleFormat.ass => SubtitleFormat.ass,
        YlSubtitleFormat.ssa => SubtitleFormat.ssa,
        _ => SubtitleFormat.srt,
      },
    );
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'same-language tracks use UID independent of order and TrackNumber',
    () async {
      final a = await parse(
        mkv(
          tracks: [
            ...track(number: 3, uid: 300, forced: true),
            ...track(number: 7, uid: 700, ietf: 'en-US'),
          ],
          clusters: cluster([
            ...block(number: 7, text: 'normal'),
            ...block(number: 3, text: 'forced'),
          ]),
        ),
      );
      expect(a.map((e) => e.track.id), ['mkv:300', 'mkv:700']);
      expect(a.first.track.role, 'forced');
      expect(a.last.track.language, 'en-US');
      expect(document(a.first).cues.single.payload, 'forced');
      final b = await parse(
        mkv(
          tracks: [
            ...track(number: 7, uid: 700),
            ...track(number: 3, uid: 300),
          ],
          clusters: cluster(block(number: 3)),
        ),
      );
      expect(b.last.track.id, a.first.track.id);
    },
  );
  test('UID supports the entire unsigned 64-bit range', () async {
    final bytes = mkv(
      tracks: element(0xae, [
        ...uint(0xd7, 1),
        ...element(0x73c5, List.filled(8, 255)),
        ...uint(0x83, 17),
        ...str(0x86, 'S_TEXT/UTF8'),
      ]),
    );
    expect((await parse(bytes)).single.track.id, 'mkv:18446744073709551615');
  });
  test(
    'unknown Segment and non-default scale, signed block time, CodecDelay',
    () async {
      final data = await parse(
        mkv(
          unknownSegment: true,
          scale: 2000000,
          tracks: track(extra: uint(0x56aa, 500000)),
          clusters: cluster(block(time: -10, duration: 25), time: 100),
        ),
      );
      final c = document(data.single).cues.single;
      expect(c.start, const Duration(microseconds: 179500));
      expect(c.end, const Duration(microseconds: 229500));
    },
  );
  test(
    'SimpleBlock requires and uses DefaultDuration in nanoseconds',
    () async {
      final d = await parse(
        mkv(
          tracks: track(extra: uint(0x23e383, 250500000)),
          clusters: cluster(block(simple: true)),
        ),
      );
      expect(
        document(d.single).cues.single.end,
        const Duration(microseconds: 1250500),
      );
    },
  );
  test('Cluster timestamp may follow blocks', () async {
    final d = await parse(
      mkv(clusters: element(0x1f43b675, [...block(), ...uint(0xe7, 1234)])),
    );
    expect(
      document(d.single).cues.single.start,
      const Duration(milliseconds: 1234),
    );
  });
  for (final ssa in [false, true]) {
    test(
      '${ssa ? 'SSA' : 'ASS'} uses private styles, packet ReadOrder, exact times and commas',
      () async {
        final header = assFixture(ssa: ssa).split('[Events]').first;
        final d = await parse(
          mkv(
            tracks: track(
              codec: ssa ? 'S_TEXT/SSA' : 'S_TEXT/ASS',
              private: header,
            ),
            clusters: cluster([
              ...block(
                time: 7,
                duration: 123,
                text: '2,${ssa ? '' : '1'},Default,,0,0,0,,second, comma',
              ),
              ...block(
                time: 3,
                duration: 150,
                text: '1,${ssa ? '' : '0'},Default,,0,0,0,,{\\b1}first\\Nline',
              ),
            ]),
          ),
        );
        final doc = document(d.single);
        expect(doc.cues.map((c) => c.start.inMilliseconds), [1003, 1007]);
        expect(doc.cues.first.end.inMilliseconds, 1153);
        expect(doc.cues.first.ass!.runs.first.style.bold, true);
        expect(doc.cues.last.payload, 'second, comma');
      },
    );
  }
  test('UTF8 block content cannot inject file-level cues', () async {
    final d = await parse(
      mkv(
        clusters: cluster(
          block(text: 'a\n\n99\n00:00:01,000 --> 00:00:02,000\n<literal>'),
        ),
      ),
    );
    expect(document(d.single).cues, hasLength(1));
  });
  final malformed = <String, List<int>>{
    'duplicate TrackUID': mkv(tracks: [...track(), ...track(number: 2)]),
    'duplicate TrackNumber': mkv(tracks: [...track(), ...track(uid: 102)]),
    'truncated block': mkv(clusters: cluster(element(0xa3, [0x81, 0]))),
    'missing track': mkv(clusters: cluster(block(number: 2))),
    'negative presentation': mkv(clusters: cluster(block(time: -1), time: 0)),
    'zero duration': mkv(clusters: cluster(block(duration: 0))),
    'duplicate timestamp': mkv(
      clusters: element(0x1f43b675, [
        ...uint(0xe7, 1),
        ...uint(0xe7, 2),
        ...block(),
      ]),
    ),
    'oversized child': mkv(clusters: element(0x1f43b675, [0xa0, 0xff])),
  };
  for (final entry in malformed.entries) {
    test('rejects ${entry.key}', () async {
      await expectLater(
        parse(entry.value),
        reason(
          entry.key == 'oversized child'
              ? SubtitleParseReason.unsupported
              : SubtitleParseReason.malformed,
        ),
      );
    });
  }
  final unsupported = <String, List<int>>{
    'codec': mkv(tracks: track(codec: 'S_HDMV/PGS')),
    'compressed track': mkv(tracks: track(extra: element(0x6d80, []))),
    'missing duration': mkv(clusters: cluster(block(duration: null))),
    'lacing': mkv(clusters: cluster(block(flags: 2))),
    'invisible subtitle': mkv(clusters: cluster(block(flags: 8))),
    'block additions': mkv(
      clusters: cluster(block(extra: element(0x75a1, []))),
    ),
    'codec state': mkv(clusters: cluster(block(extra: element(0xa4, [])))),
    'nonneutral track scale': mkv(
      tracks: track(extra: element(0x23314f, [0x40, 0, 0, 0])),
    ),
  };
  for (final entry in unsupported.entries) {
    test('rejects unsupported ${entry.key}', () async {
      await expectLater(
        parse(entry.value),
        reason(SubtitleParseReason.unsupported),
      );
    });
  }
  test('limits cue payload before reading it', () async {
    final bytes = mkv(clusters: cluster(block(text: 'x' * 65537)));
    var largest = 0;
    await expectLater(
      MatroskaSubtitles(bytes.length, (p, n) async {
        if (n > largest) largest = n;
        return bytes.sublist(p, p + n);
      }, SubtitleCancellation()).parse(),
      reason(SubtitleParseReason.limitExceeded),
    );
    expect(largest, lessThan(65537));
  });
  test('limits catalog tracks', () async {
    await expectLater(
      parse(
        mkv(
          tracks: [for (var i = 1; i <= 33; i++) ...track(number: i, uid: i)],
        ),
      ),
      reason(SubtitleParseReason.limitExceeded),
    );
  });
  test('cancellation fences pending reads', () async {
    final token = SubtitleCancellation();
    final gate = Completer<List<int>>();
    final work = MatroskaSubtitles(20, (p, n) => gate.future, token).parse();
    final rejected = expectLater(work, failure(YlFailureCodes.loadCancelled));
    token.cancel();
    gate.complete(List.filled(12, 0));
    await rejected;
  });
  test(
    'video BlockGroups may have multiple references and huge skipped payload',
    () async {
      final video = element(0xae, [
        ...uint(0xd7, 2),
        ...uint(0x73c5, 200),
        ...uint(0x83, 1),
        ...str(0x86, 'V_MPEG4/ISO/AVC'),
      ]);
      final bytes = mkv(
        tracks: [...track(), ...video],
        clusters: cluster([
          ...block(
            number: 2,
            text: 'v' * 5000000,
            extra: [...uint(0xfb, 1), ...uint(0xfb, 2)],
          ),
          ...block(),
        ]),
      );
      var read = 0;
      final d = await MatroskaSubtitles(bytes.length, (p, n) async {
        read += n;
        return bytes.sublist(p, p + n);
      }, SubtitleCancellation()).parse();
      expect(document(d.single).cues.single.payload, 'hello');
      expect(read, lessThan(4096));
    },
  );

  test(
    'independently muxed owned MKV exposes two real subtitle streams',
    () async {
      final runtime = TextSubtitleRuntime();
      await runtime.discover(
        YlFileSource(
          File(
            'packages/yl_player/test/fixtures/embedded-owned.mkv',
          ).absolute.path,
        ),
      );
      expect(runtime.state.tracks, hasLength(2));
      final normal = runtime.state.tracks.singleWhere(
        (t) => t.label == 'Normal',
      );
      final forced = runtime.state.tracks.singleWhere(
        (t) => t.label == 'Forced',
      );
      expect(normal.language, 'eng');
      expect(forced.role, 'forced');
      expect(normal.id, isNot(forced.id));
      runtime.select(normal.id);
      expect(runtime.cuesAt(const Duration(milliseconds: 502)), isEmpty);
      expect(
        runtime
            .cuesAt(const Duration(milliseconds: 503))
            .single
            .text
            .toPlainText(),
        'Owned embedded normal',
      );
      expect(runtime.cuesAt(const Duration(milliseconds: 1707)), isEmpty);
      runtime.select(forced.id);
      expect(
        runtime
            .cuesAt(const Duration(milliseconds: 750))
            .single
            .text
            .toPlainText(),
        'Owned embedded forced',
      );
      expect(runtime.cuesAt(const Duration(milliseconds: 1250)), isEmpty);
    },
  );
  test('container timing enforces overlap budget', () async {
    final data = await parse(
      mkv(clusters: cluster([for (var i = 0; i < 65; i++) ...block()])),
    );
    expect(
      () => document(data.single),
      reason(SubtitleParseReason.limitExceeded),
    );
  });
  test('ASS header cannot inject separately timed events', () async {
    final data = await parse(
      mkv(
        tracks: track(codec: 'S_TEXT/ASS', private: assFixture()),
        clusters: cluster(block(text: '0,0,Default,,0,0,0,,packet')),
      ),
    );
    expect(
      () => document(data.single),
      reason(SubtitleParseReason.unsupported),
    );
  });
  test('ASS duplicate ReadOrder rejects ambiguous ordering', () async {
    final data = await parse(
      mkv(
        tracks: track(
          codec: 'S_TEXT/ASS',
          private: assFixture().split('[Events]').first,
        ),
        clusters: cluster([
          ...block(text: '0,0,Default,,0,0,0,,one'),
          ...block(text: '0,0,Default,,0,0,0,,two'),
        ]),
      ),
    );
    expect(() => document(data.single), reason(SubtitleParseReason.malformed));
  });

  test('every truncated prefix rejects without raw bounds errors', () async {
    final bytes = mkv();
    for (var n = 0; n < bytes.length; n++) {
      await expectLater(
        parse(bytes.sublist(0, n)),
        throwsA(isA<SubtitleParseException>()),
        reason: 'prefix $n',
      );
    }
  });

  test(
    'explicit default ReferencePriority zero preserves subtitle semantics',
    () async {
      final data = await parse(
        mkv(clusters: cluster(block(extra: uint(0xfa, 0)))),
      );
      expect(document(data.single).cues.single.payload, 'hello');
    },
  );
  test(
    'nonzero ReferencePriority remains an explicit unsupported boundary',
    () async {
      await expectLater(
        parse(mkv(clusters: cluster(block(extra: uint(0xfa, 1))))),
        reason(SubtitleParseReason.unsupported),
      );
    },
  );
  for (final disabledFirst in [false, true]) {
    test(
      '32 enabled tracks plus disabled entries, disabled first=$disabledFirst',
      () async {
        final disabled = track(number: 33, uid: 33, extra: uint(0xb9, 0));
        final data = await parse(
          mkv(
            tracks: [
              if (disabledFirst) ...disabled,
              for (var i = 1; i <= 32; i++) ...track(number: i, uid: i),
              if (!disabledFirst) ...disabled,
            ],
          ),
        );
        expect(data, hasLength(32));
        expect(data.any((d) => d.track.id == 'mkv:33'), false);
      },
    );
  }
  group('catalog integration', () {
    late Directory dir;
    late File media;
    late TextSubtitleRuntime runtime;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('yl-embedded-');
      media = await File('${dir.path}/media.mkv').writeAsBytes(mkv());
      runtime = TextSubtitleRuntime();
    });
    tearDown(() async {
      runtime.reset();
      await dir.delete(recursive: true);
    });
    Future<void> discover() => runtime.discover(YlFileSource(media.path));
    Future<YlExternalSubtitle> external({String id = 'external'}) async {
      final file = await File(
        '${dir.path}/external.srt',
      ).writeAsString('1\n00:00:01,000 --> 00:00:02,000\nexternal');
      return YlExternalSubtitle(
        id: id,
        source: YlFileSource(file.path),
        format: YlSubtitleFormat.srt,
      );
    }

    test(
      'external replace/clear preserves embedded selection and offset',
      () async {
        await discover();
        runtime.select('mkv:101');
        runtime.offset(const Duration(milliseconds: 100));
        await runtime.replace([await external()]);
        expect(runtime.state.tracks, hasLength(2));
        await runtime.replace([]);
        expect(runtime.state.selectedTrackId, 'mkv:101');
        expect(runtime.state.offset.inMilliseconds, 100);
        expect(
          runtime
              .cuesAt(const Duration(milliseconds: 1500))
              .single
              .text
              .toPlainText(),
          'hello',
        );
      },
    );
    test(
      'rediscovery preserves external selection and removes only embedded',
      () async {
        await runtime.replace([await external()]);
        runtime.select('external');
        await discover();
        await media.writeAsBytes(mkv(tracks: [], clusters: []));
        await discover();
        expect(runtime.state.tracks.single.id, 'external');
        expect(runtime.state.selectedTrackId, 'external');
      },
    );
    test(
      'missing UID clears selection rather than remapping same language',
      () async {
        await discover();
        runtime.select('mkv:101');
        await media.writeAsBytes(mkv(tracks: track(uid: 102)));
        await discover();
        expect(runtime.state.selectedTrackId, isNull);
        expect(runtime.cuesAt(const Duration(seconds: 1)), isEmpty);
      },
    );
    test('both directions of ID collision preserve the old catalog', () async {
      await discover();
      runtime.select('mkv:101');
      final old = runtime.state;
      await expectLater(
        runtime.replace([await external(id: 'mkv:101')]),
        failure(YlFailureCodes.sourceInvalid),
      );
      expect(runtime.state, old);
      runtime.reset();
      await runtime.replace([await external(id: 'mkv:101')]);
      final externalState = runtime.state;
      await expectLater(discover(), failure(YlFailureCodes.sourceInvalid));
      expect(runtime.state, externalState);
    });
    test('malformed discovery is atomic and sanitized', () async {
      await discover();
      runtime.select('mkv:101');
      final old = runtime.state;
      await media.writeAsBytes([1, 2, 3]);
      await expectLater(discover(), throwsA(isA<YlPlayerException>()));
      expect(runtime.state, old);
      expect(runtime.cuesAt(const Duration(seconds: 1)), hasLength(1));
    });
    test('unsupported network source makes no network request', () async {
      await expectLater(
        runtime.discover(
          YlNetworkSource(Uri.parse('http://secret.invalid/media.mkv')),
        ),
        failure(YlFailureCodes.subtitleUnsupported),
      );
    });
    test('missing file does not disclose path', () async {
      try {
        await runtime.discover(const YlFileSource('/sensitive/missing.mkv'));
        fail('accepted');
      } on YlPlayerException catch (e) {
        expect(e.toString(), isNot(contains('sensitive')));
        expect(e.failure.code, YlFailureCodes.sourceInvalid);
      }
    });

    test('embedded and external catalogs share the 4 MiB input budget', () async {
      final payload = 'x' * 16000;
      await media.writeAsBytes(
        mkv(
          clusters: cluster([
            for (var i = 0; i < 140; i++)
              ...block(time: i * 10, duration: 5, text: payload),
          ]),
        ),
      );
      await discover();
      runtime.select('mkv:101');
      final old = runtime.state;
      final sub = await external();
      await File((sub.source as YlFileSource).path).writeAsString(
        [
          for (var i = 0; i < 140; i++)
            '${i + 1}\n00:00:${(i ~/ 10).toString().padLeft(2, '0')},${(i % 10 * 100).toString().padLeft(3, '0')} --> 00:00:${(i ~/ 10).toString().padLeft(2, '0')},${(i % 10 * 100 + 50).toString().padLeft(3, '0')}\n$payload\n',
        ].join('\n'),
      );
      await expectLater(
        runtime.replace([sub]),
        failure(YlFailureCodes.subtitleTooLarge),
      );
      expect(runtime.state, old);
      runtime.reset();
      await runtime.replace([sub]);
      final before = runtime.state;
      await expectLater(discover(), failure(YlFailureCodes.subtitleTooLarge));
      expect(runtime.state, before);
    });
    test('queued scans are cancelled by external replacement', () async {
      final pending = List.generate(20, (_) => discover());
      final rejections = [
        for (final p in pending)
          expectLater(p, failure(YlFailureCodes.loadCancelled)),
      ];
      await runtime.replace([]);
      await Future.wait(rejections);
      expect(runtime.state.tracks, isEmpty);
    });
    test('runtime reset cancels discovery with no late catalog', () async {
      final pending = discover();
      final rejected = expectLater(
        pending,
        failure(YlFailureCodes.loadCancelled),
      );
      runtime.reset();
      await rejected;
      expect(runtime.state.tracks, isEmpty);
    });
  });
}
