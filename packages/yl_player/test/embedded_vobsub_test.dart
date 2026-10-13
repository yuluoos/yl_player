import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/embedded_vobsub_fixture.dart';
import 'support/vobsub_fixture.dart';
import 'support/matroska_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'actual Matroska VobSub discovers, selects, animates and clears',
    () async {
      final dir = await Directory.systemTemp.createTemp('yl-evob-');
      addTearDown(() => dir.delete(recursive: true));
      final f = await File(
        '${dir.path}/owned.mkv',
      ).writeAsBytes(embeddedVobSub());
      final r = TextSubtitleRuntime();
      addTearDown(r.reset);
      await r.discover(YlFileSource(f.path));
      expect(r.state.tracks.single.id, 'mkv:101');
      expect(r.state.tracks.single.format, YlSubtitleFormat.vobsub);
      r.select('mkv:101');
      expect(r.cuesAt(const Duration(milliseconds: 999)), isEmpty);
      final b = r
          .cuesAt(const Duration(seconds: 1))
          .single
          .cue
          .pgs!
          .bitmaps
          .single;
      expect([b.x, b.y, b.width, b.height], [20, 30, 4, 3]);
      expect(b.rgba.take(4), [255, 255, 255, 255]);
      expect(
        r
            .cuesAt(const Duration(milliseconds: 1600))
            .single
            .cue
            .pgs!
            .bitmaps
            .single
            .rgba
            .skip(8)
            .take(4),
        [0, 0, 0, 0],
      );
      expect(r.cuesAt(const Duration(milliseconds: 2024)), isEmpty);
    },
  );
  test(
    'independent FFmpeg remux keeps raw SPU timing and header without IDX rows',
    () async {
      final r = TextSubtitleRuntime();
      addTearDown(r.reset);
      await r.discover(
        YlFileSource(
          File(
            'packages/yl_player/test/fixtures/embedded-vobsub-owned.mkv',
          ).absolute.path,
        ),
      );
      expect(r.state.tracks.single.format, YlSubtitleFormat.vobsub);
      r.select(r.state.tracks.single.id);
      expect(r.cuesAt(const Duration(milliseconds: 999)), isEmpty);
      expect(
        r
            .cuesAt(const Duration(seconds: 1))
            .single
            .cue
            .pgs!
            .bitmaps
            .single
            .rgba
            .skip(8)
            .take(4),
        [136, 0, 0, 136],
      );
      expect(
        r
            .cuesAt(const Duration(milliseconds: 1512))
            .single
            .cue
            .pgs!
            .bitmaps
            .single
            .rgba
            .skip(8)
            .take(4),
        [0, 0, 0, 0],
      );
      expect(r.cuesAt(const Duration(milliseconds: 2024)), isEmpty);
    },
  );
  test('malformed SPU cannot replace a selected valid catalog', () async {
    final dir = await Directory.systemTemp.createTemp('yl-evob-atomic-');
    addTearDown(() => dir.delete(recursive: true));
    final f = await File(
      '${dir.path}/owned.mkv',
    ).writeAsBytes(embeddedVobSub());
    final r = TextSubtitleRuntime();
    addTearDown(r.reset);
    await r.discover(YlFileSource(f.path));
    r.select('mkv:101');
    final old = r.state;
    await f.writeAsBytes(embeddedVobSub(spu: [1, 2, 3]));
    await expectLater(
      r.discover(YlFileSource(f.path)),
      throwsA(isA<YlPlayerException>()),
    );
    expect(r.state, old);
    expect(r.cuesAt(const Duration(seconds: 1)), hasLength(1));
  });
  for (final order in ['embedded-first', 'external-first', 'two-embedded']) {
    test(
      '64MiB expanded VobSub catalog $order rejects before publication',
      () async {
        final dir = await Directory.systemTemp.createTemp('yl-evob-budget-');
        addTearDown(() => dir.delete(recursive: true));
        final large = vobSpu(
          x: 0,
          y: 0,
          w: 2048,
          h: 2048,
          top: [
            for (var i = 0; i < 1024; i++) ...[0, 1],
          ],
          bottom: [
            for (var i = 0; i < 1024; i++) ...[0, 1],
          ],
        );
        final header = vobIdxText(
          width: 2048,
          height: 2048,
        ).split('\nid:').first;
        final media = await File('${dir.path}/large.mkv').writeAsBytes(
          mkv(
            tracks: track(codec: 'S_VOBSUB', private: header),
            clusters: cluster([
              for (final time in [1000, 3000, 5000])
                ...vobBlock(large, time: time),
            ], time: 0),
          ),
        );
        final bytes = vobSub(spu: large);
        final sub = await File(
          '${dir.path}/large.sub',
        ).writeAsBytes([...bytes, ...bytes, ...bytes]);
        final idx = await File('${dir.path}/large.idx').writeAsString(
          vobIdxText(
            width: 2048,
            height: 2048,
            tail:
                'timestamp: 00:00:03:000, filepos: ${bytes.length.toRadixString(16)}\ntimestamp: 00:00:05:000, filepos: ${(2 * bytes.length).toRadixString(16)}',
          ),
        );
        final r = TextSubtitleRuntime();
        addTearDown(r.reset);
        Future<void> embedded() => r.discover(YlFileSource(media.path));
        Future<void> external() => r.replace([
          YlExternalSubtitle(
            id: 'external',
            format: YlSubtitleFormat.vobsub,
            source: YlFileSource(sub.path),
            companionSource: YlFileSource(idx.path),
          ),
        ]);
        await (order == 'external-first' ? external() : embedded());
        r.select(r.state.tracks.single.id);
        final old = r.state;
        if (order == 'two-embedded') {
          await media.writeAsBytes(
            mkv(
              tracks: [
                ...track(codec: 'S_VOBSUB', private: header),
                ...track(
                  number: 2,
                  uid: 202,
                  codec: 'S_VOBSUB',
                  private: header,
                ),
              ],
              clusters: cluster([
                for (final number in [1, 2])
                  for (final time in [1000, 3000, 5000])
                    ...vobBlock(large, number: number, time: time),
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
