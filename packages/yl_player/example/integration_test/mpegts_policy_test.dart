import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('TS live and strict policies reject before network access', (
    tester,
  ) async {
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      request.response.statusCode = 500;
      await request.response.close();
    });
    final player = await appleController(tester);
    try {
      final uri = Uri.parse('http://127.0.0.1:${server.port}/clip.ts');
      await expectLater(
        player.load(YlNetworkSource(uri, intent: YlStreamIntent.live)),
        failureCode('container.mpegts_live_unsupported'),
      );
      await expectLater(
        player.load(YlNetworkSource(uri, networkPolicy: strictNetwork)),
        failureCode('policy.unsupported'),
      );
      await expectLater(
        player.load(
          YlNetworkSource(uri),
          options: const YlLoadOptions(bufferStrategy: strictBuffer),
        ),
        failureCode('policy.unsupported'),
      );
      await expectLater(
        player.load(
          YlNetworkSource(uri),
          options: const YlLoadOptions(
            decoderPolicyOverride: YlDecoderPolicy.hardwareRequired,
          ),
        ),
        failureCode('policy.unsupported'),
      );
      expect(requests, 0);
    } finally {
      await player.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await server.close(force: true);
    }
  });

  testWidgets(
    'Malformed TS reports a safe container error and preserves current playback',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp('yl_ts_policy_');
      final asset = await rootBundle.load(
        'assets/test_media/format_matrix/ts-avc-ac3.ts',
      );
      final file = File('${directory.path}/valid.ts');
      await file.writeAsBytes(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
      );
      final broken = File('${directory.path}/private-token.ts');
      await broken.writeAsBytes([0x47, 0, 0, 0x10]);
      final player = await appleController(tester);
      try {
        final session = await player.load(YlFileSource(file.path));
        await readyAndPlay(player, session);
        try {
          await player.load(YlFileSource(broken.path));
          fail('Malformed TS committed');
        } on YlPlayerException catch (error) {
          expect(error.failure.code, 'container.mpegts_open_failed');
          expect(error.failure.scope, YlFailureScope.command);
          expect(error.failure.message, contains('MPEG-TS'));
          expect(error.failure.message, isNot(contains('private-token')));
        }
        expect(player.state.sessionId, session.id);
        expect(player.state.failure, isNull);
        await session.pause();
        await session.seekTo(const Duration(seconds: 1));
        await session.play();
        await stateWhere(
          player,
          (s) => s.timeline.position > const Duration(milliseconds: 1350),
        );
      } finally {
        await player.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets('TS server without Range never claims seekability', (
    tester,
  ) async {
    final asset = await rootBundle.load(
      'assets/test_media/format_matrix/ts-avc-ac3.ts',
    );
    final bytes = asset.buffer.asUint8List(
      asset.offsetInBytes,
      asset.lengthInBytes,
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
    final player = await appleController(tester);
    try {
      final session = await player.load(
        YlNetworkSource(
          Uri.parse('http://127.0.0.1:${server.port}/clip.ts'),
          intent: YlStreamIntent.onDemand,
        ),
      );
      await readyAndPlay(player, session);
      expect(player.state.timeline.isLive, isFalse);
      expect(player.state.timeline.isSeekable, isFalse);
      await expectLater(
        session.seekTo(const Duration(seconds: 2)),
        failureCode('network.range_not_supported'),
      );
      expect(player.state.failure, isNull);
    } finally {
      await player.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await server.close(force: true);
    }
  });
}
