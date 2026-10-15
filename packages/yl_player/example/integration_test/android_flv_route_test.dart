import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

/// The P03 VOD seek route must not intercept existing streaming FLV sources.
/// This finite owned response checks routing, not long-play/live recovery.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final intent in [YlStreamIntent.automatic, YlStreamIntent.live]) {
    testWidgets('Android ${intent.name} FLV retains Media3 with managed HTTP', (
      tester,
    ) async {
      final data = await rootBundle.load(
        'assets/test_media/format_matrix/flv-avc-mp3.flv',
      );
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
      final player = await YlPlayerController.create(
        options: const YlPlayerOptions(audioPolicy: YlAudioPolicy.appManaged),
      );
      try {
        await tester.pumpWidget(
          MaterialApp(home: YlPlayerView(controller: player)),
        );
        final session = await player
            .load(
              YlNetworkSource(
                Uri.parse('http://127.0.0.1:${server.port}/stream.flv'),
                intent: intent,
                networkPolicy: const YlNetworkPolicy.managed(maxRetries: 0),
              ),
            )
            .timeout(const Duration(seconds: 15));
        await session.ready.timeout(const Duration(seconds: 10));
        await session.play();
        await session.firstFrame.timeout(const Duration(seconds: 10));
        expect(player.state.engine, YlPlaybackEngine.media3);
        expect(player.state.failure, isNull);
        expect(requests, greaterThan(0));
      } finally {
        await player.dispose().timeout(const Duration(seconds: 5));
        await tester.pumpWidget(const SizedBox.shrink());
        await server.close(force: true);
      }
    });
  }
}
