import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/embedded_pgs_fixture.dart';
import 'support/pgs_fixture.dart';
import 'support/matroska_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final merged in [false, true]) {
    test(
      'actual Matroska PGS merged=$merged discovers, recolors and clears',
      () async {
        final dir = await Directory.systemTemp.createTemp('yl-epgs-');
        addTearDown(() => dir.delete(recursive: true));
        final f = await File(
          '${dir.path}/owned.mkv',
        ).writeAsBytes(embeddedPgs(merged: merged));
        final r = TextSubtitleRuntime();
        addTearDown(r.reset);
        await r.discover(YlFileSource(f.path));
        expect(r.state.tracks.single.id, 'mkv:101');
        expect(r.state.tracks.single.format, YlSubtitleFormat.pgs);
        r.select('mkv:101');
        expect(r.cuesAt(const Duration(milliseconds: 999)), isEmpty);
        final white = r
            .cuesAt(const Duration(seconds: 1))
            .single
            .cue
            .pgs!
            .bitmaps
            .single;
        expect(white.rgba.take(4), [255, 255, 255, 255]);
        expect([white.x, white.y, white.width, white.height], [20, 30, 4, 2]);
        expect(
          r
              .cuesAt(const Duration(seconds: 2))
              .single
              .cue
              .pgs!
              .bitmaps
              .single
              .rgba
              .take(4),
          [0, 0, 0, 255],
        );
        expect(r.cuesAt(const Duration(seconds: 3)), isEmpty);
      },
    );
  }
  test(
    'independent FFmpeg remux uses actual container zero-based PTS',
    () async {
      final r = TextSubtitleRuntime();
      addTearDown(r.reset);
      await r.discover(
        YlFileSource(
          File(
            'packages/yl_player/test/fixtures/embedded-pgs-owned.mkv',
          ).absolute.path,
        ),
      );
      r.select(r.state.tracks.single.id);
      expect(
        r.cuesAt(Duration.zero).single.cue.pgs!.bitmaps.single.rgba.take(4),
        [255, 255, 255, 255],
      );
      expect(
        r
            .cuesAt(const Duration(seconds: 1))
            .single
            .cue
            .pgs!
            .bitmaps
            .single
            .rgba
            .take(4),
        [0, 0, 0, 255],
      );
      expect(r.cuesAt(const Duration(seconds: 2)), isEmpty);
    },
  );
  for (final order in ['embedded-first', 'external-first', 'two-embedded']) {
    test(
      '64MiB expanded catalog budget $order preserves prior catalog',
      () async {
        final dir = await Directory.systemTemp.createTemp('yl-epgs-budget-');
        addTearDown(() => dir.delete(recursive: true));
        final large = <int>[
          ...pgsPcs(width: 2048, height: 2048, objects: [pgsRef(x: 0, y: 0)]),
          ...pgsWindow(w: 2048, h: 2048),
          ...pgsPalette(),
          ...pgsObject(
            w: 2048,
            h: 2048,
            data: [
              for (var y = 0; y < 2048; y++) ...[0, 0xc8, 0, 1, 0, 0],
            ],
          ),
          ...pgsEnd(),
          for (final ticks in [180000, 270000]) ...[
            ...pgsPcs(
              pts: ticks,
              width: 2048,
              height: 2048,
              state: 0,
              update: true,
            ),
            ...pgsPalette(pts: ticks),
            ...pgsEnd(ticks),
          ],
        ];
        final media = await File(
          '${dir.path}/large.mkv',
        ).writeAsBytes(embeddedPgs(sup: large, merged: true));
        final sup = await File('${dir.path}/large.sup').writeAsBytes(large);
        final r = TextSubtitleRuntime();
        addTearDown(r.reset);
        Future<void> embedded() => r.discover(YlFileSource(media.path));
        Future<void> external() => r.replace([
          YlExternalSubtitle(
            id: 'external',
            format: YlSubtitleFormat.pgs,
            source: YlFileSource(sup.path),
          ),
        ]);
        await (order == 'external-first' ? external() : embedded());
        r.select(r.state.tracks.single.id);
        final old = r.state;
        if (order == 'two-embedded') {
          final packets = pgsPackets(large);
          await media.writeAsBytes(
            mkv(
              tracks: [
                ...track(codec: 'S_HDMV/PGS'),
                ...track(number: 2, uid: 202, codec: 'S_HDMV/PGS'),
              ],
              clusters: cluster([
                for (final p in packets) ...pgsBlock(p.bytes, time: p.time),
                for (final p in packets)
                  ...pgsBlock(p.bytes, number: 2, time: p.time),
              ], time: 0),
            ),
          );
        }
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
        expect(r.cuesAt(const Duration(seconds: 1)), hasLength(1));
      },
    );
  }
}
