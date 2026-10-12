import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/fmp4_fixture.dart';
import 'mp4_parser_test.dart' show parse;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'independent FFmpeg fragmented tx3g sample timeline and style',
    () async {
      final data = await parse(
        await File(
          'packages/yl_player/test/fixtures/fmp4-tx3g-owned.mp4',
        ).readAsBytes(),
      );
      expect(data.single.track.id, 'mp4:2');
      expect(data.single.track.language, 'eng');
      final packets = data.single.packets;
      expect(packets.map((p) => p.text), ['bold and 中文', 'second']);
      expect(packets.map((p) => p.start.inMicroseconds), [1000000, 3123000]);
      expect(packets.map((p) => p.end.inMicroseconds), [3123000, 4567000]);
      expect(packets.first.textRuns!.first.bold, true);
    },
  );
  test(
    'actual fMP4 tx3g discovers selects and renders literal styled text',
    () async {
      final dir = await Directory.systemTemp.createTemp('fmp4-tx3g-');
      addTearDown(() => dir.delete(recursive: true));
      final file = await File('${dir.path}/owned.mp4').writeAsBytes(
        fragmented(
          tracks: [
            Mp4Track(
              id: 7,
              entry: description(defaults: style(face: 1)),
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
                  samples: [textSample('<b>literal</b>')],
                  durations: [1500],
                ),
              ],
            ),
            Fragment(
              sequence: 2,
              tracks: [
                FragmentTrack(id: 7, time: 2500, samples: [textSample('')]),
              ],
            ),
          ],
        ),
      );
      final runtime = TextSubtitleRuntime();
      await runtime.discover(YlFileSource(file.path));
      expect(runtime.state.tracks.single.id, 'mp4:7');
      expect(runtime.state.tracks.single.format, YlSubtitleFormat.srt);
      runtime.select('mp4:7');
      expect(runtime.cuesAt(const Duration(milliseconds: 999)), isEmpty);
      final cue = runtime.cuesAt(const Duration(seconds: 1)).single;
      expect(cue.text.toPlainText(), '<b>literal</b>');
      expect(cue.cue.textRuns!.every((r) => r.bold), true);
      expect(runtime.cuesAt(const Duration(milliseconds: 2500)), isEmpty);
    },
  );
}
