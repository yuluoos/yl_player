import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/wvtt_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'actual MP4 wvtt file discovers and renders simultaneous styled cues',
    () async {
      final dir = await Directory.systemTemp.createTemp('wvtt-owned-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/movie.mp4');
      await file.writeAsBytes(
        mp4(
          tracks: [
            wvttTrack(
              id: 7,
              samples: [
                box('vtte', []),
                [
                  ...vttCue(
                    '<b>one</b>',
                    id: 'owned',
                    settings: 'position:25%,center align:left',
                  ),
                  ...vttCue('two &amp; 三'),
                ],
                box('vtte', []),
              ],
              durations: [1000, 1500, 500],
            ),
          ],
        ),
      );
      final runtime = TextSubtitleRuntime();
      await runtime.discover(YlFileSource(file.path));
      expect(runtime.state.tracks.single.id, 'mp4:7');
      expect(runtime.state.tracks.single.format, YlSubtitleFormat.webvtt);
      runtime.select('mp4:7');
      expect(runtime.cuesAt(const Duration(milliseconds: 999)), isEmpty);
      final cues = runtime.cuesAt(const Duration(milliseconds: 1000));
      expect(cues.map((c) => c.text.toPlainText()), ['one', 'two & 三']);
      expect(cues.first.cue.identifier, 'owned');
      expect(cues.first.cue.positionPercent, 25);
      expect(cues.first.cue.alignment, 'left');
      expect(runtime.cuesAt(const Duration(milliseconds: 2500)), isEmpty);
    },
  );
}
