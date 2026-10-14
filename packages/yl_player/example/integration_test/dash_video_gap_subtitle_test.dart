import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/capture_composition.dart';
import 'support/dash_server.dart';

/// A video-only gap must not erase a cue valid in the programme window.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final (kind, target) in [
    ('leading', 250),
    ('internal', 1500),
    ('trailing', 2500),
  ]) {
    testWidgets('DASH $kind video gap keeps subtitle over actual black output', (
      tester,
    ) async {
      var manifest = await rootBundle.loadString(
        'assets/test_media/dash_timeline/independent-pto.mpd',
      );
      if (kind == 'leading') {
        manifest = manifest.replaceFirst(
          'presentationTimeOffset="122880"',
          'presentationTimeOffset="116736"',
        );
      } else {
        final start = manifest.indexOf('<SegmentTemplate');
        final end =
            manifest.indexOf('</SegmentTemplate>', start) +
            '</SegmentTemplate>'.length;
        final numbers = kind == 'trailing' ? [1, 2] : [1, 3, 4];
        final timeline = numbers
            .map((n) => '<S t="${122880 + (n - 1) * 12288}" d="12288"/>')
            .join();
        final urls = numbers
            .map(
              (n) =>
                  '<SegmentURL media="chunk-0-${n.toString().padLeft(5, '0')}.m4s"/>',
            )
            .join();
        manifest = manifest.replaceRange(
          start,
          end,
          '<SegmentList timescale="12288" presentationTimeOffset="122880"><Initialization sourceURL="init-0.m4s"/><SegmentTimeline>$timeline</SegmentTimeline>$urls</SegmentList>',
        );
      }
      manifest = manifest.replaceFirst(
        '</Period>',
        '<AdaptationSet id="7" contentType="text" mimeType="text/vtt" lang="en"><Representation id="cue"><SegmentTemplate timescale="1" media="gap-cue.vtt"><SegmentTimeline><S t="0" d="4"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period>',
      );
      final server = await DashServer.start(
        timelineMarkers: true,
        manifestOverride: manifest,
        subtitleFiles: {
          '/independent/gap-cue.vtt': utf8.encode(
            'WEBVTT\n\n00:00.000 --> 00:04.000\ncue during video gap\n',
          ),
        },
      );
      addTearDown(server.close);
      final player = await YlPlayerController.create(
        enableTextSubtitles: true,
        options: const YlPlayerOptions(audioPolicy: YlAudioPolicy.appManaged),
      );
      addTearDown(player.dispose);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: key,
            child: YlPlayerView(controller: player),
          ),
        ),
      );
      final session = await player.load(
        YlNetworkSource(
          server.automaticUri,
          format: YlMediaFormat.dash,
          networkPolicy: strictNetwork,
        ),
      );
      await session.ready.timeout(const Duration(seconds: 15));
      await session.discoverEmbeddedSubtitles();
      await session.selectSubtitleTrack(
        player.state.subtitles.tracks.single.id,
      );
      await readyAndPlay(player, session);
      await session.pause();
      await session.seekTo(Duration(milliseconds: target));
      await stateWhere(
        player,
        (s) => (s.timeline.position.inMilliseconds - target).abs() < 50,
      );
      final cue = find.text('cue during video gap', findRichText: true);
      final watch = Stopwatch()..start();
      var rgb = <int>[];
      var whites = 0;
      do {
        await tester.pump(const Duration(milliseconds: 50));
        if (cue.evaluate().length != 1) continue;
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final local = tester
            .getRect(cue)
            .shift(-boundary.localToGlobal(Offset.zero));
        final (image, scale, top) = await captureComposition(boundary);
        try {
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final center =
              (((top + boundary.size.height * scale / 2).floor()) *
                      image.width +
                  image.width ~/ 2) *
              4;
          rgb = [for (var c = 0; c < 3; c++) data.getUint8(center + c)];
          whites = 0;
          for (
            var y = (top + local.top * scale).ceil().clamp(0, image.height);
            y < (top + local.bottom * scale).floor().clamp(0, image.height);
            y++
          ) {
            for (
              var x = (local.left * scale).ceil().clamp(0, image.width);
              x < (local.right * scale).floor().clamp(0, image.width);
              x++
            ) {
              if ([0, 1, 2].every(
                (c) => data.getUint8((y * image.width + x) * 4 + c) > 220,
              )) {
                whites++;
              }
            }
          }
        } finally {
          image.dispose();
        }
        if (rgb.every((v) => v < 32) &&
            whites > 8 &&
            cue.evaluate().length == 1) {
          break;
        }
      } while (watch.elapsed < const Duration(seconds: 4));
      debugPrint(
        'YL_DASH_VIDEO_GAP kind=$kind target=$target clock=${player.state.timeline.position.inMilliseconds} rgb=$rgb glyphPixels=$whites geometry=${player.state.videoGeometry}',
      );
      expect(cue, findsOneWidget);
      expect(rgb.length == 3 && rgb.every((v) => v < 32), isTrue);
      expect(whites, greaterThan(8));
      expect(player.state.failure, isNull);
      await session.selectSubtitleTrack(null);
      await tester.pump();
      expect(cue, findsNothing);
      await player.stop();
    });
  }
}
