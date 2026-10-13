import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'elng_parser_test.dart' show languageFile, elng;
import 'support/range_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final network in [false, true]) {
    for (final codec in ['tx3g', 'wvtt', 'stpp']) {
      for (final layout in ['ordinary', 'fragmented', 'hybrid']) {
        test(
          '${network ? 'managed HTTP' : 'file'} $codec $layout language, atomic rejection and recovery',
          () async {
            final previous = HttpOverrides.current;
            HttpOverrides.global = null;
            addTearDown(() => HttpOverrides.global = previous);
            final dir = await Directory.systemTemp.createTemp('elng-');
            addTearDown(() => dir.delete(recursive: true));
            final servers = <RangeServer>[];
            Future<YlMediaSource> source(String tag) async {
              final bytes = languageFile(
                elng(tag),
                codec: codec,
                layout: layout,
              );
              if (network) {
                final server = await RangeServer.start(bytes);
                servers.add(server);
                addTearDown(server.close);
                return YlNetworkSource(
                  server.uri,
                  networkPolicy: const YlNetworkPolicy.managed(maxRetries: 0),
                  request: YlHttpRequest(
                    credentials: {'Authorization': 'owned'},
                  ),
                );
              }
              final file = File('${dir.path}/${tag.hashCode}.mp4');
              await file.writeAsBytes(bytes);
              return YlFileSource(file.path);
            }

            final runtime = TextSubtitleRuntime();
            addTearDown(runtime.reset);
            await runtime.discover(await source('zh-Hant'));
            expect(runtime.state.tracks.single.language, 'zh-Hant');
            runtime.select('mp4:1');
            final before = runtime.state;
            await expectLater(
              runtime.discover(await source('en--US')),
              throwsA(
                isA<YlPlayerException>().having(
                  (e) => e.failure.code,
                  'code',
                  YlFailureCodes.subtitleMalformed,
                ),
              ),
            );
            expect(runtime.state, same(before));
            expect(
              runtime.cuesAt(Duration.zero).single.text.toPlainText(),
              'hello',
            );
            await runtime.discover(await source('zh-Hans'));
            expect(runtime.state.selectedTrackId, 'mp4:1');
            expect(runtime.state.tracks.single.language, 'zh-Hans');
            expect(
              runtime.cuesAt(Duration.zero).single.text.toPlainText(),
              'hello',
            );
            for (final server in servers) {
              expect(server.requests, isNotEmpty);
              for (final q in server.requests) {
                expect(q.headers.value('authorization'), 'owned');
                expect(q.headers.value('range'), startsWith('bytes='));
              }
              expect(
                server.requests.skip(1).map((q) => q.headers.value('if-match')),
                everyElement('"owned-v1"'),
              );
            }
          },
        );
      }
    }
  }
}
