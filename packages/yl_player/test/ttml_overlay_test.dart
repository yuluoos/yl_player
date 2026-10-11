import 'dart:io';
import 'dart:convert';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'package:yl_player/src/subtitles/text_subtitle_overlay.dart';
import 'package:yl_player/yl_player.dart';

void main() {
  testWidgets('two TTML regions flow independently and clip overflowing paragraphs', (
    tester,
  ) async {
    final lines = List.filled(10, 'RED<br/>').join();
    final doc = SubtitleDocument.parse(
      utf8.encode(
        '<tt xmlns="http://www.w3.org/ns/ttml" xmlns:s="http://www.w3.org/ns/ttml#styling">'
        '<head><layout><region xml:id="left" s:origin="5% 10%" s:extent="40% 20%"/>'
        '<region xml:id="right" s:origin="55% 70%" s:extent="40% 20%" s:displayAlign="after"/></layout></head>'
        '<body><div><p begin="0s" end="1s" region="left">$lines</p>'
        '<p begin="0s" end="1s" region="right">GREEN</p></div></body></tt>',
      ),
      format: SubtitleFormat.ttml,
    );
    final cues = [
      for (final cue in doc.cues)
        TextSubtitleCue(
          cue,
          TextSpan(
            text: cue.payload,
            style: TextStyle(
              color: cue.region!.id == 'left'
                  ? const Color(0xffff0000)
                  : const Color(0xff00ff00),
            ),
          ),
        ),
    ];
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 300,
              height: 300,
              child: ColoredBox(
                color: const Color(0xff000000),
                child: TextSubtitleOverlay(
                  cues: cues,
                  geometry: const YlVideoGeometry(
                    encodedSize: YlPixelSize(300, 300),
                    displaySize: YlPixelSize(300, 300),
                  ),
                  fit: BoxFit.contain,
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
    var red = 0, green = 0;
    for (var y = 0; y < 300; y++) {
      for (var x = 0; x < 300; x++) {
        final i = (y * 300 + x) * 4;
        if (bytes.getUint8(i) > 150) {
          red++;
          expect(
            const Rect.fromLTWH(
              15,
              30,
              120,
              60,
            ).contains(Offset(x.toDouble(), y.toDouble())),
            isTrue,
          );
        }
        if (bytes.getUint8(i + 1) > 150) {
          green++;
          expect(
            const Rect.fromLTWH(
              165,
              210,
              120,
              60,
            ).contains(Offset(x.toDouble(), y.toDouble())),
            isTrue,
          );
        }
      }
    }
    expect(red, greaterThan(100));
    expect(green, greaterThan(100));
    image.dispose();
  });

  for (final (name, geometry, aperture) in [
    (
      'contain',
      const YlVideoGeometry(
        encodedSize: YlPixelSize(1920, 1080),
        displaySize: YlPixelSize(1920, 1080),
      ),
      const Rect.fromLTWH(0, 65.625, 300, 168.75),
    ),
    (
      'rotated-par',
      const YlVideoGeometry(
        encodedSize: YlPixelSize(720, 576),
        displaySize: YlPixelSize(720, 576),
        pixelAspectRatio: 16 / 15,
        rotationDegrees: 90,
      ),
      const Rect.fromLTWH(37.5, 0, 225, 300),
    ),
  ]) {
    for (final align in ['before', 'center', 'after']) {
      testWidgets(
        'TTML $name region $align has exact box and clipped red pixels',
        (tester) async {
          final runtime = TextSubtitleRuntime();
          await tester.runAsync(() async {
            final dir = await Directory.systemTemp.createTemp('ttml-pixels-');
            addTearDown(() => dir.delete(recursive: true));
            final file = await File('${dir.path}/owned.ttml').writeAsString(
              '''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:s="http://www.w3.org/ns/ttml#styling">
<head><layout><region xml:id="r" s:origin="10% 60%" s:extent="80% 30%" s:displayAlign="$align"/></layout></head>
<body><div><p begin="0s" end="2s" region="r" s:color="red">OWNED</p></div></body></tt>''',
            );
            await runtime.replace([
              YlExternalSubtitle(
                id: 'tt',
                format: YlSubtitleFormat.ttml,
                source: YlFileSource(file.path),
              ),
            ]);
            runtime.select('tt');
          });
          final boundary = GlobalKey();
          await tester.pumpWidget(
            Directionality(
              textDirection: TextDirection.ltr,
              child: Align(
                alignment: Alignment.topLeft,
                child: RepaintBoundary(
                  key: boundary,
                  child: SizedBox(
                    width: 300,
                    height: 300,
                    child: ColoredBox(
                      color: const Color(0xff000000),
                      child: TextSubtitleOverlay(
                        cues: runtime.cuesAt(const Duration(seconds: 1)),
                        geometry: geometry,
                        fit: BoxFit.contain,
                        alignment: Alignment.center,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          final expected = Rect.fromLTWH(
            aperture.left + aperture.width * .1,
            aperture.top + aperture.height * .6,
            aperture.width * .8,
            aperture.height * .3,
          );
          final rect = tester.getRect(find.text('OWNED', findRichText: true));
          expect(rect.left, closeTo(expected.left, .01));
          expect(rect.width, closeTo(expected.width, .01));
          switch (align) {
            case 'before':
              expect(rect.top, closeTo(expected.top, .01));
            case 'center':
              expect(rect.center.dy, closeTo(expected.center.dy, .01));
            case 'after':
              expect(rect.bottom, closeTo(expected.bottom, .01));
          }
          final image = (await tester.runAsync(
            () =>
                (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage(),
          ))!;
          final rgba = (await tester.runAsync(
            () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
          ))!;
          var red = 0;
          for (var y = 0; y < image.height; y++) {
            for (var x = 0; x < image.width; x++) {
              final offset = (y * image.width + x) * 4;
              if (rgba.getUint8(offset) > 150 &&
                  rgba.getUint8(offset + 1) < 40 &&
                  rgba.getUint8(offset + 2) < 40) {
                red++;
                expect(
                  expected
                      .inflate(1)
                      .contains(Offset(x.toDouble(), y.toDouble())),
                  isTrue,
                );
              }
            }
          }
          expect(red, greaterThan(25));
          final evidence = Platform.environment['YL_TTML_EVIDENCE_DIR'];
          if (evidence != null) {
            final png = (await tester.runAsync(
              () => image.toByteData(format: ui.ImageByteFormat.png),
            ))!;
            await tester.runAsync(
              () => File(
                '$evidence/$name-$align.png',
              ).writeAsBytes(png.buffer.asUint8List()),
            );
          }
          image.dispose();
        },
      );
    }
  }
}
