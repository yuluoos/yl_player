import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';
import '../../test/support/fmp4_fixture.dart' as mp4;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final format in ['vtt', 'ttml', 'wvtt', 'stpp']) {
    testWidgets('managed DASH $format cue across Period gap, seek and off', (
      tester,
    ) async {
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
      final initialization = fragmented ? ' initialization="sub-init.mp4"' : '';
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
      await tester.pumpWidget(
        MaterialApp(home: YlPlayerView(controller: player)),
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
    });
  }
}
