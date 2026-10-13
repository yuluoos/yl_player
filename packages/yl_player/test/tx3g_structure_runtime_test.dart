import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/tx3g_structure_fixture.dart';
import 'support/range_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final network in [false, true]) {
    for (final config in [false, true]) {
      test(
        '${network ? 'managed HTTP' : 'file'} ${config ? 'configuration' : 'modifier'} overflow preserves styled selection and recovery',
        () async {
          final old = HttpOverrides.current;
          HttpOverrides.global = null;
          addTearDown(() => HttpOverrides.global = old);
          final dir = await Directory.systemTemp.createTemp('tx3g-structure-');
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
                  entry: description(
                    defaults: style(face: 1, color: 0xff0000ff),
                  ),
                  samples: [textSample('kept')],
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
              await source(
                config
                    ? configurationFile(200000)
                    : modifierFile('hybrid', 199949),
                'over',
              ),
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
          expect(cue.cue.textRuns!.single.bold, true);
          expect(cue.cue.textRuns!.single.color, 0xffff0000);
          expect(cue.cue.textRuns!.single.fontFamily, 'Arial');
          await runtime.discover(good);
          expect(runtime.state.selectedTrackId, 'mp4:1');
          expect(
            runtime.cuesAt(Duration.zero).single.text.toPlainText(),
            'kept',
          );
        },
      );
    }
  }
}
