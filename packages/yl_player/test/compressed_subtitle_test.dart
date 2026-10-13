import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/compressed_subtitle_fixture.dart';
import 'support/matroska_fixture.dart';
import 'support/embedded_vobsub_fixture.dart' show vobBlock;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final algo in [0, 3]) {
    test(
      'actual file compressed Matroska algorithm $algo discovers and renders',
      () async {
        final dir = await Directory.systemTemp.createTemp('yl-comp-');
        addTearDown(() => dir.delete(recursive: true));
        final f = await File(
          '${dir.path}/owned.mkv',
        ).writeAsBytes(compressedMkv(algo: algo));
        final r = TextSubtitleRuntime();
        addTearDown(r.reset);
        await r.discover(YlFileSource(f.path));
        r.select('mkv:101');
        expect(
          r.cuesAt(const Duration(seconds: 1)).single.cue.payload,
          'compressed subtitle',
        );
        expect(r.cuesAt(const Duration(seconds: 2)), isEmpty);
      },
    );
  }
  for (final order in ['embedded-first', 'external-first']) {
    test('stored compressed bytes remain charged in catalog $order', () async {
      final dir = await Directory.systemTemp.createTemp('yl-comp-budget-');
      addTearDown(() => dir.delete(recursive: true));
      final packet = ZLibEncoder(level: 0).convert(List.filled(16000, 65));
      final media = await File('${dir.path}/owned.mkv').writeAsBytes(
        mkv(
          tracks: track(extra: compressionEncoding()),
          clusters: cluster([
            for (var i = 0; i < 128; i++)
              ...vobBlock(packet, time: i, duration: 1),
          ], time: 0),
        ),
      );
      final text = await File('${dir.path}/external.vtt').writeAsString(
        "WEBVTT\n\nNOTE ${List.filled(1000000, 'x').join()}\n\n00:00:00.000 --> 00:00:01.000\nexternal",
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
      await (order == 'embedded-first' ? embedded() : external());
      r.select(r.state.tracks.single.id);
      final old = r.state;
      await expectLater(
        order == 'embedded-first' ? external() : embedded(),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.subtitleTooLarge,
          ),
        ),
      );
      expect(r.state, old);
      expect(r.cuesAt(Duration.zero), hasLength(1));
    });
  }
  test(
    'damaged compressed stream leaves prior selected catalog intact',
    () async {
      final dir = await Directory.systemTemp.createTemp('yl-comp-atomic-');
      addTearDown(() => dir.delete(recursive: true));
      final media = await File(
        '${dir.path}/owned.mkv',
      ).writeAsBytes(compressedMkv());
      final r = TextSubtitleRuntime();
      addTearDown(r.reset);
      await r.discover(YlFileSource(media.path));
      r.select('mkv:101');
      final old = r.state;
      await media.writeAsBytes(
        mkv(
          tracks: track(extra: compressionEncoding()),
          clusters: cluster(vobBlock([0x78, 0x9c, 3], duration: 1000)),
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
      expect(
        r.cuesAt(const Duration(seconds: 1)).single.cue.payload,
        'compressed subtitle',
      );
    },
  );
}
