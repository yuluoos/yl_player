import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/chain_subtitle_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'independent Python double-zlib golden discovers and renders actual file',
    () async {
      final fixture = File('test/fixtures/subtitle-chain-owned.json');
      final f = fixture.existsSync()
          ? fixture
          : File('packages/yl_player/test/fixtures/subtitle-chain-owned.json');
      final g = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final dir = await Directory.systemTemp.createTemp('chain-golden-');
      addTearDown(() => dir.delete(recursive: true));
      final media = await File('${dir.path}/golden.mkv').writeAsBytes(
        mkv(
          tracks: track(
            codec: 'S_TEXT/WEBVTT',
            extra: [
              ...element(0x63a2, base64Decode(g['headerStored'] as String)),
              ...element(0x6d80, [
                for (final s in doubleZlib.reversed) ...s.bytes,
              ]),
            ],
          ),
          clusters: cluster(
            vobBlock(
              base64Decode(g['bodyStored'] as String),
              time: 1000,
              duration: 1000,
            ),
            time: 0,
          ),
        ),
      );
      final r = TextSubtitleRuntime();
      addTearDown(r.reset);
      await r.discover(YlFileSource(media.path));
      r.select('mkv:101');
      expect(
        r.cuesAt(const Duration(seconds: 1)).single.text.toPlainText(),
        'hello',
      );
      expect(
        r.cuesAt(const Duration(seconds: 1)).single.cue.payload,
        '<b>hello</b>',
      );
      expect(r.cuesAt(const Duration(seconds: 2)), isEmpty);
    },
  );
  for (final order in ['embedded-first', 'external-first', 'empty-track']) {
    test(
      'retained intermediate bytes prevent catalog budget bypass $order',
      () async {
        final dir = await Directory.systemTemp.createTemp('chain-budget-');
        addTearDown(() => dir.delete(recursive: true));
        final privateOnly = order == 'empty-track';
        final stages = [
          EncodingStage(0, scope: privateOnly ? 2 : 1),
          EncodingStage(1, scope: privateOnly ? 2 : 1),
        ];
        final header = utf8.encode(
          'WEBVTT\n\nNOTE ${List.filled(250000, 'x').join()}',
        );
        final packet = encodedChain(
          List.filled(16000, 65),
          stages,
          1,
          stored: true,
        );
        final media = await File('${dir.path}/budget.mkv').writeAsBytes(
          mkv(
            tracks: privateOnly
                ? [
                    for (var i = 0; i < 5; i++)
                      ...chainTrack(
                        stages: stages,
                        header: header,
                        number: i + 1,
                        uid: i + 101,
                        stored: true,
                      ),
                  ]
                : chainTrack(stages: stages),
            clusters: privateOnly
                ? []
                : cluster([
                    for (var i = 0; i < 85; i++)
                      ...vobBlock(packet, time: i, duration: 1),
                  ], time: 0),
          ),
        );
        final external = await File('${dir.path}/external.vtt').writeAsString(
          'WEBVTT\n\nNOTE ${List.filled(500000, 'x').join()}\n\n00:00:00.000 --> 00:00:01.000\nexternal',
        );
        final r = TextSubtitleRuntime();
        addTearDown(r.reset);
        Future<void> embedded() => r.discover(YlFileSource(media.path));
        Future<void> outside() => r.replace([
          YlExternalSubtitle(
            id: 'ext',
            format: YlSubtitleFormat.webvtt,
            source: YlFileSource(external.path),
          ),
        ]);
        await (order == 'external-first' ? outside() : embedded());
        r.select(r.state.tracks.first.id);
        final before = r.state;
        await expectLater(
          order == 'external-first' ? embedded() : outside(),
          throwsA(
            isA<YlPlayerException>().having(
              (e) => e.failure.code,
              'code',
              YlFailureCodes.subtitleTooLarge,
            ),
          ),
        );
        expect(r.state, same(before));
      },
    );
  }
}
