import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'package:yl_player/src/subtitles/text_subtitle_overlay.dart';
import 'package:yl_player/src/subtitles/ass_overlay.dart';
import 'package:yl_player/yl_player.dart';
import 'support/ass_fixture.dart';
import 'support/fake_player_platform.dart';

List<TextSubtitleCue> at(String script, int elapsed) {
  final d = SubtitleDocument.parse(
    utf8.encode(script),
    format: SubtitleFormat.ass,
  );
  return [
    for (final c in d.cuesAt(Duration(milliseconds: 1000 + elapsed)))
      TextSubtitleCue(
        c,
        TextSpan(text: c.ass!.runs.map((r) => r.text).join()),
        elapsed: Duration(milliseconds: elapsed),
      ),
  ];
}

const geometry = YlVideoGeometry(
  encodedSize: YlPixelSize(300, 200),
  displaySize: YlPixelSize(300, 200),
);
Future<(ui.Image, ByteData)> render(
  WidgetTester tester,
  List<TextSubtitleCue> cues, {
  YlVideoGeometry g = geometry,
  BoxFit fit = BoxFit.contain,
  GlobalKey? repaintKey,
}) async {
  final key = repaintKey ?? GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: key,
          child: SizedBox(
            width: 300,
            height: 200,
            child: ColoredBox(
              color: const Color(0xff000000),
              child: TextSubtitleOverlay(
                cues: cues,
                geometry: g,
                fit: fit,
                alignment: Alignment.center,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  final image = (await tester.runAsync(
    () => (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
        .toImage(),
  ))!;
  final bytes = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  return (image, bytes);
}

Rect bounds(ByteData data, bool Function(int, int, int) match) {
  var l = 300, t = 200, r = -1, b = -1;
  for (var y = 0; y < 200; y++) {
    for (var x = 0; x < 300; x++) {
      final i = (y * 300 + x) * 4;
      if (match(data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2))) {
        if (x < l) l = x;
        if (x > r) r = x;
        if (y < t) t = y;
        if (y > b) b = y;
      }
    }
  }
  return r < 0
      ? Rect.zero
      : Rect.fromLTRB(l.toDouble(), t.toDouble(), r + 1.0, b + 1.0);
}

void boxNear(Rect actual, Rect expected, {double tolerance = 1}) {
  expect(actual, isNot(Rect.zero));
  for (final (a, e) in [
    (actual.left, expected.left),
    (actual.top, expected.top),
    (actual.right, expected.right),
    (actual.bottom, expected.bottom),
  ]) {
    expect(a, closeTo(e, tolerance));
  }
}

void main() {
  testWidgets(
    'smart wrap charges failed single-grapheme probes to its budget',
    (tester) async {
      var shapes = 0;
      debugAssWrapMeasurement = () => shapes++;
      addTearDown(() => debugAssWrapMeasurement = null);
      // 512 style runs, each containing an indivisible Ahem glyph. A two-pixel
      // script aperture forces one glyph per line; every larger glyph offers an
      // impossible downward move. Failed probes must still consume work budget.
      final text = List.filled(256, r'{\fs40}A{\fs20}A').join();
      final script = assFixture(
        wrap: '3',
        text: text,
      ).replaceFirst('Default,,0,0,0,,', 'Default,,149,149,0,,');
      final cues = at(script, 0);
      final key = GlobalKey();
      final (first, bytes) = await render(tester, cues, repaintKey: key);
      addTearDown(first.dispose);
      expect(
        shapes,
        greaterThan(1),
        reason: 'The failed probe path must execute.',
      );
      expect(
        shapes,
        lessThanOrEqualTo(129),
        reason: 'One initial paragraph plus at most 128 local measurements.',
      );
      final measured = shapes;
      final (second, again) = await render(tester, cues, repaintKey: key);
      addTearDown(second.dispose);
      expect(
        shapes,
        measured,
        reason: 'Active-cue rebuild must reuse prepared runs.',
      );
      expect(again.buffer.asUint8List(), bytes.buffer.asUint8List());
    },
  );

  testWidgets(
    'font availability change repaints paused ASS and detaches on unmount',
    (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [
              AssSubtitleOverlay(
                cues: at(
                  assFixture(wrap: '0', text: 'AA AA AA AA AA AA AA'),
                  0,
                ),
              ),
            ],
          ),
        ),
      );
      var pictures = 0;
      final previous = ui.Picture.onCreate;
      ui.Picture.onCreate = (picture) {
        pictures++;
        previous?.call(picture);
      };
      addTearDown(() => ui.Picture.onCreate = previous);
      await tester.binding.handleSystemMessage({'type': 'fontsChange'});
      await tester.pump();
      expect(
        pictures,
        greaterThan(0),
        reason:
            'Paused cues must remeasure and repaint when fallback fonts change.',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.binding.handleSystemMessage({'type': 'fontsChange'});
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'smart wrap maximum admitted text remains bounded across rebuilds',
    (tester) async {
      final text = List.filled(4096, 'a b ').join();
      final cues = at(assFixture(wrap: '3', text: text), 0);
      final (first, bytes) = await render(tester, cues);
      expect(bounds(bytes, (r, g, b) => r > 100), isNot(Rect.zero));
      final (second, again) = await render(tester, cues);
      expect(again.buffer.asUint8List(), bytes.buffer.asUint8List());
      first.dispose();
      second.dispose();
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('smart lower-wide wrap never breaks ASS nonbreaking spaces', (
    tester,
  ) async {
    final (reference, expected) = await render(
      tester,
      at(assFixture(wrap: '2', text: r'AA\hBB\NAA\hBB AA\hBB'), 0),
    );
    final (actual, bytes) = await render(
      tester,
      at(assFixture(wrap: '3', text: r'AA\hBB AA\hBB AA\hBB'), 0),
    );
    expect(bytes.buffer.asUint8List(), expected.buffer.asUint8List());
    reference.dispose();
    actual.dispose();
  });

  for (final wrap in ['0', '3']) {
    testWidgets('smart wrap $wrap retains styles and hard paragraph breaks', (
      tester,
    ) async {
      final hard = wrap == '0'
          ? r'AA AA AA AA\NAA AA AA'
          : r'AA AA AA\NAA AA AA AA';
      final (reference, expected) = await render(
        tester,
        at(
          assFixture(
            wrap: '2',
            text: '{\\1c&H00FF00&}$hard\\N{\\1c&H0000FF&}$hard',
          ),
          0,
        ),
      );
      final (actual, bytes) = await render(
        tester,
        at(
          assFixture(
            wrap: wrap,
            text:
                r'{\1c&H00FF00&}AA AA AA AA AA AA AA\N{\1c&H0000FF&}AA AA AA AA AA AA AA',
          ),
          0,
        ),
      );
      expect(bytes.buffer.asUint8List(), expected.buffer.asUint8List());
      reference.dispose();
      actual.dispose();
    });
    testWidgets('smart wrap $wrap preserves CJK glyph order', (tester) async {
      final hard = wrap == '0'
          ? r'一二三四五六七八九十\N甲乙丙丁戊己庚辛壬'
          : r'一二三四五六七八九\N十甲乙丙丁戊己庚辛壬';
      final (reference, expected) = await render(
        tester,
        at(assFixture(wrap: '2', text: hard), 0),
      );
      final (actual, bytes) = await render(
        tester,
        at(assFixture(wrap: wrap, text: '一二三四五六七八九十甲乙丙丁戊己庚辛壬'), 0),
      );
      expect(bytes.buffer.asUint8List(), expected.buffer.asUint8List());
      reference.dispose();
      actual.dispose();
    });
  }

  for (final (wrap, expected) in [
    ('0', r'AA AA AA AA\NAA AA AA'),
    ('3', r'AA AA AA\NAA AA AA AA'),
  ]) {
    testWidgets(
      'smart wrap $wrap matches independently specified balanced lines',
      (tester) async {
        final (reference, expectedBytes) = await render(
          tester,
          at(assFixture(wrap: '2', text: expected), 0),
        );
        final (actual, actualBytes) = await render(
          tester,
          at(assFixture(wrap: wrap, text: 'AA AA AA AA AA AA AA'), 0),
        );
        expect(
          actualBytes.buffer.asUint8List(),
          expectedBytes.buffer.asUint8List(),
        );
        reference.dispose();
        actual.dispose();
      },
    );
  }

  for (final ms in [0, 1000, 1750]) {
    testWidgets('ASS media-time move/fade outlined box at $ms ms', (
      tester,
    ) async {
      final script = assFixture(
        text: r'{\an7\move(50,80,150,80)\fad(0,500)\3c&H00FF00&}AB',
      );
      final (im, data) = await render(tester, at(script, ms));
      final x = 50 + ms / 20;
      boxNear(
        bounds(data, (r, g, b) => r > 100 && g < 5),
        Rect.fromLTWH(x, 80, 40, 20),
      );
      boxNear(
        bounds(data, (r, g, b) => g > 100 && r < 5),
        Rect.fromLTWH(x - 2, 78, 44, 24),
      );
      final expected = ms == 1750 ? 128 : 255;
      final i = (90 * 300 + (x + 10).round()) * 4;
      expect(data.getUint8(i), closeTo(expected, 1));
      final output = Platform.environment['YL_ASS_EVIDENCE_DIR'];
      if (output != null) {
        await tester.runAsync(() async {
          final png = await im.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$output/move-$ms.png',
          ).writeAsBytes(png!.buffer.asUint8List());
        });
      }
      im.dispose();
    });
  }
  testWidgets('layer paints higher cue on top, file order breaks ties', (
    tester,
  ) async {
    final script = assFixture(
      text: r'{\an7\pos(50,80)\bord0}AB',
      extra:
          r'Dialogue: 2,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\an7\pos(50,80)\bord0\c&HFF0000&}AB',
    );
    final (im, data) = await render(tester, at(script, 1000));
    expect(bounds(data, (r, g, b) => r > 100), Rect.zero);
    boxNear(
      bounds(data, (r, g, b) => b > 200),
      const Rect.fromLTWH(50, 80, 40, 20),
    );
    im.dispose();
  });
  testWidgets('unpositioned overlapping events stack without overlap', (
    tester,
  ) async {
    final script = assFixture(
      text: r'{\bord0}AB',
      extra:
          r'Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\bord0\c&HFF0000&}AB',
    );
    final (im, data) = await render(tester, at(script, 1000));
    boxNear(
      bounds(data, (r, g, b) => r > 200),
      const Rect.fromLTWH(130, 170, 40, 20),
    );
    boxNear(
      bounds(data, (r, g, b) => b > 200),
      const Rect.fromLTWH(130, 150, 40, 20),
    );
    im.dispose();
  });
  for (final (name, g, expected) in [
    (
      'contain',
      const YlVideoGeometry(
        encodedSize: YlPixelSize(300, 300),
        displaySize: YlPixelSize(300, 300),
      ),
      const Rect.fromLTWH(50, 0, 200, 200),
    ),
    (
      'rotate-par',
      const YlVideoGeometry(
        encodedSize: YlPixelSize(200, 100),
        displaySize: YlPixelSize(200, 100),
        rotationDegrees: 90,
        pixelAspectRatio: 1.5,
      ),
      const Rect.fromLTWH(116.6667, 0, 66.6667, 200),
    ),
  ]) {
    testWidgets('ASS $name scales and clips to aperture', (tester) async {
      final script = assFixture(text: r'{\an7\pos(0,0)\bord0}AB');
      final (im, data) = await render(tester, at(script, 1000), g: g);
      boxNear(
        bounds(data, (r, g, b) => r > 100),
        Rect.fromLTWH(expected.left, 0, 40 * expected.width / 300, 20),
      );
      im.dispose();
    });
  }
  testWidgets('unknown font falls back and remains in clipped aperture', (
    tester,
  ) async {
    final script = assFixture(
      text: r'{\fnDefinitelyMissingOwnedFont\an7\pos(-10,180)\bord0}AB',
    );
    final (im, data) = await render(tester, at(script, 1000));
    final b = bounds(data, (r, g, b) => r > 100);
    expect(b, isNot(Rect.zero));
    expect(b.left, 0);
    expect(b.bottom, lessThanOrEqualTo(200));
    im.dispose();
  });

  for (var anchor = 1; anchor <= 9; anchor++) {
    testWidgets('ASS anchor $anchor matches manually derived box', (
      tester,
    ) async {
      final script = assFixture(text: '{\\an$anchor\\pos(150,100)\\bord0}AB');
      final (im, data) = await render(tester, at(script, 1000));
      final column = (anchor - 1) % 3, row = (anchor - 1) ~/ 3;
      boxNear(
        bounds(data, (r, g, b) => r > 200),
        Rect.fromLTWH(150 - column * 20, 80 + row * 10, 40, 20),
      );
      im.dispose();
    });
  }
  testWidgets('ASS colored shadow extends beyond fill and outline', (
    tester,
  ) async {
    final script = assFixture(
      text: r'{\an7\pos(50,80)\bord2\shad5\3c&H00FF00&\4c&HFF0000&}AB',
    );
    final (im, data) = await render(tester, at(script, 1000));
    boxNear(
      bounds(data, (r, g, b) => b > 200 && r < 5 && g < 5),
      const Rect.fromLTRB(53, 83, 97, 107),
    );
    boxNear(
      bounds(data, (r, g, b) => r > 200 && g < 5),
      const Rect.fromLTWH(50, 80, 40, 20),
    );
    im.dispose();
  });
  testWidgets(
    'public ASS first-frame, pause/offset, seek, off and source reset',
    (tester) async {
      final backend = FakePlatformPlayer();
      final player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
        enableTextSubtitles: true,
      );
      addTearDown(player.dispose);
      final pending = player.load(const YlFileSource('/owned.mp4'));
      const sid = YlPlaybackSessionId('ass');
      backend.commit(sid);
      final session = await pending;
      await tester.runAsync(() async {
        final d = await Directory.systemTemp.createTemp('ass-public-');
        addTearDown(() => d.delete(recursive: true));
        final f = await File('${d.path}/owned.ass').writeAsString(assFixture());
        await session.replaceExternalSubtitles([
          YlExternalSubtitle(
            id: 'ass',
            format: YlSubtitleFormat.ass,
            source: YlFileSource(f.path),
          ),
        ]);
      });
      await session.selectSubtitleTrack('ass');
      void position(int ms, {bool paused = false}) => backend.emitState(
        backend.state.copyWith(
          revision: backend.state.revision + 1,
          status: paused ? YlPlaybackStatus.paused : YlPlaybackStatus.playing,
          timeline: YlTimeline(position: Duration(milliseconds: ms)),
          videoGeometry: geometry,
        ),
      );
      position(1600);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 300,
            height: 200,
            child: YlPlayerView(controller: player),
          ),
        ),
      );
      expect(find.byType(AssSubtitleOverlay), findsNothing);
      backend.emitFirstFrame(sid);
      position(1600);
      await tester.pump();
      expect(find.byType(AssSubtitleOverlay), findsOneWidget);
      position(1600, paused: true);
      await tester.pump(const Duration(seconds: 10));
      expect(
        tester
            .widget<AssSubtitleOverlay>(find.byType(AssSubtitleOverlay))
            .cues
            .single
            .elapsed,
        const Duration(milliseconds: 600),
      );
      await session.setSubtitleOffset(const Duration(milliseconds: 500));
      await tester.pump();
      expect(
        tester
            .widget<AssSubtitleOverlay>(find.byType(AssSubtitleOverlay))
            .cues
            .single
            .elapsed,
        const Duration(milliseconds: 100),
      );
      await session.seekTo(Duration.zero);
      await tester.pump();
      expect(find.byType(AssSubtitleOverlay), findsNothing);
      position(1600);
      await tester.pump();
      expect(find.byType(AssSubtitleOverlay), findsOneWidget);
      await session.selectSubtitleTrack(null);
      await tester.pump();
      expect(find.byType(AssSubtitleOverlay), findsNothing);
      await session.selectSubtitleTrack('ass');
      await tester.pump();
      expect(find.byType(AssSubtitleOverlay), findsOneWidget);
      final next = player.load(const YlFileSource('/next.mp4'));
      backend.commit(const YlPlaybackSessionId('next'));
      await next;
      await tester.pump();
      expect(find.byType(AssSubtitleOverlay), findsNothing);
    },
  );
}
