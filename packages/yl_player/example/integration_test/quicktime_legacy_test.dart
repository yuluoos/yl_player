import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

/// QuickTime permits an omitted ftyp atom. Replace it with equal-sized free
/// space so the owned file's media payload and every chunk offset stay exact.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final network in [false, true]) {
    testWidgets(
      'automatic legacy MOV ${network ? 'HTTP' : 'file'} outputs a frame',
      (tester) async {
        final asset = await rootBundle.load(
          'assets/test_media/format_matrix/mov-hevc-aac.mov',
        );
        final bytes = asset.buffer
            .asUint8List(asset.offsetInBytes, asset.lengthInBytes)
            .toList();
        expect(String.fromCharCodes(bytes.sublist(4, 8)), 'ftyp');
        bytes.setRange(4, 8, 'free'.codeUnits);
        final directory = await Directory.systemTemp.createTemp(
          'yl_legacy_mov_',
        );
        final file = await File(
          '${directory.path}/legacy.mov',
        ).writeAsBytes(bytes);
        HttpServer? server;
        if (network) {
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server.listen((request) async {
            var start = 0, end = bytes.length - 1;
            final range = request.headers.value('range');
            if (range != null) {
              final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
              start = int.parse(match[1]!);
              if (match[2]!.isNotEmpty) {
                end = int.parse(match[2]!).clamp(start, end);
              }
              request.response.statusCode = 206;
              request.response.headers.set(
                'Content-Range',
                'bytes $start-$end/${bytes.length}',
              );
            }
            request.response.contentLength = end - start + 1;
            request.response.headers.set('Accept-Ranges', 'bytes');
            request.response.add(bytes.sublist(start, end + 1));
            await request.response.close();
          });
        }
        final player = await YlPlayerController.create();
        try {
          await tester.pumpWidget(
            MaterialApp(home: YlPlayerView(controller: player)),
          );
          final session = await player.load(
            network
                ? YlNetworkSource(
                    Uri.parse('http://127.0.0.1:${server!.port}/legacy.mov'),
                    intent: YlStreamIntent.onDemand,
                  )
                : YlFileSource(file.path),
          );
          await session.ready.timeout(const Duration(seconds: 15));
          await session.play();
          await session.firstFrame.timeout(const Duration(seconds: 10));
          expect(player.state.failure, isNull);
          expect(player.state.videoGeometry, isNotNull);
        } finally {
          await player.dispose();
          await tester.pumpWidget(const SizedBox.shrink());
          await server?.close(force: true);
          await directory.delete(recursive: true);
        }
      },
    );
  }
}
