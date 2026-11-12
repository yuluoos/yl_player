import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/range_media_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('AVI explicit live intent rejects before network access', (
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
      final uri = Uri.parse('http://127.0.0.1:${server.port}/clip.avi');
      await expectLater(
        player.load(
          YlNetworkSource(
            uri,
            format: YlMediaFormat.avi,
            intent: YlStreamIntent.live,
          ),
        ),
        failureCode('container.avi_live_unsupported'),
      );
      expect(requests, 0);
      await expectLater(
        player.load(YlNetworkSource(uri)),
        failureCode('network.http_status.500'),
      );
      expect(requests, greaterThan(0));
    } finally {
      await player.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await server.close(force: true);
    }
  });

  testWidgets(
    'AVI strict policies preserve playback, seeking and hardware evidence',
    (tester) async {
      final server = await RangeMediaServer.start(
        asset: 'assets/test_media/format_matrix/avi-avc-mp3.avi',
      );
      final player = await appleController(tester);
      try {
        await exercisePolicyPlayback(
          player,
          YlNetworkSource(server.mediaUri, networkPolicy: strictNetwork),
        );
        for (final options in [
          const YlLoadOptions(bufferStrategy: strictBuffer),
          const YlLoadOptions(
            decoderPolicyOverride: YlDecoderPolicy.hardwareRequired,
          ),
        ]) {
          await exercisePolicyPlayback(
            player,
            YlNetworkSource(server.mediaUri),
            options: options,
          );
        }
        await expectLater(
          player.load(
            YlNetworkSource(server.mediaUri, intent: YlStreamIntent.live),
          ),
          failureCode('container.avi_live_unsupported'),
        );
      } finally {
        await player.dispose();
        await server.close();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'Malformed AVI reports a safe container error and preserves current playback',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp('yl_avi_policy_');
      final asset = await rootBundle.load(
        'assets/test_media/format_matrix/avi-avc-mp3.avi',
      );
      final file = File('${directory.path}/valid.avi');
      await file.writeAsBytes(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
      );
      final broken = File('${directory.path}/private-token.avi');
      await broken.writeAsBytes([0x47, 0, 0, 0x10]);
      final player = await appleController(tester);
      try {
        final session = await player.load(YlFileSource(file.path));
        await readyAndPlay(player, session);
        // An unidentifiable prefix fails inspection; an explicit format reaches
        // that container's demuxer. Both failures must preserve the accepted session.
        for (final format in [YlMediaFormat.automatic, YlMediaFormat.avi]) {
          try {
            await player.load(YlFileSource(broken.path, format: format));
            fail('Malformed AVI committed');
          } on YlPlayerException catch (error) {
            expect(
              error.failure.code,
              format == YlMediaFormat.automatic
                  ? 'container.unsupported'
                  : 'container.avi_open_failed',
            );
            expect(error.failure.scope, YlFailureScope.command);
            if (format != YlMediaFormat.automatic) {
              expect(error.failure.message, contains('AVI'));
            }
            expect(error.failure.message, isNot(contains('private-token')));
          }
          expect(player.state.sessionId, session.id);
          expect(player.state.failure, isNull);
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

  testWidgets(
    'AVI without idx1 restores playback after forward and backward seek',
    (tester) async {
      final asset = await rootBundle.load(
        'assets/test_media/format_matrix/avi-avc-mp3.avi',
      );
      final input = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      final data = ByteData.sublistView(input);
      final output = BytesBuilder()..add(input.sublist(0, 12));
      var offset = 12;
      var removed = 0;
      while (offset + 8 <= input.length) {
        final size = data.getUint32(offset + 4, Endian.little);
        final end = offset + 8 + size + (size & 1);
        expect(end, lessThanOrEqualTo(input.length));
        if (String.fromCharCodes(input.sublist(offset, offset + 4)) == 'idx1') {
          removed++;
        } else {
          output.add(input.sublist(offset, end));
        }
        offset = end;
      }
      expect(removed, 1);
      expect(offset, input.length);
      final bytes = output.takeBytes();
      ByteData.sublistView(bytes).setUint32(4, bytes.length - 8, Endian.little);
      final directory = await Directory.systemTemp.createTemp(
        'yl_avi_no_index_',
      );
      final file = await File(
        '${directory.path}/no-index.avi',
      ).writeAsBytes(bytes);
      final player = await appleController(tester);
      try {
        final session = await player.load(YlFileSource(file.path));
        await readyAndPlay(player, session);
        expect(player.state.timeline.isSeekable, isTrue);
        for (final target in [2000, 1250]) {
          await session.pause();
          await session.seekTo(Duration(milliseconds: target));
          await session.play();
          await stateWhere(
            player,
            (s) => s.timeline.position > Duration(milliseconds: target + 200),
          );
          expect(player.state.failure, isNull);
        }
        await stateWhere(player, (s) => s.status == YlPlaybackStatus.completed);
      } finally {
        await player.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets('AVI server without Range never claims seekability', (
    tester,
  ) async {
    final asset = await rootBundle.load(
      'assets/test_media/format_matrix/avi-avc-mp3.avi',
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
          Uri.parse('http://127.0.0.1:${server.port}/clip.avi'),
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
