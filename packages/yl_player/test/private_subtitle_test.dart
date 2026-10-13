import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/private_subtitle_fixture.dart';
import 'support/matroska_fixture.dart';
import 'support/compressed_subtitle_fixture.dart';
import 'support/embedded_vobsub_fixture.dart' show vobBlock;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scope in [2, 3]) {
    test(
      'actual file private compression scope $scope discovers and renders',
      () async {
        final dir = await Directory.systemTemp.createTemp('yl-private-');
        addTearDown(() => dir.delete(recursive: true));
        final f = await File(
          '${dir.path}/owned.mkv',
        ).writeAsBytes(privateMkv(scope: scope));
        final r = TextSubtitleRuntime();
        addTearDown(r.reset);
        await r.discover(YlFileSource(f.path));
        r.select('mkv:101');
        expect(
          r.cuesAt(const Duration(seconds: 1)).single.cue.payload,
          'hello',
        );
        expect(r.cuesAt(const Duration(seconds: 2)), isEmpty);
      },
    );
  }
  test(
    'Python-compressed private and block render through actual file',
    () async {
      final g =
          jsonDecode(
                File(
                  'packages/yl_player/test/fixtures/subtitle-private-owned.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final dir = await Directory.systemTemp.createTemp('yl-private-golden-');
      addTearDown(() => dir.delete(recursive: true));
      final media = await File('${dir.path}/golden.mkv').writeAsBytes(
        mkv(
          tracks: track(
            codec: 'S_TEXT/WEBVTT',
            extra: [
              ...element(0x63a2, base64Decode(g['headerZlib'] as String)),
              ...compressionEncoding(scope: 3),
            ],
          ),
          clusters: cluster(
            vobBlock(
              base64Decode(g['bodyZlib'] as String),
              time: 0,
              duration: 1000,
            ),
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
    },
  );
  for (final order in ['embedded-first', 'external-first', 'empty-track']) {
    test('private stored and restored byte budget persists $order', () async {
      final dir = await Directory.systemTemp.createTemp('yl-private-budget-');
      addTearDown(() => dir.delete(recursive: true));
      final header = utf8.encode(
        "WEBVTT\n\nNOTE ${List.filled(250000, 'x').join()}",
      );
      final stored = ZLibEncoder(level: 0).convert(header);
      final media = await File('${dir.path}/owned.mkv').writeAsBytes(
        mkv(
          tracks: [
            for (var i = 1; i <= 8; i++)
              ...track(
                number: i,
                uid: i,
                codec: 'S_TEXT/WEBVTT',
                extra: [
                  ...element(0x63a2, stored),
                  ...compressionEncoding(scope: 2),
                ],
              ),
          ],
          clusters: cluster(
            order == 'empty-track'
                ? []
                : [for (var i = 1; i <= 8; i++) ...block(number: i)],
          ),
        ),
      );
      final text = await File('${dir.path}/external.vtt').writeAsString(
        "WEBVTT\n\nNOTE ${List.filled(1000000, 'x').join()}\n\n00:00:01.000 --> 00:00:02.000\nexternal",
      );
      final r = TextSubtitleRuntime();
      addTearDown(r.reset);
      Future<void> embedded() => r.discover(YlFileSource(media.path));
      Future<void> external() => r.replace([
        YlExternalSubtitle(
          id: 'ext',
          format: YlSubtitleFormat.webvtt,
          source: YlFileSource(text.path),
        ),
      ]);
      await (order == 'external-first' ? external() : embedded());
      r.select(r.state.tracks.first.id);
      final old = r.state;
      await expectLater(
        order == 'external-first' ? embedded() : external(),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.subtitleTooLarge,
          ),
        ),
      );
      expect(r.state, old);
      expect(
        r.cuesAt(const Duration(seconds: 1)),
        order == 'empty-track' ? isEmpty : hasLength(1),
      );
    });
  }
  test(
    'malformed private restoration leaves selected catalog intact',
    () async {
      final dir = await Directory.systemTemp.createTemp('yl-private-atomic-');
      addTearDown(() => dir.delete(recursive: true));
      final media = await File(
        '${dir.path}/owned.mkv',
      ).writeAsBytes(privateMkv());
      final r = TextSubtitleRuntime();
      addTearDown(r.reset);
      await r.discover(YlFileSource(media.path));
      r.select('mkv:101');
      final old = r.state;
      await media.writeAsBytes(
        mkv(
          tracks: track(
            codec: 'S_TEXT/WEBVTT',
            extra: [
              ...element(0x63a2, [0x78, 0x9c, 3]),
              ...compressionEncoding(scope: 2),
            ],
          ),
        ),
      );
      await expectLater(
        r.discover(YlFileSource(media.path)),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.subtitleMalformed,
          ),
        ),
      );
      expect(r.state, old);
      expect(r.cuesAt(const Duration(seconds: 1)).single.cue.payload, 'hello');
    },
  );
}
