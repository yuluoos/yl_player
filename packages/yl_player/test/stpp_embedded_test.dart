import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/stpp_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'actual stpp file uses document track time and retains styles and region',
    () async {
      final dir = await Directory.systemTemp.createTemp('stpp-owned-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/movie.mp4');
      await file.writeAsBytes(
        mp4(
          tracks: [
            stppTrack(
              id: 7,
              samples: [
                stppSample(''),
                stppSample(
                  '<p xml:id="one" begin="1.25s" end="3s" region="r" tts:fontWeight="bold">one &amp; 三</p>',
                  head:
                      '<head><layout><region xml:id="r" tts:origin="10% 60%" tts:extent="80% 30%" tts:displayAlign="after"/></layout></head>',
                ),
                stppSample(''),
              ],
              durations: [1000, 1500, 500],
            ),
          ],
        ),
      );
      final runtime = TextSubtitleRuntime();
      await runtime.discover(YlFileSource(file.path));
      expect(runtime.state.tracks.single.id, 'mp4:7');
      expect(runtime.state.tracks.single.format, YlSubtitleFormat.ttml);
      runtime.select('mp4:7');
      expect(runtime.cuesAt(const Duration(milliseconds: 1249)), isEmpty);
      final cue = runtime.cuesAt(const Duration(milliseconds: 1250)).single;
      expect(cue.text.toPlainText(), 'one & 三');
      expect(cue.cue.identifier, 'one');
      expect(cue.cue.textRuns!.every((r) => r.bold), true);
      expect(cue.cue.region!.x, .1);
      expect(cue.cue.region!.displayAlign, 'after');
      expect(runtime.cuesAt(const Duration(milliseconds: 2499)), hasLength(1));
      expect(runtime.cuesAt(const Duration(milliseconds: 2500)), isEmpty);
    },
  );
  test(
    'retained external metadata and empty stpp XML share catalog byte budget',
    () async {
      final dir = await Directory.systemTemp.createTemp('stpp-budget-');
      addTearDown(() => dir.delete(recursive: true));
      final external = await File('${dir.path}/external.ttml').writeAsString(
        ttmlDocument(
          '<p begin="0s" end="1s">old</p>',
          head: '<!--${'a' * 1100000}-->',
        ),
      );
      final sample = stppSample('', head: '<!--${'a' * 240000}-->');
      final file = await File('${dir.path}/movie.mp4').writeAsBytes(
        mp4(
          tracks: [
            stppTrack(
              samples: List.filled(14, sample),
              durations: List.filled(14, 1000),
            ),
          ],
        ),
      );
      final runtime = TextSubtitleRuntime();
      await runtime.replace([
        YlExternalSubtitle(
          id: 'old',
          format: YlSubtitleFormat.ttml,
          source: YlFileSource(external.path),
        ),
      ]);
      runtime.select('old');
      await expectLater(
        runtime.discover(YlFileSource(file.path)),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.subtitleTooLarge,
          ),
        ),
      );
      expect(runtime.state.tracks.map((t) => t.id), ['old']);
      expect(runtime.state.selectedTrackId, 'old');
      expect(runtime.cuesAt(Duration.zero).single.text.toPlainText(), 'old');
    },
  );
}
