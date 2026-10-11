import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/mp4_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real MP4 tx3g file discovers Track ID and renders literal text at sample time',
    () async {
      final dir = await Directory.systemTemp.createTemp('mp4-owned-');
      final file = File('${dir.path}/owned.mp4');
      await file.writeAsBytes(
        mp4(
          tracks: [
            Mp4Track(
              id: 7,
              samples: [textSample(''), textSample('<b>literal</b>')],
              durations: [1000, 1500],
            ),
          ],
        ),
      );
      addTearDown(() => dir.delete(recursive: true));
      final runtime = TextSubtitleRuntime();
      await runtime.discover(
        YlFileSource(file.path, format: YlMediaFormat.mp4),
      );
      expect(runtime.state.tracks.single.id, 'mp4:7');
      runtime.select('mp4:7');
      expect(runtime.cuesAt(const Duration(milliseconds: 999)), isEmpty);
      expect(
        runtime
            .cuesAt(const Duration(milliseconds: 1000))
            .single
            .text
            .toPlainText(),
        '<b>literal</b>',
      );
      expect(runtime.cuesAt(const Duration(milliseconds: 2500)), isEmpty);
    },
  );
}
