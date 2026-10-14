import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'package:yl_player/src/subtitles/text_subtitle_overlay.dart';
import 'package:yl_player/yl_player.dart';

void main() {
  for (final alignment in ['start', 'end']) {
    testWidgets('RTL $alignment anchors match text direction', (tester) async {
      final doc = SubtitleDocument.parse(
        utf8.encode(
          'WEBVTT\n\n00:01.000 --> 00:02.000 align:$alignment\ncaption\n',
        ),
        format: SubtitleFormat.webvtt,
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.rtl,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              height: 300,
              child: TextSubtitleOverlay(
                cues: [
                  TextSubtitleCue(
                    doc.cues.single,
                    parseSubtitleText('caption'),
                  ),
                ],
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
      );
      final rect = tester.getRect(find.byType(RichText));
      expect(
        alignment == 'start' ? rect.right : rect.left,
        closeTo(alignment == 'start' ? 285 : 15, .01),
      );
    });
  }
  for (final (name, fit, alignment, geometry, expected) in [
    (
      'video-gap viewport',
      BoxFit.contain,
      Alignment.center,
      null,
      const Rect.fromLTWH(0, 0, 300, 300),
    ),
    (
      'contain',
      BoxFit.contain,
      Alignment.center,
      const YlVideoGeometry(
        encodedSize: YlPixelSize(1920, 1080),
        displaySize: YlPixelSize(1920, 1080),
      ),
      const Rect.fromLTWH(0, 65.625, 300, 168.75),
    ),
    (
      'top-left',
      BoxFit.contain,
      Alignment.topLeft,
      const YlVideoGeometry(
        encodedSize: YlPixelSize(1920, 1080),
        displaySize: YlPixelSize(1920, 1080),
      ),
      const Rect.fromLTWH(0, 0, 300, 168.75),
    ),
    (
      'cover',
      BoxFit.cover,
      Alignment.center,
      const YlVideoGeometry(
        encodedSize: YlPixelSize(1920, 1080),
        displaySize: YlPixelSize(1920, 1080),
      ),
      const Rect.fromLTWH(0, 0, 300, 300),
    ),
    (
      'rotated-par',
      BoxFit.contain,
      Alignment.center,
      const YlVideoGeometry(
        encodedSize: YlPixelSize(720, 576),
        displaySize: YlPixelSize(720, 576),
        pixelAspectRatio: 16 / 15,
        rotationDegrees: 90,
      ),
      const Rect.fromLTWH(37.5, 0, 225, 300),
    ),
  ]) {
    testWidgets('painted pixels and upright text remain in $name aperture', (
      tester,
    ) async {
      final doc = SubtitleDocument.parse(
        utf8.encode(
          'WEBVTT\n\n00:01.000 --> 00:02.000 position:25%,line-left align:left\n<b>owned</b>\n',
        ),
        format: SubtitleFormat.webvtt,
      );
      final cue = TextSubtitleCue(
        doc.cues.single,
        parseSubtitleText(doc.cues.single.payload),
      );
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
                    cues: [cue],
                    geometry: geometry,
                    fit: fit,
                    alignment: alignment,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final textRect = tester.getRect(find.byType(RichText));
      expect(textRect.left, closeTo(expected.left + expected.width * .25, .01));
      expect(
        textRect.bottom,
        closeTo(expected.bottom - expected.height * .05, .01),
      );
      expect(textRect.width, greaterThan(textRect.height));
      final image = (await tester.runAsync(
        () => (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage(),
      ))!;
      final rgba = (await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      var bright = 0;
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          final index = (y * image.width + x) * 4;
          if (rgba.getUint8(index) > 150 && rgba.getUint8(index + 1) > 150) {
            bright++;
            expect(
              expected.contains(Offset(x.toDouble(), y.toDouble())),
              isTrue,
            );
          }
        }
      }
      expect(bright, greaterThan(50));
      // Opt-in local evidence output; normal tests do not change the checkout.
      final evidence = Platform.environment['YL_SUBTITLE_SCREENSHOTS'];
      if (evidence != null) {
        final png = await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.png),
        );
        await tester.runAsync(
          () => File(
            '$evidence/$name.png',
          ).writeAsBytes(png!.buffer.asUint8List()),
        );
      }
      image.dispose();
    });
  }
}
