import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final intent in YlStreamIntent.values) {
    testWidgets(
      'FLV ${intent.name} respects a server without Range',
      (tester) async {
        final asset = await rootBundle.load(
          'assets/test_media/format_matrix/flv-avc-mp3.flv',
        );
        final bytes = asset.buffer.asUint8List(
          asset.offsetInBytes,
          asset.lengthInBytes,
        );
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final ranges = <String?>[];
        server.listen((request) async {
          ranges.add(request.headers.value(HttpHeaders.rangeHeader));
          request.response.headers.contentType = ContentType.binary;
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
          await request.response.close();
        });
        YlPlayerController? player;
        try {
          player = await YlPlayerController.create(
            options: const YlPlayerOptions(
              audioPolicy: YlAudioPolicy.appManaged,
            ),
          );
          await tester.pumpWidget(
            MaterialApp(home: YlPlayerView(controller: player)),
          );
          final session = await player
              .load(
                YlNetworkSource(
                  Uri.parse('http://127.0.0.1:${server.port}/clip.flv'),
                  intent: intent,
                ),
              )
              .timeout(const Duration(seconds: 15));
          await session.ready.timeout(const Duration(seconds: 10));
          final isLive = intent != YlStreamIntent.onDemand;
          expect(player.state.timeline.isLive, isLive);
          expect(player.state.timeline.isSeekable, isFalse);
          if (isLive) {
            expect(player.state.timeline.duration, isNull);
            expect(ranges, everyElement(isNull));
          } else {
            expect(player.state.timeline.duration, isNotNull);
            expect(ranges, contains('bytes=0-'));
          }
          await session.play();
          await session.firstFrame.timeout(const Duration(seconds: 10));
          await expectLater(
            session.seekTo(const Duration(seconds: 2)),
            throwsA(
              isA<YlPlayerException>()
                  .having(
                    (e) => e.failure.code,
                    'code',
                    'network.range_not_supported',
                  )
                  .having(
                    (e) => e.failure.scope,
                    'scope',
                    YlFailureScope.command,
                  ),
            ),
          );
          expect(player.state.failure, isNull);
        } finally {
          await player?.dispose();
          await tester.pumpWidget(const SizedBox.shrink());
          await server.close(force: true);
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}
