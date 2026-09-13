import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/android_test_support.dart';
import 'support/authenticated_hls_server.dart';
import 'support/range_media_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('FFmpeg demuxes and software decodes unsupported HEVC Main10', (
    tester,
  ) async {
    final server = await RangeMediaServer.start(
      asset: 'assets/test_media/hevc_main10_level62_aac.mkv',
    );
    addTearDown(server.close);
    final player = await YlPlayerController.create(
      options: const YlPlayerOptions(
        decoderPolicy: YlDecoderPolicy.hardwarePreferred,
        audioPolicy: YlAudioPolicy.pluginManagedMediaPlayback,
      ),
    );
    addTearDown(player.dispose);
    expect(
      player.capabilities.availableEngines,
      contains(YlPlaybackEngine.managedFallback),
    );
    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: player)),
    );

    final session = await player.load(
      YlNetworkSource(server.mediaUri, format: YlMediaFormat.matroska),
    );
    await session.play();
    await session.ready.timeout(const Duration(seconds: 20));
    await session.firstFrame.timeout(const Duration(seconds: 20));
    await waitForState(
      player,
      (state) =>
          state.engine == YlPlaybackEngine.managedFallback &&
          state.decoderMode == YlDecoderMode.software,
    );
    final fallback = player.state;

    expect(fallback.videoGeometry?.encodedSize.width, 640);
    expect(fallback.videoGeometry?.encodedSize.height, 360);
    expect(fallback.audioTracks, isNotEmpty);
    expect(fallback.failure, isNull);
  });

  testWidgets('FFmpeg demuxes HEVC FLV packets into MediaCodec hardware', (
    tester,
  ) async {
    final server = await RangeMediaServer.start(
      asset: 'assets/test_media/hevc_aac.flv',
    );
    addTearDown(server.close);
    final player = await YlPlayerController.create();
    addTearDown(player.dispose);
    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: player)),
    );

    final session = await player.load(
      YlNetworkSource(server.mediaUri, format: YlMediaFormat.flv),
    );
    await session.play();
    await session.ready.timeout(const Duration(seconds: 20));
    await session.firstFrame.timeout(const Duration(seconds: 20));
    await waitForState(
      player,
      (state) =>
          state.engine == YlPlaybackEngine.managedFallback &&
          state.decoderMode == YlDecoderMode.hardware,
    );

    expect(player.state.videoGeometry?.encodedSize.width, 320);
    expect(player.state.audioTracks, isNotEmpty);
    expect(player.state.failure, isNull);
  });

  testWidgets('FFmpeg fallback preserves AAC audio from MP4', (tester) async {
    final server = await RangeMediaServer.start(
      asset: 'assets/test_media/hevc_main10_level62_aac.mp4',
    );
    addTearDown(server.close);
    final player = await YlPlayerController.create();
    addTearDown(player.dispose);
    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: player)),
    );

    final session = await player.load(
      YlNetworkSource(server.mediaUri, format: YlMediaFormat.mp4),
    );
    await session.play();
    await session.ready.timeout(const Duration(seconds: 20));
    await session.firstFrame.timeout(const Duration(seconds: 20));
    await waitForState(
      player,
      (state) =>
          state.engine == YlPlaybackEngine.managedFallback &&
          state.decoderMode == YlDecoderMode.software &&
          state.audioTracks.any((track) => track.isSelected),
    );

    expect(player.state.audioTracks.single.codec, 'aac');
    expect(player.state.failure, isNull);
  });

  testWidgets('native HLS decrypts AES-128 and software decodes Main10', (
    tester,
  ) async {
    final server = await AuthenticatedHlsServer.start(
      sameOrigin: true,
      segmentAsset: 'assets/test_media/hls_main10_encrypted_segment0.ts',
      codecs: 'hvc1.2.6.L186.B0,mp4a.40.2',
      durationSeconds: 3,
    );
    addTearDown(server.close);
    final player = await YlPlayerController.create();
    addTearDown(player.dispose);
    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: player)),
    );

    final session = await player.load(
      YlNetworkSource(
        server.masterUri,
        format: YlMediaFormat.hls,
        request: YlHttpRequest(
          headers: const {'X-Client': 'yl-player-native-hls'},
          credentials: const {'Authorization': 'Bearer fixture-only'},
        ),
      ),
    );
    await session.play();
    await session.ready.timeout(const Duration(seconds: 20));
    await session.firstFrame.timeout(const Duration(seconds: 20));
    await waitForState(
      player,
      (state) =>
          state.engine == YlPlaybackEngine.managedFallback &&
          state.decoderMode == YlDecoderMode.software,
    );

    expect(server.requestsFor('/key.bin'), isNotEmpty);
    expect(server.requestsFor('/segment0.ts'), isNotEmpty);
    expect(player.state.timeline.isSeekable, isTrue);
    expect(
      server
          .requestsFor('/segment0.ts')
          .every(
            (request) =>
                request.header('authorization') == 'Bearer fixture-only',
          ),
      isTrue,
    );
    expect(player.state.failure, isNull);
  });

  testWidgets('native live HLS starts at the live window and seeks to edge', (
    tester,
  ) async {
    final server = await AuthenticatedHlsServer.start(
      sameOrigin: true,
      segmentAsset: 'assets/test_media/hls_main10_encrypted_segment0.ts',
      codecs: 'hvc1.2.6.L186.B0,mp4a.40.2',
      isLive: true,
      durationSeconds: 3,
    );
    addTearDown(server.close);
    final player = await YlPlayerController.create();
    addTearDown(player.dispose);
    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: player)),
    );

    final session = await player.load(
      YlNetworkSource(
        server.masterUri,
        intent: YlStreamIntent.live,
        format: YlMediaFormat.hls,
      ),
    );
    await session.play();
    await session.ready.timeout(const Duration(seconds: 20));
    await session.firstFrame.timeout(const Duration(seconds: 20));
    await waitForState(
      player,
      (state) =>
          state.engine == YlPlaybackEngine.managedFallback &&
          state.timeline.isLive,
    );
    await session.seekToLiveEdge().timeout(const Duration(seconds: 10));

    expect(player.state.failure, isNull);
    expect(server.requestsFor('/media.m3u8').length, greaterThanOrEqualTo(2));
  });
}
