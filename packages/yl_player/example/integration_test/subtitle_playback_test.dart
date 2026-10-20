import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_overlay.dart';
import '../../test/support/ass_fixture.dart';
import '../../test/support/pgs_fixture.dart';
import '../../test/support/vobsub_fixture.dart';
import 'support/apple_strict_support.dart';
import 'support/capture_composition.dart';
import 'protected_view_probe_test.dart' as protected_probe;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  protected_probe.main();
  for (final format in YlSubtitleFormat.values) {
    testWidgets('P02 actual ${format.name}: managed load, pixels, clock and lifecycle', (
      tester,
    ) async {
      final dir = await Directory.systemTemp.createTemp('p02-effects-');
      addTearDown(() => dir.delete(recursive: true));
      final video = BytesBuilder();
      for (final name in [
        'init-0.m4s',
        for (var i = 1; i <= 4; i++)
          'chunk-0-${i.toString().padLeft(5, '0')}.m4s',
      ]) {
        final data = await rootBundle.load(
          'assets/test_media/dash_timeline/period0/$name',
        );
        video.add(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      }
      final media = video.takeBytes();
      final file = await File('${dir.path}/owned.mp4').writeAsBytes(media);
      final subtitle = switch (format) {
        YlSubtitleFormat.srt => utf8.encode(
          '1\n00:00:01,000 --> 00:00:03,000\nSUBTITLE\n',
        ),
        YlSubtitleFormat.webvtt => utf8.encode(
          'WEBVTT\n\n00:01.000 --> 00:03.000\nSUBTITLE\n',
        ),
        YlSubtitleFormat.ttml => utf8.encode(
          '<tt xmlns="http://www.w3.org/ns/ttml" xmlns:tts="http://www.w3.org/ns/ttml#styling"><head><layout><region xml:id="bottom" tts:origin="10% 70%" tts:extent="80% 25%" tts:displayAlign="after"/></layout></head><body region="bottom"><div><p begin="1s" end="3s">SUBTITLE</p></div></body></tt>',
        ),
        YlSubtitleFormat.ass || YlSubtitleFormat.ssa => utf8.encode(
          assFixture(
                ssa: format == YlSubtitleFormat.ssa,
                wrap: '0',
                text: 'SUBTITLE',
              )
              .replaceAll('Ahem', 'sans-serif')
              .replaceAll('&H000000FF', '&H00FFFFFF')
              .replaceAll('20,255,255,0,0', '20,16777215,16777215,0,0'),
        ),
        YlSubtitleFormat.pgs => pgsFixture(),
        YlSubtitleFormat.vobsub => vobSub(),
      };
      // Blue third row contrasts with the green 1.5-second video marker.
      final companion = utf8.encode(
        vobIdxText().replaceFirst('ff0000, 00ff00', 'ff0000, 0000ff'),
      );
      final requests = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        requests.add(request.uri.path);
        expect(request.headers.value('x-p02-owned'), 'subtitle');
        final data = request.uri.path == '/pair.idx' ? companion : subtitle;
        request.response.contentLength = data.length;
        request.response.add(data);
        await request.response.close();
      });
      addTearDown(() async {
        await server.close(force: true);
        await subscription.cancel();
      });
      YlNetworkSource resource(String name) => YlNetworkSource(
        Uri.parse('http://127.0.0.1:${server.port}/$name'),
        request: YlHttpRequest(headers: const {'x-p02-owned': 'subtitle'}),
        networkPolicy: strictNetwork,
      );
      final player = await YlPlayerController.create(
        enableTextSubtitles: true,
        options: const YlPlayerOptions(audioPolicy: YlAudioPolicy.appManaged),
      );
      addTearDown(player.dispose);
      final errors = <YlPlaybackFailedEvent>[];
      final events = player.events
          .where((e) => e is YlPlaybackFailedEvent)
          .cast<YlPlaybackFailedEvent>()
          .listen(errors.add);
      addTearDown(events.cancel);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: key,
            child: YlPlayerView(controller: player),
          ),
        ),
      );
      final session = await player.load(YlFileSource(file.path));
      await readyAndPlay(player, session);
      await session.pause();
      await session.replaceExternalSubtitles([
        YlExternalSubtitle(
          id: 'owned',
          source: resource('subtitle'),
          format: format,
          companionSource: format == YlSubtitleFormat.vobsub
              ? resource('pair.idx')
              : null,
        ),
      ]);
      expect(
        requests,
        unorderedEquals(
          format == YlSubtitleFormat.vobsub
              ? ['/subtitle', '/pair.idx']
              : ['/subtitle'],
        ),
      );
      Future<void> settle(bool visible) async {
        final watch = Stopwatch()..start();
        do {
          await tester.pump(const Duration(milliseconds: 30));
          if (find.byType(TextSubtitleOverlay).evaluate().isNotEmpty ==
              visible) {
            return;
          }
        } while (watch.elapsed < const Duration(seconds: 5));
        fail(
          'Cue did not settle: format=${format.name}, visible=$visible, position=${player.state.timeline.position}',
        );
      }

      Future<void> seek(int ms) async {
        await session.seekTo(Duration(milliseconds: ms));
        await stateWhere(
          player,
          (s) => (s.timeline.position.inMilliseconds - ms).abs() < 100,
        );
        await tester.pump(const Duration(milliseconds: 120));
      }

      await seek(1500);
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final viewport = boundary.size;
      final fitted = applyBoxFit(
        BoxFit.contain,
        const Size(320, 180),
        viewport,
      ).destination;
      final aperture = Alignment.center.inscribe(
        fitted,
        Offset.zero & viewport,
      );
      // Native presentation can lag the seek ACK and the Flutter engine frame.
      // Observe the owned green marker before freezing the no-subtitle reference.
      final before = await _captureMarker(tester, key, aperture);
      await session.selectSubtitleTrack('owned');
      await settle(true);
      // Decode completion and raster delivery are separate from cue publication.
      await tester.pump(const Duration(milliseconds: 200));
      final shown = await _capture(key);
      final delta = _difference(before, shown, aperture);
      expect(
        delta.$1,
        greaterThan(12),
        reason: 'The full subtitle area must be painted.',
      );
      final bitmap =
          format == YlSubtitleFormat.pgs || format == YlSubtitleFormat.vobsub;
      if (bitmap) {
        final expected = Rect.fromLTWH(
          aperture.left + aperture.width * .2,
          aperture.top + aperture.height * .3,
          aperture.width * .04,
          aperture.height * (format == YlSubtitleFormat.pgs ? .02 : .03),
        );
        for (final pair in [
          (delta.$2.left, expected.left),
          (delta.$2.top, expected.top),
          (delta.$2.right, expected.right),
          (delta.$2.bottom, expected.bottom),
        ]) {
          expect(pair.$1, closeTo(pair.$2, 3));
        }
      } else {
        expect(delta.$2.top, greaterThan(aperture.center.dy));
        expect(delta.$2.width, greaterThan(20));
        expect(delta.$2.height, greaterThan(4));
      }
      // Exercise the production public view with the same controller/session.
      // The clear protected-view probe above is separate evidence.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(TextSubtitleOverlay), findsNothing);
      expect(player.state.sessionId, session.id);
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: key,
            child: YlPlayerView(controller: player),
          ),
        ),
      );
      await settle(true);
      await tester.pump(const Duration(milliseconds: 200));
      final remountedPixels = await _capture(key);
      final remountedDelta = _difference(shown, remountedPixels, aperture);
      expect(
        remountedDelta.$1,
        lessThan(8),
        reason:
            'Remount must restore the same paused video and subtitle pixels.',
      );
      expect(player.state.sessionId, session.id);
      final paused = player.state.timeline.position;
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        (player.state.timeline.position - paused).abs(),
        lessThan(const Duration(milliseconds: 100)),
      );
      await session.setSubtitleOffset(const Duration(seconds: 1));
      await settle(false);
      await session.setSubtitleOffset(const Duration(milliseconds: -250));
      await settle(true);
      await seek(0);
      await settle(false);
      await seek(1500);
      await settle(true);
      await session.selectSubtitleTrack(null);
      await settle(false);
      final off = await _captureMarker(tester, key, aperture);
      expect(
        _difference(before, off, aperture).$1,
        lessThan(8),
        reason: 'Off must remove the entire subtitle image.',
      );
      await session.setSubtitleOffset(Duration.zero);
      await session.selectSubtitleTrack('owned');
      final sync = <Map<String, num>>[];
      for (final speed in [1.0, 2.0]) {
        await seek(500);
        await settle(false);
        await session.setPlaybackSpeed(speed);
        await session.play();
        final deadline = Stopwatch()..start();
        int? first;
        while (deadline.elapsed < const Duration(seconds: 6)) {
          await tester.pump(const Duration(milliseconds: 20));
          if (find.byType(TextSubtitleOverlay).evaluate().isNotEmpty) {
            first = player.state.timeline.position.inMilliseconds;
            break;
          }
        }
        expect(first, isNotNull);
        expect(first!, inInclusiveRange(1000, 1750));
        sync.add({
          'speed': speed,
          'observedMediaMs': first,
          'lateMs': first - 1000,
        });
        await session.pause();
      }
      expect(errors, isEmpty);
      debugPrint(
        'YL_P02_SUBTITLE ${jsonEncode({
          'format': format.name,
          'platform': Platform.operatingSystem,
          'os': Platform.operatingSystemVersion,
          'mediaSha256': sha256.convert(media).toString(),
          'subtitleSha256': sha256.convert(subtitle).toString(),
          'companionSha256': format == YlSubtitleFormat.vobsub ? sha256.convert(companion).toString() : null,
          'changedPixels': delta.$1,
          'bounds': [delta.$2.left, delta.$2.top, delta.$2.right, delta.$2.bottom],
          'clockObservations': sync,
          'clockEvidence': 'post-engine-frame cue publication against authoritative native timeline; not physical display/audio sync',
          'pixelEvidence': Platform.isAndroid ? 'Flutter texture composition' : 'owned window / simulator / physical-device capture; target recorded by runner',
        })}',
      );
      await player.stop();
      await settle(false);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

Future<_Pixels> _capture(GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final (image, scale, top) = await captureComposition(boundary);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    return _Pixels(image.width, image.height, scale, top, data);
  } finally {
    image.dispose();
  }
}

class _Pixels {
  _Pixels(this.width, this.height, this.scale, this.top, this.data);
  final int width, height;
  final double scale, top;
  final ByteData data;
}

(int, Rect) _difference(_Pixels off, _Pixels on, Rect aperture) {
  expect(on.width, off.width);
  expect(on.height, off.height);
  var count = 0, left = on.width, top = on.height, right = -1, bottom = -1;
  for (
    var y = (on.top + aperture.top * on.scale).ceil();
    y < (on.top + aperture.bottom * on.scale).floor();
    y++
  ) {
    for (
      var x = (aperture.left * on.scale).ceil();
      x < (aperture.right * on.scale).floor();
      x++
    ) {
      final i = (y * on.width + x) * 4;
      if ([0, 1, 2].every(
        (c) => (on.data.getUint8(i + c) - off.data.getUint8(i + c)).abs() < 32,
      )) {
        continue;
      }
      count++;
      if (x < left) left = x;
      if (y < top) top = y;
      if (x > right) right = x;
      if (y > bottom) bottom = y;
    }
  }
  return (
    count,
    count == 0
        ? Rect.zero
        : Rect.fromLTRB(
            left / on.scale,
            (top - on.top) / on.scale,
            (right + 1) / on.scale,
            (bottom + 1 - on.top) / on.scale,
          ),
  );
}

// Check a grid across the actual video aperture, not subtitle widget state.
bool _greenMarker(_Pixels pixels, Rect aperture) {
  for (final fy in [.2, .5, .8]) {
    for (final fx in [.2, .5, .8]) {
      final x = ((aperture.left + aperture.width * fx) * pixels.scale).floor();
      final y =
          (pixels.top + (aperture.top + aperture.height * fy) * pixels.scale)
              .floor();
      final i = (y * pixels.width + x) * 4;
      if (pixels.data.getUint8(i) > 100 ||
          pixels.data.getUint8(i + 1) < 150 ||
          pixels.data.getUint8(i + 2) > 100) {
        return false;
      }
    }
  }
  return true;
}

Future<_Pixels> _captureMarker(
  WidgetTester tester,
  GlobalKey key,
  Rect aperture,
) async {
  final ready = Stopwatch()..start();
  var pixels = await _capture(key);
  while (!_greenMarker(pixels, aperture) &&
      ready.elapsed < const Duration(seconds: 5)) {
    await tester.pump(const Duration(milliseconds: 100));
    pixels = await _capture(key);
  }
  expect(
    _greenMarker(pixels, aperture),
    isTrue,
    reason: 'The actual native video must show the 1.5-second marker.',
  );
  return pixels;
}
