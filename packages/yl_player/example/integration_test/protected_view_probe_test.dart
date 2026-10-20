import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'package:yl_player/src/subtitles/text_subtitle_overlay.dart';
import 'package:yl_player/yl_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const channel = MethodChannel('yl_player_example/protected_probe');
const viewType = 'yl_player_example/protected_probe_view';
Widget nativeView(int id) {
  final args = <String, Object>{'id': id};
  if (Platform.isMacOS) {
    return AppKitView(
      viewType: viewType,
      creationParams: args,
      creationParamsCodec: const StandardMessageCodec(),
    );
  }
  if (Platform.isIOS) {
    return UiKitView(
      viewType: viewType,
      creationParams: args,
      creationParamsCodec: const StandardMessageCodec(),
    );
  }
  return PlatformViewLink(
    viewType: viewType,
    surfaceFactory: (context, controller) => AndroidViewSurface(
      controller: controller as AndroidViewController,
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
    ),
    onCreatePlatformView: (params) =>
        PlatformViewsService.initExpensiveAndroidView(
            id: params.id,
            viewType: viewType,
            layoutDirection: TextDirection.ltr,
            creationParams: args,
            creationParamsCodec: const StandardMessageCodec(),
            onFocus: () => params.onFocusChanged(true),
          )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create(),
  );
}

Future<Map<Object?, Object?>> snapshot(int id) async =>
    (await channel.invokeMapMethod<Object?, Object?>('snapshot', {'id': id}))!;
Future<Map<Object?, Object?>> waitFor(
  WidgetTester tester,
  int id,
  bool Function(Map<Object?, Object?>) predicate,
) async {
  final end = DateTime.now().add(const Duration(seconds: 15));
  var state = <Object?, Object?>{};
  do {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    state = await snapshot(id);
    if (predicate(state)) return state;
  } while (DateTime.now().isBefore(end));
  fail('Prototype did not converge: $state');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'clear native prototype isolates players, resize, remount, replacement and release',
    (tester) async {
      debugPrint('P02 probe: fixture');
      final directory = await Directory.systemTemp.createTemp('yl-clear-view-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/clear.mp4');
      final sink = file.openWrite();
      for (final name in [
        'init-0.m4s',
        for (var i = 1; i <= 4; i++)
          'chunk-0-${i.toString().padLeft(5, '0')}.m4s',
      ]) {
        final data = await rootBundle.load(
          'assets/test_media/dash_timeline/period0/$name',
        );
        sink.add(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      }
      await sink.close();
      // Clear AVC bytes: a secure view request is not proof of DRM security.
      for (final id in [71, 72]) {
        await channel.invokeMethod<void>('create', {
          'id': id,
          'path': file.path,
        });
      }
      addTearDown(() async {
        await channel.invokeMethod<void>('reset');
      });
      final document = SubtitleDocument.parse(
        utf8.encode('1\n00:00:00,000 --> 00:00:30,000\nSUBTITLE OVERLAY\n'),
        format: SubtitleFormat.srt,
      );
      final cue = document.cues.single;
      final overlayKeys = [GlobalKey(), GlobalKey()];
      var showSubtitles = true;
      var mountFirst = true;
      Widget composed(int id, int index) => Stack(
        fit: StackFit.expand,
        children: [
          nativeView(id),
          // Capture only this clear subtitle layer; never the native video surface.
          if (showSubtitles)
            RepaintBoundary(
              key: overlayKeys[index],
              child: TextSubtitleOverlay(
                cues: [
                  TextSubtitleCue(
                    cue,
                    const TextSpan(text: 'SUBTITLE OVERLAY'),
                  ),
                ],
                geometry: const YlVideoGeometry(
                  encodedSize: YlPixelSize(320, 180),
                  displaySize: YlPixelSize(320, 180),
                ),
                fit: BoxFit.contain,
                alignment: Alignment.center,
              ),
            ),
        ],
      );
      Future<void> checkSubtitlePaint(
        int index,
        double width,
        double height,
      ) async {
        final boundary =
            overlayKeys[index].currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final image = await boundary
            .toImage(pixelRatio: 1)
            .timeout(const Duration(seconds: 5));
        try {
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final apertureHeight = width * 9 / 16;
          final top = (height - apertureHeight) / 2;
          var opaque = 0;
          var white = 0;
          for (var y = 0; y < image.height; y++) {
            for (var x = 0; x < image.width; x++) {
              final i = (y * image.width + x) * 4;
              if (data.getUint8(i + 3) == 0) continue;
              opaque++;
              expect(y, greaterThanOrEqualTo(top.floor()));
              expect(y, lessThan((top + apertureHeight).ceil()));
              if (data.getUint8(i) > 200 &&
                  data.getUint8(i + 1) > 200 &&
                  data.getUint8(i + 2) > 200) {
                white++;
              }
            }
          }
          expect(opaque, greaterThan(100));
          expect(white, greaterThan(30));
        } finally {
          image.dispose();
        }
      }

      Widget layout(double width, double height) => MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(
                key: const ValueKey('one'),
                width: width,
                height: height,
                child: mountFirst ? composed(71, 0) : const SizedBox.shrink(),
              ),
              SizedBox(
                key: const ValueKey('two'),
                width: 160,
                height: 90,
                child: composed(72, 1),
              ),
              const Text('Subtitle placement reference'),
            ],
          ),
        ),
      );
      debugPrint('P02 probe: mount');
      await tester.pumpWidget(layout(240, 135));
      debugPrint('P02 probe: wait frame');
      final one = await waitFor(
        tester,
        71,
        (s) => s['readyEpoch'] == 1 && (s['positionMs'] as num) > 100,
      );
      final two = await waitFor(tester, 72, (s) => s['readyEpoch'] == 1);
      expect(one['id'], 71);
      expect(two['id'], 72);
      expect(one['pixelReadback'], false);
      expect(one['protectionVerified'], false);
      expect(one['width'], closeTo(240, 1));
      expect(one['height'], closeTo(135, 1));
      if (Platform.isAndroid) expect(one['secureRequested'], true);
      debugPrint('P02 probe: subtitle paint');
      await checkSubtitlePaint(0, 240, 135);
      debugPrint('P02 probe: first paint done');
      await checkSubtitlePaint(1, 160, 90);
      await tester.pumpWidget(layout(180, 220));
      await waitFor(
        tester,
        71,
        (s) =>
            ((s['width'] as num) - 180).abs() <= 1 &&
            ((s['height'] as num) - 220).abs() <= 1,
      );
      await checkSubtitlePaint(0, 180, 220);
      await checkSubtitlePaint(1, 160, 90);
      showSubtitles = false;
      await tester.pumpWidget(layout(180, 220));
      expect(find.byType(TextSubtitleOverlay), findsNothing);
      expect((await snapshot(72))['readyEpoch'], 1);
      showSubtitles = true;
      await tester.pumpWidget(layout(180, 220));
      await checkSubtitlePaint(0, 180, 220);
      // Retain both native owners and remove only the first surface. A reset
      // or replacement here would hide bugs in same-player reattachment.
      final beforeDetach = await snapshot(71);
      mountFirst = false;
      await tester.pumpWidget(layout(180, 220));
      await waitFor(tester, 71, (s) => s['attached'] == false);
      expect(overlayKeys[0].currentContext, isNull);
      expect((await snapshot(71))['epoch'], beforeDetach['epoch']);
      expect((await snapshot(72))['attached'], true);
      await checkSubtitlePaint(1, 160, 90);
      mountFirst = true;
      await tester.pumpWidget(layout(180, 220));
      final remounted = await waitFor(
        tester,
        71,
        (s) =>
            s['attached'] == true &&
            s['readyEpoch'] == 1 &&
            (s['positionMs'] as num) > (beforeDetach['positionMs'] as num),
      );
      expect(remounted['epoch'], 1);
      expect(remounted['width'], closeTo(180, 1));
      expect(remounted['height'], closeTo(220, 1));
      await checkSubtitlePaint(0, 180, 220);
      expect((await snapshot(72))['epoch'], 1);
      debugPrint(
        'YL_P02_REMOUNT ${jsonEncode({'platform': Platform.operatingSystem, 'before': beforeDetach, 'after': remounted, 'evidence': 'clear native probe and separate subtitle pixels; not DRM'})}',
      );
      await channel.invokeMethod<void>('replace', {
        'id': 71,
        'path': file.path,
      });
      final replaced = await waitFor(
        tester,
        71,
        (s) => s['readyEpoch'] == 2 && (s['positionMs'] as num) > 100,
      );
      expect(replaced['epoch'], 2);
      await checkSubtitlePaint(0, 180, 220);
      expect((await snapshot(72))['epoch'], 1);
      await channel.invokeMethod<void>('dispose', {'id': 71});
      await expectLater(
        snapshot(71),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'probe.missing',
          ),
        ),
      );
      expect((await snapshot(72))['readyEpoch'], 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      await channel.invokeMethod<void>('reset');
      expect(await channel.invokeMethod<int>('count'), 0);
    },
  );
}
