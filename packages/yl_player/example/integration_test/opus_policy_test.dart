import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/range_media_server.dart';

const _asset = 'assets/test_media/format_matrix/mkv-avc-opus.mkv';
Future<Uint8List> _bytes() async {
  final data = await rootBundle.load(_asset);
  return Uint8List.fromList(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
}

int _uniqueOffset(Uint8List data, List<int> pattern) {
  final matches = <int>[];
  for (var i = 0; i <= data.length - pattern.length; i++) {
    var equal = true;
    for (var j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) {
        equal = false;
        break;
      }
    }
    if (equal) {
      matches.add(i);
    }
  }
  expect(matches, hasLength(1));
  return matches.single;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Opus strict policies and live intent reject explicitly', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('yl_opus_policy_');
    final file = File('${directory.path}/clip.mkv');
    await file.writeAsBytes(await _bytes());
    final server = await RangeMediaServer.start(asset: _asset);
    final player = await appleController(tester);
    try {
      for (final options in [
        const YlLoadOptions(bufferStrategy: strictBuffer),
        const YlLoadOptions(
          decoderPolicyOverride: YlDecoderPolicy.hardwareRequired,
        ),
      ]) {
        await expectLater(
          player.load(YlFileSource(file.path), options: options),
          failureCode('policy.opus_unsupported'),
        );
      }
      await expectLater(
        player.load(
          YlNetworkSource(server.mediaUri, networkPolicy: strictNetwork),
        ),
        failureCode('policy.opus_unsupported'),
      );
      await expectLater(
        player.load(
          YlNetworkSource(server.mediaUri, intent: YlStreamIntent.live),
        ),
        failureCode('container.network_mkv_live_unsupported'),
      );
    } finally {
      await player.dispose();
      await server.close();
      await tester.pumpWidget(const SizedBox.shrink());
      await directory.delete(recursive: true);
    }
  });
  testWidgets(
    'Invalid Opus header preserves current playback and hides input identity',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'yl_opus_header_',
      );
      final bytes = await _bytes();
      final file = File('${directory.path}/clip.mkv');
      await file.writeAsBytes(bytes);
      final offset = _uniqueOffset(bytes, 'OpusHead'.codeUnits);
      bytes[offset + 18] =
          1; // unsupported mapping family, deliberately incomplete.
      final bad = File('${directory.path}/private-token.mkv');
      await bad.writeAsBytes(bytes);
      final player = await appleController(tester);
      try {
        final session = await player.load(YlFileSource(file.path));
        await readyAndPlay(player, session);
        try {
          await player.load(YlFileSource(bad.path));
          fail('Invalid header committed');
        } on YlPlayerException catch (error) {
          expect(error.failure.code, 'decoder.audio_opus_unsupported');
          expect(error.failure.message, contains('mapping family 0'));
          expect(error.failure.message, isNot(contains('private-token')));
        }
        expect(player.state.sessionId, session.id);
        expect(player.state.failure, isNull);
        await session.seekTo(const Duration(milliseconds: 1250));
        await stateWhere(
          player,
          (s) => s.timeline.position > const Duration(milliseconds: 1600),
        );
      } finally {
        await player.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await directory.delete(recursive: true);
      }
    },
  );
  testWidgets(
    'Mixed AAC switches to Opus and back while strict policies retain AAC',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp('yl_opus_mixed_');
      final data = await rootBundle.load(
        'assets/test_media/format_matrix/mkv-avc-aac-opus.mkv',
      );
      final file = File('${directory.path}/mixed.mkv');
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      final player = await appleController(tester);
      try {
        final session = await player.load(YlFileSource(file.path));
        await readyAndPlay(player, session);
        final selected = player.state.audioTracks
            .singleWhere((t) => t.isSelected)
            .id;
        final opus = player.state.audioTracks
            .singleWhere((t) => !t.isSelected)
            .id;
        await session.pause();
        await session.seekTo(const Duration(milliseconds: 1250));
        await session.selectAudioTrack(opus);
        await stateWhere(
          player,
          (s) => s.audioTracks.any((t) => t.id == opus && t.isSelected),
        );
        expect(player.state.failure, isNull);
        await session.play();
        await stateWhere(
          player,
          (s) => s.timeline.position > const Duration(milliseconds: 1600),
        );
        await session.selectAudioTrack(selected);
        await stateWhere(
          player,
          (s) => s.audioTracks.any((t) => t.id == selected && t.isSelected),
        );
        expect(
          player.state.audioTracks.singleWhere((t) => t.isSelected).id,
          selected,
        );
        expect(player.state.failure, isNull);
        await session.seekTo(const Duration(milliseconds: 1250));
        await stateWhere(
          player,
          (s) => s.timeline.position > const Duration(milliseconds: 1600),
        );
        final strict = await player.load(
          YlFileSource(file.path),
          options: const YlLoadOptions(bufferStrategy: strictBuffer),
        );
        await readyAndPlay(player, strict);
        expect(player.state.audioTracks, hasLength(1));
        expect(player.state.failure, isNull);
      } finally {
        await player.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await directory.delete(recursive: true);
      }
    },
  );
  testWidgets(
    'HTTP Opus switches preserve playing intent and complete after seek',
    (tester) async {
      final server = await RangeMediaServer.start(
        asset: 'assets/test_media/format_matrix/mkv-avc-aac-opus.mkv',
      );
      final player = await appleController(tester);
      try {
        final session = await player.load(YlNetworkSource(server.mediaUri));
        await readyAndPlay(player, session);
        final aac = player.state.audioTracks
            .singleWhere((t) => t.isSelected)
            .id;
        final opus = player.state.audioTracks
            .singleWhere((t) => !t.isSelected)
            .id;
        await session.seekTo(const Duration(milliseconds: 1000));
        await stateWhere(
          player,
          (s) => s.timeline.position >= const Duration(milliseconds: 1100),
        );
        for (final track in [opus, aac, opus]) {
          final before = player.state.timeline.position;
          await session.selectAudioTrack(track);
          final selected = await stateWhere(
            player,
            (s) => s.audioTracks.any((t) => t.id == track && t.isSelected),
          );
          expect(selected.status, YlPlaybackStatus.playing);
          expect(selected.failure, isNull);
          expect(
            selected.timeline.position.inMilliseconds,
            greaterThanOrEqualTo(before.inMilliseconds - 1),
          );
        }
        await session.seekTo(const Duration(milliseconds: 2500));
        await stateWhere(player, (s) => s.status == YlPlaybackStatus.completed);
        expect(player.state.failure, isNull);
      } finally {
        await player.dispose();
        await server.close();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
  testWidgets('Malformed Opus packet reports a specific safe error', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('yl_opus_mode_');
    final bytes = await _bytes();
    // Independently probed first packet prefix. Mutate its frame count beyond
    // 120 ms; this is a negative, modified sample, not an unsupported mode.
    final offset = _uniqueOffset(bytes, [
      252,
      115,
      121,
      109,
      66,
      159,
      171,
      198,
      59,
      57,
      210,
      10,
      62,
      72,
      150,
      249,
    ]);
    bytes[offset] = 255;
    bytes[offset + 1] = 63;
    final file = File('${directory.path}/private-token.mkv');
    await file.writeAsBytes(bytes);
    final player = await appleController(tester);
    try {
      YlFailure? failure;
      try {
        final session = await player.load(YlFileSource(file.path));
        await session.ready;
        await session.play();
        failure = (await stateWhere(player, (s) => s.failure != null)).failure;
      } on YlPlayerException catch (error) {
        // The command may observe terminal state before its failure event reaches Dart.
        failure = error.failure.code == 'session.failed'
            ? (await stateWhere(player, (s) => s.failure != null)).failure
            : error.failure;
      }
      expect(failure?.code, 'decoder.audio_opus_failed');
      expect(failure?.message, contains('complete media file'));
      expect(failure?.message, isNot(contains('private-token')));
    } finally {
      await player.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await directory.delete(recursive: true);
    }
  });
}
