import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/playback_sessions.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<File> copyAssetToLocalFile(String name) async {
    final data = await rootBundle.load('assets/test_media/$name');
    final directory = await Directory.systemTemp.createTemp('yl_player_mkv_');
    final file = File('${directory.path}/$name');
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    addTearDown(() => directory.delete(recursive: true));
    return file;
  }

  testWidgets('local H264 AAC MKV uses native fallback and renders a frame', (
    WidgetTester tester,
  ) async {
    final file = await copyAssetToLocalFile('h264_aac.mkv');
    final controller = await YlPlayerController.create();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AspectRatio(
          aspectRatio: 16 / 9,
          child: YlPlayerView(controller: controller),
        ),
      ),
    );

    // R21: this default-policy geometry case requires successful real playback.
    // Hardware-required rejection is covered separately by native policy tests.
    await loadSession(
      controller,
      YlFileSource(file.path, format: YlMediaFormat.matroska),
    );
    final firstFrame = controller.events
        .firstWhere((event) => event is YlFirstFrameEvent)
        .timeout(const Duration(seconds: 15));
    await sessionFor(controller).play();
    await sessionFor(controller).ready.timeout(const Duration(seconds: 20));
    await firstFrame;
    await tester.pump();

    expect(controller.state.engine, YlPlaybackEngine.managedFallback);
    debugPrint(
      'TASK7_LOCAL_MKV_DECODER_MODE=${controller.state.decoderMode.name}',
    );
    expect(controller.state.decoderIdentity, 'VideoToolbox');
    expect(controller.state.videoGeometry?.displaySize.width, 320);
    expect(controller.state.videoGeometry?.displaySize.height, 180);
    expect(controller.state.videoGeometry?.encodedSize.width, 320);
    expect(controller.state.videoGeometry?.encodedSize.height, 180);
    expect(controller.state.videoGeometry?.pixelAspectRatio, 1);
    expect(controller.state.videoGeometry?.rotationDegrees, 0);
    debugPrint(
      'TASK7_LOCAL_MKV_GEOMETRY_PASS: encoded=320x180 display=320x180 PAR=1 rotation=0',
    );
    expect(controller.textureId.value, isNotNull);

    await sessionFor(controller).seekTo(const Duration(milliseconds: 900));
    final seeked = await controller.states
        .firstWhere(
          (state) =>
              state.timeline.position >= const Duration(milliseconds: 850),
        )
        .timeout(const Duration(seconds: 10));
    expect(seeked.engine, YlPlaybackEngine.managedFallback);
  });

  testWidgets('local MKV exposes and switches both AAC tracks', (
    WidgetTester tester,
  ) async {
    final file = await copyAssetToLocalFile('two_audio_tracks.mkv');
    final controller = await YlPlayerController.create();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: controller)),
    );

    await loadSession(
      controller,
      YlFileSource(file.path, format: YlMediaFormat.matroska),
    );
    final session = sessionFor(controller);
    await session.ready.timeout(const Duration(seconds: 20));
    final trackState =
        controller.state.sessionId == session.id &&
            controller.state.audioTracks.length == 2
        ? controller.state
        : await controller.states
              .firstWhere(
                (state) =>
                    state.sessionId == session.id &&
                    state.audioTracks.length == 2,
              )
              .timeout(const Duration(seconds: 5));
    expect(trackState.sessionId, session.id);
    expect(trackState.audioTracks, hasLength(2));
    final secondTrack = trackState.audioTracks[1];
    await sessionFor(controller).selectAudioTrack(secondTrack.id);
    final switched = await controller.states
        .firstWhere(
          (state) => state.audioTracks.any(
            (track) => track.id == secondTrack.id && track.isSelected,
          ),
        )
        .timeout(const Duration(seconds: 5));
    expect(switched.engine, YlPlaybackEngine.managedFallback);
  });
}
