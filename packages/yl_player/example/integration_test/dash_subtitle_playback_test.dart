import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';
import 'support/capture_composition.dart';
import '../../test/support/fmp4_fixture.dart' as mp4;

void main() => runDashSubtitlePlaybackTests();

void runDashSubtitlePlaybackTests({bool verifyPixels = false}) {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final format in ['vtt', 'ttml', 'wvtt', 'stpp']) {
    testWidgets(
      'managed DASH $format ${verifyPixels ? 'actual pixels ' : ''}cue across Period gap, seek and off',
      (tester) async {
        final original = await rootBundle.loadString(
          'assets/test_media/dash_timeline/gap.mpd',
        );
        final fragmented = format == 'wvtt' || format == 'stpp';
        final mime = fragmented
            ? 'application/mp4'
            : format == 'vtt'
            ? 'text/vtt'
            : 'application/ttml+xml';
        final codec = fragmented ? ' codecs="$format"' : '';
        final initialization = fragmented
            ? ' initialization="sub-init.mp4"'
            : '';
        final init = fragmented
            ? mp4.fragmented(
                tracks: [
                  mp4.Mp4Track(
                    entry: format == 'wvtt' ? mp4.wvttEntry() : mp4.stppEntry(),
                    samples: [],
                    durations: [],
                  ),
                ],
                fragments: [],
              )
            : <int>[];
        final manifest = original.replaceAll(
          '</Period>',
          '<AdaptationSet id="7" contentType="text" mimeType="$mime"$codec lang="en"><Representation id="sub"><SegmentTemplate timescale="1" presentationTimeOffset="10"$initialization media="sub-\$Time\$.$format"><SegmentTimeline><S t="10" d="2" r="1"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period>',
        );
        final files = <String, List<int>>{};
        for (final period in [0, 1]) {
          if (fragmented) files['/period$period/sub-init.mp4'] = init;
          for (final t in [10, 12]) {
            final label = 'P$period T$t';
            files['/period$period/sub-$t.$format'] = fragmented
                ? mp4.Fragment(
                    tracks: [
                      mp4.FragmentTrack(
                        time: t * 1000,
                        durations: [2000],
                        samples: [
                          format == 'wvtt'
                              ? mp4.vttCue(label)
                              : mp4.stppSample(
                                  '<p begin="${t}s" end="${t + 2}s">$label</p>',
                                ),
                        ],
                      ),
                    ],
                  ).build(init.length)
                : utf8.encode(
                    format == 'vtt'
                        ? 'WEBVTT\n\n00:00:$t.000 --> 00:00:${t + 2}.000\n$label\n'
                        : '<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="${t}s" end="${t + 2}s">$label</p></div></body></tt>',
                  );
          }
        }
        final server = await DashServer.start(
          timelineMarkers: true,
          manifestOverride: manifest,
          subtitleFiles: files,
        );
        addTearDown(server.close);
        final player = await YlPlayerController.create(
          enableTextSubtitles: true,
          options: const YlPlayerOptions(audioPolicy: YlAudioPolicy.appManaged),
        );
        addTearDown(player.dispose);
        final outputKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: outputKey,
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
        final track = player.state.subtitles.tracks.single.id;
        await session.selectSubtitleTrack(track);
        await readyAndPlay(player, session);
        await session.pause();
        Future<void> observe(int ms, String? label) async {
          await session.seekTo(Duration(milliseconds: ms));
          await stateWhere(
            player,
            (s) => (s.timeline.position.inMilliseconds - ms).abs() < 80,
          );
          final deadline = DateTime.now().add(const Duration(seconds: 4));
          do {
            await tester.pump(const Duration(milliseconds: 50));
            if (label == null
                ? find.text('P0 T12', findRichText: true).evaluate().isEmpty
                : find.text(label, findRichText: true).evaluate().length == 1) {
              break;
            }
          } while (DateTime.now().isBefore(deadline));
          if (label == null) {
            expect(find.text('P0 T12', findRichText: true), findsNothing);
          } else {
            expect(
              find.text(label, findRichText: true),
              findsOneWidget,
              reason:
                  'status=${player.state.status} position=${player.state.timeline.position.inMilliseconds} frame=${player.isCurrentFramePresented} texture=${player.textureId.value} geometry=${player.state.videoGeometry}',
            );
          }
          if (verifyPixels) {
            // Capture the actual video + Flutter cue composition. Apple needs a
            // full window capture because its video is a hybrid native view.
            final expected = switch (ms) {
              500 => [255, 0, 0],
              2500 => [0, 0, 255],
              4500 => [0, 0, 0],
              5500 => [255, 255, 0],
              7500 => [255, 0, 255],
              _ => throw StateError('No owned pixel reference for $ms'),
            };
            final capture = Stopwatch()..start();
            var rgb = <int>[];
            var glyphPixels = 0;
            do {
              await tester.pump(const Duration(milliseconds: 50));
              final boundary =
                  outputKey.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              // A seek can reset output geometry after the cue data arrives.
              // Sample the layout before awaiting capture, and require the cue
              // to remain present afterward; the bounded loop still fails if
              // the rendered cue never returns.
              final cue = label == null
                  ? null
                  : find.text(label, findRichText: true);
              final local = cue != null && cue.evaluate().length == 1
                  ? tester
                        .getRect(cue)
                        .shift(-boundary.localToGlobal(Offset.zero))
                  : null;
              final (image, scale, top) = await captureComposition(boundary);
              try {
                final bytes = (await image.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                ))!;
                final offset =
                    (((top + boundary.size.height * scale / 2).floor()) *
                            image.width +
                        image.width ~/ 2) *
                    4;
                rgb = [for (var c = 0; c < 3; c++) bytes.getUint8(offset + c)];
                glyphPixels = 0;
                if (local != null && cue!.evaluate().length == 1) {
                  final rect = Rect.fromLTRB(
                    local.left * scale,
                    top + local.top * scale,
                    local.right * scale,
                    top + local.bottom * scale,
                  );
                  for (
                    var y = rect.top.ceil().clamp(0, image.height);
                    y < rect.bottom.floor().clamp(0, image.height);
                    y++
                  ) {
                    for (
                      var x = rect.left.ceil().clamp(0, image.width);
                      x < rect.right.floor().clamp(0, image.width);
                      x++
                    ) {
                      final index = (y * image.width + x) * 4;
                      if ([
                        0,
                        1,
                        2,
                      ].every((c) => bytes.getUint8(index + c) > 220)) {
                        glyphPixels++;
                      }
                    }
                  }
                }
              } finally {
                image.dispose();
              }
              if (_colorMatches(rgb, expected) &&
                  (label == null || glyphPixels > 8)) {
                break;
              }
            } while (capture.elapsed < const Duration(seconds: 4));
            debugPrint(
              'YL_DASH_CUE_PIXEL format=$format requestedMs=$ms clockMs=${player.state.timeline.position.inMilliseconds} rgb=$rgb glyphPixels=$glyphPixels captureMs=${capture.elapsedMilliseconds}',
            );
            expect(
              _colorMatches(rgb, expected),
              isTrue,
              reason:
                  'Actual texture pixel $rgb must match owned reference $expected at $ms',
            );
            if (label != null) expect(glyphPixels, greaterThan(8));
          }
          expect(player.state.subtitles.selectedTrackId, track);
          expect(player.state.failure, isNull);
        }

        await observe(500, 'P0 T10');
        await observe(2500, 'P0 T12');
        await observe(4500, null);
        await observe(5500, 'P1 T10');
        await observe(7500, 'P1 T12');
        await session.selectSubtitleTrack(null);
        await tester.pump();
        expect(find.text('P1 T12', findRichText: true), findsNothing);
        await player.stop();
      },
    );
  }
}

// These owned AVC markers have no CICP declaration. Platform colour management
// may differ from ffmpeg's default YUV matrix. Classify the six disjoint solid
// markers with wide margins, preserving measured RGB; this measures timeline
// identity and composition, not colourimetric accuracy.
bool _colorMatches(List<int> actual, List<int> expected) =>
    actual.length == 3 &&
    List.generate(
      3,
      (i) => expected[i] == 0 ? actual[i] < 96 : actual[i] > 192,
    ).every((v) => v);
