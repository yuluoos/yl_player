import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'package:yl_player/src/subtitles/pgs_overlay.dart';
import 'package:yl_player/yl_player.dart';
import 'support/vobsub_fixture.dart';
import 'support/fake_player_platform.dart';
import 'pgs_overlay_test.dart'
    show at, overlay, pixels, rgb, square, settleDecode;

void main() {
  for (final ms in [1000, 1512, 2024]) {
    testWidgets('VobSub manual field/color/alpha grid at $ms ms', (
      tester,
    ) async {
      final d = SubtitleDocument.parseVobSub(
        vobSub(spu: vobAnimated()),
        vobIdx(),
      );
      final key = GlobalKey();
      await tester.pumpWidget(overlay(at(d, ms), boundary: key));
      final (image, data) = await pixels(tester, key);
      for (var y = 0; y < 200; y++) {
        for (var x = 0; x < 300; x++) {
          var expected = <int>[0, 0, 255];
          if (ms < 2024 && x >= 90 && x < 98 && y >= 60 && y < 66) {
            if (y >= 64) {
              expected = [0, 255, 0];
            } else if (y < 62 && x >= 94) {
              expected = ms < 1512 ? [136, 0, 119] : [0, 0, 255];
            } else {
              expected = [255, 255, 255];
            }
          }
          final actual = rgb(data, x, y);
          if (actual[0] != expected[0] ||
              actual[1] != expected[1] ||
              actual[2] != expected[2]) {
            expect(actual, expected, reason: 'pixel($x,$y)');
          }
        }
      }
      final output = Platform.environment['YL_VOBSUB_EVIDENCE_DIR'];
      if (output != null) {
        await tester.runAsync(() async {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$output/fields-$ms.png',
          ).writeAsBytes(png!.buffer.asUint8List());
        });
      }
      image.dispose();
    });
  }
  testWidgets('VobSub reuses cropped bitmap geometry', (tester) async {
    final d = SubtitleDocument.parseVobSub(vobSub(), vobIdx());
    final key = GlobalKey();
    await tester.pumpWidget(
      overlay(at(d, 1000), boundary: key, fit: BoxFit.cover),
    );
    final (image, data) = await pixels(tester, key);
    expect(rgb(data, 60, 40), [255, 255, 255]);
    expect(rgb(data, 60, 46), [0, 255, 0]);
    expect(rgb(data, 60, 39), [0, 0, 255]);
    expect(rgb(data, 72, 46), [0, 0, 255]);
    image.dispose();
  });
  testWidgets(
    'public VobSub pair: first frame/offset/seek/off/source reset release images',
    (tester) async {
      final created = <ui.Image>[];
      final oldCreate = ui.Image.onCreate;
      ui.Image.onCreate = (i) {
        created.add(i);
        oldCreate?.call(i);
      };
      addTearDown(() => ui.Image.onCreate = oldCreate);
      final backend = FakePlatformPlayer();
      final player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
        enableTextSubtitles: true,
      );
      addTearDown(player.dispose);
      final pending = player.load(const YlFileSource('/owned.mp4'));
      const sid = YlPlaybackSessionId('pgs');
      backend.commit(sid);
      final session = await pending;
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('vobsub-view-');
        addTearDown(() => dir.delete(recursive: true));
        final f = await File('${dir.path}/owned.sub').writeAsBytes(vobSub());
        await session.replaceExternalSubtitles([
          YlExternalSubtitle(
            id: 'pgs',
            format: YlSubtitleFormat.vobsub,
            companionSource: YlFileSource(
              (await File('${dir.path}/owned.idx').writeAsBytes(vobIdx())).path,
            ),
            source: YlFileSource(f.path),
          ),
        ]);
      });
      await session.selectSubtitleTrack('pgs');
      void position(int ms, {bool paused = false}) => backend.emitState(
        backend.state.copyWith(
          revision: backend.state.revision + 1,
          status: paused ? YlPlaybackStatus.paused : YlPlaybackStatus.playing,
          timeline: YlTimeline(position: Duration(milliseconds: ms)),
          videoGeometry: square,
        ),
      );
      position(1000);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: YlPlayerView(controller: player),
        ),
      );
      expect(find.byType(PgsSubtitleOverlay), findsNothing);
      expect(created, isEmpty);
      backend.emitFirstFrame(sid);
      position(1000);
      await tester.pump();
      expect(find.byType(PgsSubtitleOverlay), findsOneWidget);
      await settleDecode(tester);
      expect(created, hasLength(1));
      position(1000, paused: true);
      await tester.pump(const Duration(seconds: 10));
      await settleDecode(tester);
      expect(created, hasLength(1));
      await session.setSubtitleOffset(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.byType(PgsSubtitleOverlay), findsNothing);
      expect(created.last.debugDisposed, true);
      position(1600);
      await tester.pump();
      expect(find.byType(PgsSubtitleOverlay), findsOneWidget);
      await session.seekTo(Duration.zero);
      await tester.pump();
      expect(find.byType(PgsSubtitleOverlay), findsNothing);
      expect(created.every((i) => i.debugDisposed), true);
      position(1600);
      await tester.pump();
      await session.selectSubtitleTrack(null);
      await tester.pump();
      expect(created.every((i) => i.debugDisposed), true);
      await session.selectSubtitleTrack('pgs');
      await tester.pump();
      final next = player.load(const YlFileSource('/next.mp4'));
      backend.commit(const YlPlaybackSessionId('next'));
      await next;
      await tester.pump();
      expect(find.byType(PgsSubtitleOverlay), findsNothing);
      expect(created.every((i) => i.debugDisposed), true);
    },
  );
}
