import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

/// Real unavailable hardware from an owned AV1 fixture. Controlled allocator
/// exhaustion is exercised natively; no production budget override is exposed.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('unavailable AV1 hardware produces the public nonretryable error', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp(
      'yl_decoder_error_',
    );
    final bytes = await rootBundle.load(
      'assets/test_media/format_matrix/av1-hardware-control.mkv',
    );
    final file = File('${directory.path}/av1.mkv');
    await file.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    final player = await YlPlayerController.create(
      options: const YlPlayerOptions(
        decoderPolicy: YlDecoderPolicy.hardwareRequired,
        audioPolicy: YlAudioPolicy.appManaged,
      ),
    );
    try {
      await tester.pumpWidget(
        MaterialApp(home: YlPlayerView(controller: player)),
      );
      YlPlayerException? observed;
      try {
        final session = await player
            .load(YlFileSource(file.path))
            .timeout(const Duration(seconds: 15));
        await session.ready.timeout(const Duration(seconds: 10));
        await session.play();
        await session.firstFrame.timeout(const Duration(seconds: 10));
      } on YlPlayerException catch (error) {
        observed = error;
      }
      // A machine with working AV1 hardware is a positive hardware control,
      // explicitly not evidence that the unavailable-error branch was tested.
      if (observed == null) {
        expect(player.state.decoderMode, YlDecoderMode.hardware);
        debugPrint(
          'YL_DECODER_ERROR_ROW=hardware-available-negative-control-unexercised',
        );
      } else {
        expect(observed.failure.code, YlFailureCodes.decoderUnavailable);
        expect(observed.failure.retryable, isFalse);
        debugPrint('YL_DECODER_ERROR_ROW=actual-unavailable-nonretryable');
      }
    } finally {
      await player.dispose().timeout(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox.shrink());
      await directory.delete(recursive: true);
    }
  });
}
