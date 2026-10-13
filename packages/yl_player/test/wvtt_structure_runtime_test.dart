import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/wvtt_structure_fixture.dart';
import 'support/range_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final network in [false, true]) {
    test(
      '${network ? 'managed HTTP' : 'file'} overflow preserves selected cues and permits recovery',
      () async {
        final old = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = old);
        final dir = await Directory.systemTemp.createTemp('wvtt-structure-');
        addTearDown(() => dir.delete(recursive: true));
        Future<YlMediaSource> source(List<int> bytes, String name) async {
          if (network) {
            final server = await RangeServer.start(bytes);
            addTearDown(server.close);
            return YlNetworkSource(
              server.uri,
              networkPolicy: const YlNetworkPolicy.managed(maxRetries: 0),
              request: YlHttpRequest(credentials: {'Authorization': 'owned'}),
            );
          }
          final file = File('${dir.path}/$name.mp4');
          await file.writeAsBytes(bytes);
          return YlFileSource(file.path);
        }

        final runtime = TextSubtitleRuntime();
        addTearDown(runtime.reset);
        final good = await source(
          mp4(
            tracks: [
              Mp4Track(
                entry: wvttEntry(),
                samples: [
                  vttCue(
                    '<b>kept</b>',
                    settings: 'position:25%,center align:left',
                  ),
                ],
              ),
            ],
          ),
          'good',
        );
        await runtime.discover(good);
        runtime.select('mp4:1');
        final before = runtime.state;
        await expectLater(
          runtime.discover(
            await source(structureFile('hybrid', 200000), 'over'),
          ),
          throwsA(
            isA<YlPlayerException>().having(
              (e) => e.failure.code,
              'code',
              YlFailureCodes.subtitleTooLarge,
            ),
          ),
        );
        expect(runtime.state, same(before));
        final cue = runtime.cuesAt(Duration.zero).single;
        expect(cue.text.toPlainText(), 'kept');
        expect(cue.cue.positionPercent, 25);
        expect(cue.cue.alignment, 'left');
        await runtime.discover(good);
        expect(runtime.state.selectedTrackId, 'mp4:1');
        expect(runtime.cuesAt(Duration.zero).single.text.toPlainText(), 'kept');
      },
    );
  }
}
