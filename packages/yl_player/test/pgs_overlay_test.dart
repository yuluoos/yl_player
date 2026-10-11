import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'package:yl_player/src/subtitles/text_subtitle_overlay.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'package:yl_player/src/subtitles/pgs_overlay.dart';
import 'package:yl_player/yl_player.dart';
import 'support/pgs_fixture.dart';
import 'support/fake_player_platform.dart';

const square = YlVideoGeometry(
  encodedSize: YlPixelSize(100, 100),
  displaySize: YlPixelSize(100, 100),
);
List<TextSubtitleCue> at(SubtitleDocument d, int ms) => [
  for (final c in d.cuesAt(Duration(milliseconds: ms)))
    TextSubtitleCue(c, const TextSpan()),
];
Widget overlay(
  List<TextSubtitleCue> cues, {
  GlobalKey? boundary,
  YlVideoGeometry geometry = square,
  BoxFit fit = BoxFit.contain,
  Alignment alignment = Alignment.center,
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: Align(
    alignment: Alignment.topLeft,
    child: RepaintBoundary(
      key: boundary,
      child: SizedBox(
        width: 300,
        height: 200,
        child: ColoredBox(
          color: const Color(0xff0000ff),
          child: TextSubtitleOverlay(
            cues: cues,
            geometry: geometry,
            fit: fit,
            alignment: alignment,
          ),
        ),
      ),
    ),
  ),
);
Future<(ui.Image, ByteData)> pixels(WidgetTester tester, GlobalKey key) async {
  await settleDecode(tester);
  final image = (await tester.runAsync(
    () => (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
        .toImage(),
  ))!;
  final bytes = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  return (image, bytes);
}

List<int> rgb(ByteData data, int x, int y) => [
  for (var c = 0; c < 3; c++) data.getUint8((y * 300 + x) * 4 + c),
];
Future<void> settleDecode(WidgetTester tester) async {
  // Pump between engine callbacks: each sequential object decode resumes in
  // the widget test's fake async zone before starting the next engine request.
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

void main() {
  for (final ms in [1000, 2000, 3000]) {
    testWidgets('PGS exact palette/alpha/clear pixel grid at $ms ms', (
      tester,
    ) async {
      final d = SubtitleDocument.parse(
        pgsFixture(),
        format: SubtitleFormat.pgs,
      );
      final key = GlobalKey();
      await tester.pumpWidget(overlay(at(d, ms), boundary: key));
      final (image, data) = await pixels(tester, key);
      for (var y = 0; y < 200; y++) {
        for (var x = 0; x < 300; x++) {
          var expected = <int>[0, 0, 255];
          if (ms < 3000 && x >= 90 && x < 98 && y >= 60 && y < 64) {
            if (y < 62 && x >= 94) {
              expected = [127, 0, 127];
            } else {
              expected = ms == 1000 ? [255, 255, 255] : [0, 0, 0];
            }
          }
          final actual = rgb(data, x, y);
          if (actual[0] != expected[0] ||
              actual[1] != expected[1] ||
              actual[2] != expected[2]) {
            expect(actual, expected, reason: 'pixel ($x,$y)');
          }
        }
      }
      final output = Platform.environment['YL_PGS_EVIDENCE_DIR'];
      if (output != null) {
        await tester.runAsync(() async {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$output/palette-$ms.png',
          ).writeAsBytes(png!.buffer.asUint8List());
        });
      }
      image.dispose();
    });
  }
  testWidgets('PGS cover follows actual source crop, not squeezed full plane', (
    tester,
  ) async {
    final d = SubtitleDocument.parse(pgsFixture(), format: SubtitleFormat.pgs);
    final key = GlobalKey();
    await tester.pumpWidget(
      overlay(at(d, 1000), boundary: key, fit: BoxFit.cover),
    );
    final (image, data) = await pixels(tester, key);
    expect(rgb(data, 60, 40), [255, 255, 255]);
    expect(rgb(data, 71, 45), [255, 255, 255]);
    expect(rgb(data, 60, 39), [0, 0, 255]);
    expect(rgb(data, 72, 40), [0, 0, 255]);
    image.dispose();
  });
  for (final (
        name,
        alignment,
        geometry,
        objectX,
        objectY,
        expectedX,
        expectedY,
        oldX,
        oldY,
      )
      in [
        ('right', const Alignment(2, 0), square, 20, 30, 190, 60, 180, 60),
        ('left', const Alignment(-2, 0), square, 30, 30, 10, 60, 45, 60),
        (
          'bottom',
          const Alignment(0, 2),
          const YlVideoGeometry(
            encodedSize: YlPixelSize(300, 100),
            displaySize: YlPixelSize(300, 100),
          ),
          20,
          30,
          60,
          180,
          60,
          165,
        ),
        (
          'top',
          const Alignment(0, -2),
          const YlVideoGeometry(
            encodedSize: YlPixelSize(300, 100),
            displaySize: YlPixelSize(300, 100),
          ),
          20,
          60,
          60,
          10,
          60,
          30,
        ),
      ]) {
    testWidgets(
      'PGS partially offscreen $name alignment preserves video scale',
      (tester) async {
        final d = SubtitleDocument.parse([
          ...pgsPcs(
            objects: [pgsRef(x: objectX, y: objectY)],
          ),
          ...pgsWindow(),
          ...pgsPalette(),
          ...pgsObject(),
          ...pgsEnd(),
        ], format: SubtitleFormat.pgs);
        final key = GlobalKey();
        await tester.pumpWidget(
          overlay(
            at(d, 1000),
            boundary: key,
            alignment: alignment,
            geometry: geometry,
          ),
        );
        final (image, data) = await pixels(tester, key);
        expect(rgb(data, expectedX, expectedY), [255, 255, 255]);
        expect(rgb(data, oldX, oldY), [0, 0, 255]);
        image.dispose();
      },
    );
  }
  testWidgets('PGS rotation/PAR remains upright in the fitted aperture', (
    tester,
  ) async {
    final d = SubtitleDocument.parse(pgsFixture(), format: SubtitleFormat.pgs);
    final key = GlobalKey();
    await tester.pumpWidget(
      overlay(
        at(d, 1000),
        boundary: key,
        geometry: const YlVideoGeometry(
          encodedSize: YlPixelSize(200, 100),
          displaySize: YlPixelSize(200, 100),
          pixelAspectRatio: 1.5,
          rotationDegrees: 90,
        ),
      ),
    );
    final (image, data) = await pixels(tester, key);
    expect(rgb(data, 130, 61), [255, 255, 255]);
    expect(rgb(data, 129, 61), [0, 0, 255]);
    image.dispose();
  });
  testWidgets('late decoding is disposed and global jobs coalesce at two', (
    tester,
  ) async {
    final d = SubtitleDocument.parse(pgsFixture(), format: SubtitleFormat.pgs);
    final frame = d.cues.first.pgs!;
    final images = (await tester.runAsync(
      () async => [
        for (var i = 0; i < 3; i++) await decodePgsBitmap(frame.bitmaps.single),
      ],
    ))!;
    final waits = <Completer<ui.Image>>[];
    Future<ui.Image> hold(PgsBitmap _) {
      final c = Completer<ui.Image>();
      waits.add(c);
      return c.future;
    }

    Widget held(int generation) => Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          PgsSubtitleOverlay(
            key: ValueKey(generation),
            frame: frame,
            decoder: hold,
          ),
        ],
      ),
    );
    // Repeated unmounts must not evade the global in-flight bound.
    for (var i = 0; i < 20; i++) {
      await tester.pumpWidget(held(i));
    }
    expect(waits, hasLength(2));
    waits[0].complete(images[0]);
    await tester.pump();
    expect(images[0].debugDisposed, true);
    expect(waits, hasLength(3)); // Only the most recent queued view starts.
    waits[2].complete(images[2]);
    await tester.pump();
    expect(images[2].debugDisposed, false);
    await tester.pumpWidget(const SizedBox());
    expect(images[2].debugDisposed, true);
    waits[1].complete(images[1]);
    await tester.pump();
    expect(images.every((i) => i.debugDisposed), true);
    expect(waits, hasLength(3));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'partial decode failure releases first image and sanitizes error',
    (tester) async {
      final d = SubtitleDocument.parse([
        ...pgsPcs(objects: [pgsRef(), pgsRef(x: 21)]),
        ...pgsWindow(),
        ...pgsPalette(),
        ...pgsObject(),
        ...pgsEnd(),
      ], format: SubtitleFormat.pgs);
      final frame = d.cues.single.pgs!;
      final first = (await tester.runAsync(
        () => decodePgsBitmap(frame.bitmaps.first),
      ))!;
      var count = 0;
      Future<ui.Image> failSecond(PgsBitmap _) async {
        if (++count == 1) return first;
        throw StateError('private source/token must not escape');
      }

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [PgsSubtitleOverlay(frame: frame, decoder: failSecond)],
          ),
        ),
      );
      await tester.pump();
      expect(count, 2);
      expect(first.debugDisposed, true);
      expect(tester.takeException().toString(), 'PGS image creation failed.');
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('overlapping objects preserve paint order and alpha', (
    tester,
  ) async {
    final d = SubtitleDocument.parse([
      ...pgsPcs(objects: [pgsRef(), pgsRef(id: 2)]),
      ...pgsWindow(),
      ...pgsPalette(),
      ...pgsObject(),
      ...pgsObject(id: 2, data: [0, 0x84, 2, 0, 0, 0, 0x84, 2, 0, 0]),
      ...pgsEnd(),
    ], format: SubtitleFormat.pgs);
    final key = GlobalKey();
    await tester.pumpWidget(overlay(at(d, 1000), boundary: key));
    final (image, data) = await pixels(tester, key);
    // Second half-alpha red object composites over white, then over red/blue.
    expect(rgb(data, 90, 60), [254, 127, 127]);
    expect(rgb(data, 94, 60), [190, 0, 63]);
    image.dispose();
  });
  testWidgets(
    'same-frame rebuild reuses handles; switch/off/unmount releases all',
    (tester) async {
      final created = <ui.Image>[];
      final oldCreate = ui.Image.onCreate;
      ui.Image.onCreate = (i) {
        created.add(i);
        oldCreate?.call(i);
      };
      addTearDown(() => ui.Image.onCreate = oldCreate);
      final d = SubtitleDocument.parse(
        pgsFixture(),
        format: SubtitleFormat.pgs,
      );
      await tester.pumpWidget(overlay(at(d, 1000)));
      await settleDecode(tester);
      expect(created, hasLength(1));
      expect(created.first.debugDisposed, false);
      await tester.pumpWidget(overlay(at(d, 1500), fit: BoxFit.cover));
      await settleDecode(tester);
      expect(created, hasLength(1));
      await tester.pumpWidget(overlay(at(d, 2000)));
      await settleDecode(tester);
      expect(created, hasLength(2));
      expect(created.first.debugDisposed, true);
      expect(created.last.debugDisposed, false);
      await tester.pumpWidget(overlay(at(d, 3000)));
      expect(created.every((i) => i.debugDisposed), true);
      await tester.pumpWidget(overlay(at(d, 1000)));
      await settleDecode(tester);
      expect(created, hasLength(3));
      await tester.pumpWidget(const SizedBox());
      expect(created.every((i) => i.debugDisposed), true);
    },
  );
  testWidgets(
    'public PGS file: first frame/offset/seek/off/source reset release images',
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
        final dir = await Directory.systemTemp.createTemp('pgs-view-');
        addTearDown(() => dir.delete(recursive: true));
        final f = await File(
          '${dir.path}/owned.sup',
        ).writeAsBytes(pgsFixture());
        await session.replaceExternalSubtitles([
          YlExternalSubtitle(
            id: 'pgs',
            format: YlSubtitleFormat.pgs,
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
