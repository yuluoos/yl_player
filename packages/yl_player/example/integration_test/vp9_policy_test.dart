import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/range_media_server.dart';

const _asset = 'assets/test_media/format_matrix/webm-vp9-opus.webm';
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('VP9 enforces strict resource policies during playback', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('yl_vp9_policy_');
    final data = await rootBundle.load(_asset);
    final file = File('${directory.path}/clip.webm');
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    final server = await RangeMediaServer.start(asset: _asset);
    final player = await appleController(tester);
    try {
      await exercisePolicyPlayback(
        player,
        YlFileSource(file.path),
        options: const YlLoadOptions(bufferStrategy: strictBuffer),
      );
      await exercisePolicyPlayback(
        player,
        YlNetworkSource(server.mediaUri, networkPolicy: strictNetwork),
        options: const YlLoadOptions(
          bufferStrategy: strictBuffer,
          decoderPolicyOverride: YlDecoderPolicy.hardwareRequired,
        ),
      );
    } finally {
      await player.dispose();
      await server.close();
      await tester.pumpWidget(const SizedBox.shrink());
      await directory.delete(recursive: true);
    }
  });
  testWidgets('Unsupported VP9 profile preserves the playing session', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('yl_vp9_profile_');
    final data = await rootBundle.load(_asset);
    final bytes = Uint8List.fromList(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    final good = File('${directory.path}/good.webm');
    await good.writeAsBytes(bytes);
    final offsets = <int>[];
    for (var i = 0; i + 4 < bytes.length; i++) {
      if (bytes[i] == 0x82 &&
          bytes[i + 1] == 0x49 &&
          bytes[i + 2] == 0x83 &&
          bytes[i + 3] == 0x42) {
        offsets.add(i);
      }
    }
    expect(offsets, hasLength(4)); // Four independently generated keyframes.
    bytes[offsets.first] |=
        0x10; // Profile 2, outside the accepted 8-bit profile.
    final bad = File('${directory.path}/private-token.webm');
    await bad.writeAsBytes(bytes);
    final player = await appleController(tester);
    try {
      final session = await player.load(YlFileSource(good.path));
      await readyAndPlay(player, session);
      await expectLater(
        player.load(YlFileSource(bad.path)),
        failureCode('decoder.video_vp9_unsupported'),
      );
      expect(player.state.failure, isNull);
      await session.pause();
      await session.seekTo(const Duration(milliseconds: 1250));
      await session.play();
      await stateWhere(
        player,
        (s) => s.timeline.position > const Duration(milliseconds: 1600),
      );
    } finally {
      await player.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await directory.delete(recursive: true);
    }
  });
  testWidgets('VP9 seek retains opening color and range constraints', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('yl_vp9_range_');
    final data = await rootBundle.load(_asset);
    final bytes = Uint8List.fromList(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    final offsets = <int>[];
    for (var i = 0; i + 4 < bytes.length; i++) {
      if (bytes[i] == 0x82 &&
          bytes[i + 1] == 0x49 &&
          bytes[i + 2] == 0x83 &&
          bytes[i + 3] == 0x42) {
        offsets.add(i);
      }
    }
    expect(offsets, hasLength(4));
    bytes[offsets.last + 4] |=
        0x10; // Same-size final keyframe changes limited to full range.
    final file = File('${directory.path}/changed-range.webm');
    await file.writeAsBytes(bytes);
    final player = await appleController(tester);
    try {
      final session = await player.load(YlFileSource(file.path));
      await readyAndPlay(player, session);
      expect(player.state.decoderMode.name, 'hardware');
      YlFailure? failure;
      try {
        await session.pause();
        await session.seekTo(const Duration(milliseconds: 3250));
        await session.play();
        failure = (await stateWhere(player, (s) => s.failure != null)).failure;
      } on YlPlayerException catch (error) {
        failure = error.failure.code == 'session.failed'
            ? (await stateWhere(player, (s) => s.failure != null)).failure
            : error.failure;
      }
      expect(failure?.code, 'decoder.video_vp9_unsupported');
    } finally {
      await player.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await directory.delete(recursive: true);
    }
  });
}
