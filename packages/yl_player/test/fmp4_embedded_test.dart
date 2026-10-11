import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/fmp4_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'actual fragmented MP4 discovers selects and renders WebVTT and TTML across fragments',
    () async {
      final dir = await Directory.systemTemp.createTemp('fmp4-owned-');
      addTearDown(() => dir.delete(recursive: true));
      final file = await File('${dir.path}/movie.mp4').writeAsBytes(
        fragmented(
          tracks: [
            Mp4Track(id: 7, entry: wvttEntry(), samples: [], durations: []),
            Mp4Track(
              id: 9,
              entry: stppEntry(),
              handler: 'subt',
              samples: [],
              durations: [],
            ),
          ],
          fragments: [
            Fragment(
              tracks: [
                FragmentTrack(
                  id: 7,
                  time: 1000,
                  samples: [vttCue('<b>one</b>')],
                ),
              ],
            ),
            Fragment(
              sequence: 2,
              tracks: [
                FragmentTrack(
                  id: 9,
                  time: 1000,
                  samples: [
                    stppSample(
                      '<p begin="1.25s" end="3s" tts:fontStyle="italic">two &amp; 三</p>',
                    ),
                  ],
                ),
              ],
            ),
            Fragment(
              sequence: 3,
              tracks: [
                FragmentTrack(id: 7, time: 2000, samples: [vttCue('next')]),
              ],
            ),
          ],
        ),
      );
      final runtime = TextSubtitleRuntime();
      await runtime.discover(YlFileSource(file.path));
      expect(runtime.state.tracks.map((t) => t.id), ['mp4:7', 'mp4:9']);
      expect(runtime.state.tracks.map((t) => t.format), [
        YlSubtitleFormat.webvtt,
        YlSubtitleFormat.ttml,
      ]);
      runtime.select('mp4:7');
      expect(runtime.cuesAt(const Duration(milliseconds: 999)), isEmpty);
      expect(
        runtime
            .cuesAt(const Duration(milliseconds: 1500))
            .single
            .text
            .toPlainText(),
        'one',
      );
      expect(
        runtime.cuesAt(const Duration(seconds: 2)).single.text.toPlainText(),
        'next',
      );
      runtime.select('mp4:9');
      expect(runtime.cuesAt(const Duration(milliseconds: 1249)), isEmpty);
      final cue = runtime.cuesAt(const Duration(milliseconds: 1250)).single;
      expect(cue.text.toPlainText(), 'two & 三');
      expect(cue.cue.textRuns!.every((r) => r.italic), true);
      expect(runtime.cuesAt(const Duration(seconds: 2)), isEmpty);
    },
  );
}
