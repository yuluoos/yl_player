import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

void checkDiscPlayback({
  required String disc,
  required String asset,
  required int seekSeconds,
}) {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  for (final network in [false, true]) {
    testWidgets(
      '$disc ISO ${network ? 'HTTP ranges' : 'local file'} plays across clips and seeks',
      (tester) async {
        final data = await rootBundle.load('assets/test_media/$asset');
        final image = gzip.decode(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        late final YlMediaSource source;
        var requests = 0;
        if (network) {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((r) async {
            final range = RegExp(
              r'^bytes=(\d+)-(\d+)$',
            ).firstMatch(r.headers.value('range') ?? '');
            if (range == null ||
                r.headers.value('authorization') != 'Bearer iso-test') {
              r.response.statusCode = 403;
            } else {
              requests++;
              final start = int.parse(range[1]!), end = int.parse(range[2]!);
              r.response
                ..statusCode = 206
                ..headers.set(
                  'content-range',
                  'bytes $start-$end/${image.length}',
                )
                ..contentLength = end - start + 1
                ..add(image.sublist(start, end + 1));
            }
            await r.response.close();
          });
          source = YlNetworkSource(
            Uri.parse('http://127.0.0.1:${server.port}/disc.iso?version=1'),
            request: YlHttpRequest(
              credentials: {'Authorization': 'Bearer iso-test'},
            ),
          );
        } else {
          final temp = await Directory.systemTemp.createTemp('yl-iso-');
          addTearDown(() => temp.delete(recursive: true));
          final file = await File('${temp.path}/Movie.ISO').writeAsBytes(image);
          source = YlFileSource(file.path);
        }
        final player = await YlPlayerController.create();
        addTearDown(player.dispose);
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: YlPlayerView(controller: player),
          ),
        );
        final session = await player.load(source);
        await session.ready.timeout(const Duration(seconds: 30));
        await session.play();
        await session.firstFrame.timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            final state = player.state;
            throw StateError(
              'No first frame from ${state.engine} at '
              '${state.timeline.position} of ${state.timeline.duration}, '
              'state ${state.status}, geometry ${state.videoGeometry}, '
              'audio tracks ${state.audioTracks.length}, video tracks ${state.videoTracks.length}, failure ${state.failure}',
            );
          },
        );
        Future<void> reached(int seconds) async {
          bool there(YlPlayerState s) =>
              s.timeline.position >= Duration(seconds: seconds);
          if (!there(player.state)) {
            await player.states
                .firstWhere(there)
                .timeout(const Duration(seconds: 30));
          }
        }

        // Both fixtures change cells or clips at 7 s.
        await reached(8);
        await session.seekTo(Duration(seconds: seekSeconds));
        await reached(seekSeconds + 1);
        await session.seekTo(const Duration(seconds: 2));
        bool returned(YlPlayerState state) =>
            state.timeline.position >= const Duration(seconds: 1) &&
            state.timeline.position < const Duration(seconds: 4);
        if (!returned(player.state)) {
          await player.states
              .firstWhere(returned)
              .timeout(const Duration(seconds: 8));
        }
        await reached(3);
        if (network) expect(requests, greaterThan(1));
      },
    );
  }
}
