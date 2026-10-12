import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/fmp4_fixture.dart';
import 'mp4_parser_test.dart' show parse;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('FFmpeg hybrid tx3g sample tables and later fragments', () async {
    final data = await parse(
      await File(
        'packages/yl_player/test/fixtures/hybrid-mp4-owned.mp4',
      ).readAsBytes(),
    );
    expect(data.single.track.id, 'mp4:2');
    expect(data.single.packets.map((p) => p.text), ['bold and 中文', 'second']);
    expect(data.single.packets.map((p) => p.start.inMicroseconds), [
      0,
      3123000,
    ]);
    expect(data.single.packets.map((p) => p.end.inMicroseconds), [
      3123000,
      4567000,
    ]);
    expect(data.single.packets.first.textRuns!.first.bold, true);
  });
  test(
    'real hybrid MP4 joins initial and fragmented subtitles in all three codecs',
    () async {
      final dir = await Directory.systemTemp.createTemp('hybrid-mp4-');
      addTearDown(() => dir.delete(recursive: true));
      final file = await File('${dir.path}/owned.mp4').writeAsBytes(
        fragmented(
          tracks: [
            Mp4Track(id: 1, samples: [textSample('initial tx3g')]),
            Mp4Track(
              id: 2,
              entry: wvttEntry(),
              samples: [vttCue('initial vtt')],
            ),
            Mp4Track(
              id: 3,
              entry: stppEntry(),
              samples: [stppSample('<p begin="0s" end="1s">initial ttml</p>')],
            ),
          ],
          fragments: [
            Fragment(
              tracks: [
                FragmentTrack(
                  id: 3,
                  time: 1000,
                  samples: [
                    stppSample('<p begin="1.25s" end="3s">later ttml</p>'),
                  ],
                ),
                FragmentTrack(
                  id: 2,
                  time: 1000,
                  samples: [vttCue('later vtt')],
                ),
                FragmentTrack(
                  id: 1,
                  time: 1000,
                  samples: [textSample('later tx3g')],
                ),
              ],
            ),
          ],
        ),
      );
      final runtime = TextSubtitleRuntime();
      await runtime.discover(YlFileSource(file.path));
      expect(runtime.state.tracks.map((t) => t.id), [
        'mp4:1',
        'mp4:2',
        'mp4:3',
      ]);
      for (final (id, name) in [(1, 'tx3g'), (2, 'vtt'), (3, 'ttml')]) {
        runtime.select('mp4:$id');
        expect(
          runtime
              .cuesAt(const Duration(milliseconds: 500))
              .single
              .text
              .toPlainText(),
          'initial $name',
        );
        expect(
          runtime
              .cuesAt(const Duration(milliseconds: 1500))
              .single
              .text
              .toPlainText(),
          'later $name',
        );
        expect(runtime.cuesAt(const Duration(seconds: 2)), isEmpty);
      }
    },
  );
}
