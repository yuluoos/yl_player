import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

/// Check the first actual displayed marker, not the initial timeline value.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final fixture in ['avi-avc-mp3.avi', 'flv-avc-mp3.flv']) {
    testWidgets('native $fixture starts with blue pixels at 2500ms', (
      tester,
    ) async {
      final directory = await Directory.systemTemp.createTemp('yl_resume_');
      final data = await rootBundle.load(
        'assets/test_media/format_matrix/$fixture',
      );
      final file = await File('${directory.path}/$fixture').writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      final player = await YlPlayerController.create(
        options: const YlPlayerOptions(audioPolicy: YlAudioPolicy.appManaged),
      );
      final capture = GlobalKey();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: capture,
              child: YlPlayerView(controller: player),
            ),
          ),
        );
        final session = await player.load(
          YlFileSource(file.path),
          options: const YlLoadOptions(
            startPosition: Duration(milliseconds: 2500),
          ),
        );
        await session.ready.timeout(const Duration(seconds: 10));
        await session.play();
        await session.firstFrame.timeout(const Duration(seconds: 10));
        final watch = Stopwatch()..start();
        List<int>? rgb;
        while (watch.elapsed < const Duration(seconds: 2)) {
          await tester.pump(const Duration(milliseconds: 30));
          final image =
              await (capture.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final offset =
                ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
            final value = [
              for (var c = 0; c < 3; c++) bytes.getUint8(offset + c),
            ];
            if (value.any((v) => v > 100)) {
              rgb = value;
              break;
            }
          } finally {
            image.dispose();
          }
        }
        expect(rgb, isNotNull);
        expect(rgb![0], lessThan(40));
        expect(rgb[1], lessThan(40));
        expect(rgb[2], greaterThan(220));
        expect(player.state.engine, YlPlaybackEngine.managedFallback);
        expect(player.state.failure, isNull);
      } finally {
        await player.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await directory.delete(recursive: true);
      }
    });
  }
}
