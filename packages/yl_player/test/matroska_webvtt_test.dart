import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/matroska_subtitles.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'package:yl_player/src/subtitles/subtitle_resource.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/matroska_fixture.dart';
import 'support/matroska_webvtt_fixture.dart';

Future<List<EmbeddedSubtitleData>> parse(List<int> b) => MatroskaSubtitles(
  b.length,
  (p, n) async => b.sublist(p, p + n),
  SubtitleCancellation(),
).parse();
SubtitleDocument document(EmbeddedSubtitleData d) =>
    SubtitleDocument.fromEmbeddedPackets(
      d.packets,
      format: SubtitleFormat.webvtt,
      codecPrivate: d.codecPrivate,
      sourceBytes: d.sourceBytes,
    );
Matcher reason(SubtitleParseReason r) =>
    throwsA(isA<SubtitleParseException>().having((e) => e.reason, 'reason', r));
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Matroska WebVTT header, cue text and additions stay separate', () async {
    final d = (await parse(
      fixture(
        extra: additions(
          'position:25%,line-left align:start\nowned\nNOTE preceding\n\nNOTE last',
        ),
      ),
    )).single;
    expect(d.track.format, YlSubtitleFormat.webvtt);
    expect(d.track.id, 'mkv:101');
    expect(d.codecPrivate, isNull);
    final c = document(d).cues.single;
    expect(c.payload, '<b>hello</b>');
    expect(c.identifier, 'owned');
    expect(c.start, const Duration(seconds: 1));
    expect(c.end, const Duration(seconds: 2));
    expect(c.positionPercent, 25);
    expect(c.alignment, 'start');
    expect(d.sourceBytes, greaterThan(80));
  });
  for (final codec in ['D_WEBVTT/SUBTITLES', 'D_WEBVTT/CAPTIONS']) {
    test('$codec uses identifier then settings inside Block', () async {
      final d = (await parse(
        fixture(
          codec: codec,
          header: null,
          text: 'owned\nposition:75%,line-right align:end\nhello',
        ),
      )).single;
      final c = document(d).cues.single;
      expect(c.identifier, 'owned');
      expect(c.positionPercent, 75);
      expect(c.alignment, 'end');
      expect(c.payload, 'hello');
    });
  }
  test('no additions uses empty settings; default BlockAddID is one', () async {
    expect(
      document((await parse(fixture())).single).cues.single.identifier,
      isNull,
    );
    expect(
      document(
        (await parse(fixture(extra: additions('\n\n', id: null)))).single,
      ).cues.single.identifier,
      isNull,
    );
  });
  test(
    'explicit MaxBlockAdditionID one and final identifier without LF',
    () async {
      final d = (await parse(
        fixture(extra: additions('\nidentifier'), trackExtra: uint(0x537f, 1)),
      )).single;
      expect(document(d).cues.single.identifier, 'identifier');
    },
  );
  test('CRLF metadata and payload normalize independently', () async {
    final c = document(
      (await parse(
        fixture(
          text: 'one\r\ntwo',
          extra: additions('align:end\r\nid\r\nNOTE ok'),
        ),
      )).single,
    ).cues.single;
    expect(c.payload, 'one\ntwo');
    expect(c.identifier, 'id');
    expect(c.alignment, 'end');
  });
  final malformed = <String, List<int>>{
    'missing private': fixture(header: null),
    'invalid private': fixture(header: 'bad'),
    'empty additions': fixture(extra: element(0x75a1, [])),
    'missing data': fixture(
      extra: element(0x75a1, element(0xa6, uint(0xee, 1))),
    ),
    'duplicate data': fixture(
      extra: element(
        0x75a1,
        element(0xa6, [...str(0xa5, '\n\n'), ...str(0xa5, '\n\n')]),
      ),
    ),
    'missing metadata line': fixture(extra: additions('align:end')),
    'invalid identifier': fixture(extra: additions('\na --> b\n')),
    'NUL note': fixture(extra: additions('\n\nNOTE \u0000')),
    'invalid UTF8 metadata': fixture(
      extra: element(0x75a1, element(0xa6, element(0xa5, [255]))),
    ),
    'bad settings': fixture(extra: additions('position:200%\n\n')),
    'D missing prefix': fixture(
      codec: 'D_WEBVTT/SUBTITLES',
      header: null,
      text: 'hello',
    ),
    'D missing payload': fixture(
      codec: 'D_WEBVTT/SUBTITLES',
      header: null,
      text: 'id\n\n',
    ),
  };
  for (final e in malformed.entries) {
    test(
      'rejects malformed ${e.key}',
      () async =>
          expectLater(parse(e.value), reason(SubtitleParseReason.malformed)),
    );
  }
  final unsupported = <String, List<int>>{
    'header style': fixture(header: 'WEBVTT\n\nSTYLE\n::cue { color: red }'),
    'header cues': fixture(
      header: 'WEBVTT\n\n00:00.000 --> 00:01.000\ninjected',
    ),
    'note cues': fixture(
      extra: additions('\n\n00:00.000 --> 00:01.000\ninjected'),
    ),
    'note style': fixture(extra: additions('\n\nSTYLE\n::cue { color: red }')),
    'vertical setting': fixture(extra: additions('vertical:rl\n\n')),
    'other addition ID': fixture(extra: additions('\n\n', id: 2)),
    'multiple additions': fixture(
      extra: element(0x75a1, [
        ...element(0xa6, str(0xa5, '\n\n')),
        ...element(0xa6, str(0xa5, '\n\n')),
      ]),
    ),
    'max addition ID': fixture(trackExtra: uint(0x537f, 2)),
    'D private': fixture(codec: 'D_WEBVTT/SUBTITLES', text: '\n\nhello'),
    'D additions': fixture(
      codec: 'D_WEBVTT/SUBTITLES',
      header: null,
      text: '\n\nhello',
      extra: additions('\n\n'),
    ),
    'missing BlockDuration': fixture(
      duration: null,
      trackExtra: uint(0x23e383, 1000000000),
    ),
    'metadata track': fixture(codec: 'D_WEBVTT/METADATA', header: null),
  };
  for (final e in unsupported.entries) {
    test(
      'rejects unsupported ${e.key}',
      () async =>
          expectLater(parse(e.value), reason(SubtitleParseReason.unsupported)),
    );
  }
  test('metadata limits checked before oversized payload read', () async {
    final b = fixture(extra: additions('\n\nNOTE ${'x' * 65536}'));
    var largest = 0;
    await expectLater(
      MatroskaSubtitles(b.length, (p, n) async {
        if (n > largest) largest = n;
        return b.sublist(p, p + n);
      }, SubtitleCancellation()).parse(),
      reason(SubtitleParseReason.limitExceeded),
    );
    expect(largest, lessThan(65536));
  });
  test(
    'identifier limit is independent of total metadata bytes',
    () async => expectLater(
      parse(fixture(extra: additions('\n${'i' * 1025}\n'))),
      reason(SubtitleParseReason.limitExceeded),
    ),
  );
  test('raw ignored comments are retained in document input budget', () async {
    final text = '\n\nNOTE ${'x' * 16000}';
    final b = fixture(extra: additions(text));
    final d = (await parse(b)).single;
    expect(document(d).inputBytes, d.sourceBytes);
    expect(
      d.sourceBytes,
      utf8.encode('WEBVTT\n\nNOTE owned header').length +
          utf8.encode('<b>hello</b>').length +
          utf8.encode(text).length,
    );
  });
  test(
    'independently muxed FFmpeg WebVTT discovers and renders exact times',
    () async {
      final runtime = TextSubtitleRuntime();
      addTearDown(runtime.reset);
      await runtime.discover(
        YlFileSource(
          File(
            'packages/yl_player/test/fixtures/matroska-webvtt-owned.mkv',
          ).absolute.path,
        ),
      );
      expect(runtime.state.tracks.single.format, YlSubtitleFormat.webvtt);
      runtime.select(runtime.state.tracks.single.id);
      expect(runtime.cuesAt(const Duration(milliseconds: 502)), isEmpty);
      expect(
        runtime
            .cuesAt(const Duration(milliseconds: 503))
            .single
            .text
            .toPlainText(),
        'Owned Matroska WebVTT',
      );
      expect(runtime.cuesAt(const Duration(milliseconds: 1707)), isEmpty);
    },
  );
  test('BlockAdditional totals cannot bypass the scan input limit', () async {
    await expectLater(
      parse(
        mkv(
          tracks: track(codec: 'S_TEXT/WEBVTT', private: 'WEBVTT'),
          clusters: cluster([
            for (var i = 0; i < 70; i++)
              ...block(
                time: i * 10,
                duration: 5,
                extra: additions('\n\nNOTE ${'x' * 64000}'),
              ),
          ]),
        ),
      ),
      reason(SubtitleParseReason.limitExceeded),
    );
  });
  for (final embeddedFirst in [true, false]) {
    test(
      'ignored metadata shares external catalog budget embeddedFirst=$embeddedFirst',
      () async {
        final dir = await Directory.systemTemp.createTemp('yl-mwv-budget-');
        addTearDown(() => dir.delete(recursive: true));
        final media = await File('${dir.path}/owned.mkv').writeAsBytes(
          mkv(
            tracks: track(codec: 'S_TEXT/WEBVTT', private: 'WEBVTT'),
            clusters: cluster([
              for (var i = 0; i < 35; i++)
                ...block(
                  time: i * 10,
                  duration: 5,
                  extra: additions('\n\nNOTE ${'x' * 64000}'),
                ),
            ]),
          ),
        );
        final ext = await File(
          '${dir.path}/owned.vtt',
        ).writeAsString('WEBVTT\n\nNOTE ${'x' * 2200000}');
        final runtime = TextSubtitleRuntime();
        addTearDown(runtime.reset);
        Future<void> embedded() => runtime.discover(YlFileSource(media.path));
        Future<void> external() => runtime.replace([
          YlExternalSubtitle(
            id: 'external',
            source: YlFileSource(ext.path),
            format: YlSubtitleFormat.webvtt,
          ),
        ]);
        await (embeddedFirst ? embedded() : external());
        final old = runtime.state;
        await expectLater(
          embeddedFirst ? external() : embedded(),
          throwsA(
            isA<YlPlayerException>().having(
              (e) => e.failure.code,
              'code',
              YlFailureCodes.subtitleTooLarge,
            ),
          ),
        );
        expect(runtime.state, old);
      },
    );
  }
  test(
    'render-time advanced markup fails atomically without replacing catalog',
    () async {
      final dir = await Directory.systemTemp.createTemp('yl-mwv-markup-');
      addTearDown(() => dir.delete(recursive: true));
      final file = await File('${dir.path}/owned.mkv').writeAsBytes(fixture());
      final r = TextSubtitleRuntime();
      addTearDown(r.reset);
      await r.discover(YlFileSource(file.path));
      r.select('mkv:101');
      final old = r.state;
      await file.writeAsBytes(fixture(text: '<00:00:01.000>timed'));
      await expectLater(
        r.discover(YlFileSource(file.path)),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.subtitleUnsupported,
          ),
        ),
      );
      expect(r.state, old);
      expect(
        r.cuesAt(const Duration(seconds: 1)).single.text.toPlainText(),
        'hello',
      );
    },
  );
}
