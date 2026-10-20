import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/text_subtitle_overlay.dart';
import '../../test/support/ass_fixture.dart';
import '../../test/support/pgs_fixture.dart';
import '../../test/support/vobsub_fixture.dart';
import 'apple_dash_audio_tracks_test.dart' show audioManifest;
import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';

// Automated state/clock assertions are distinct from the observer's sound and
// screen report. No physical A/V synchronization claim is made by this test.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('P02 physical observation: audio identity and subtitle lifecycle', (
    tester,
  ) async {
    final stage = ValueNotifier<String>('准备 P02 测试');
    addTearDown(stage.dispose);
    final mounted = ValueNotifier<bool>(true);
    addTearDown(mounted.dispose);
    final player = await YlPlayerController.create(
      enableTextSubtitles: true,
      options: const YlPlayerOptions(audioPolicy: YlAudioPolicy.appManaged),
    );
    addTearDown(player.dispose);
    addTearDown(() => runApp(const SizedBox.shrink()));
    final failures = <YlPlaybackFailedEvent>[];
    final subscription = player.events
        .where((e) => e is YlPlaybackFailedEvent)
        .cast<YlPlaybackFailedEvent>()
        .listen(failures.add);
    addTearDown(subscription.cancel);
    final directory = await Directory.systemTemp.createTemp('p02-device-');
    addTearDown(() => directory.delete(recursive: true));
    final server = await DashServer.start(
      manifestOverride: await audioManifest(),
    );
    addTearDown(server.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Column(
              children: [
                ValueListenableBuilder<String>(
                  valueListenable: stage,
                  builder: (_, text, _) => Text(
                    text,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 22),
                  ),
                ),
                Expanded(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: mounted,
                    builder: (_, visible, _) => visible
                        ? YlPlayerView(controller: player)
                        : const Center(
                            child: Text(
                              '视图已卸载',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    Future<void> show(String label, int seconds) async {
      debugPrint(
        'P02_DEVICE_STAGE ${jsonEncode({'stage': label, 'seconds': seconds})}',
      );
      const captureUrl = String.fromEnvironment('P01_CAPTURE_URL');
      if (captureUrl.isNotEmpty) {
        stage.value = '$label\n剩余 $seconds 秒';
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 3);
        try {
          final request = await client.getUrl(Uri.parse(captureUrl));
          final response = await request.close().timeout(
            const Duration(seconds: 12),
          );
          expect(response.statusCode, 200);
          await response.drain<void>();
        } finally {
          client.close(force: true);
        }
      }
      for (var remaining = seconds; remaining > 0; remaining--) {
        stage.value = '$label\n剩余 $remaining 秒';
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }

    Future<void> cue(bool visible) async {
      final timer = Stopwatch()..start();
      while ((find.byType(TextSubtitleOverlay).evaluate().isNotEmpty) !=
          visible) {
        if (timer.elapsed > const Duration(seconds: 5)) {
          fail('Cue visibility $visible did not settle');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    final audio = await player.load(
      YlNetworkSource(server.explicitUri, format: YlMediaFormat.dash),
    );
    await readyAndPlay(player, audio);
    await stateWhere(
      player,
      (s) =>
          s.audioTracks.length == 2 && s.audioTracks.any((t) => t.isSelected),
    );
    final tracks = player.state.audioTracks;
    expect(tracks.map((t) => t.id).toSet(), hasLength(2));
    final main = tracks.singleWhere((t) => !t.label!.contains('commentary'));
    final commentary = tracks.singleWhere(
      (t) => t.label!.contains('commentary'),
    );
    for (final track in [main, commentary, main]) {
      await audio.pause();
      await audio.seekTo(Duration.zero);
      await audio.selectAudioTrack(track.id);
      await stateWhere(
        player,
        (s) =>
            s.audioTracks.where((t) => t.isSelected).singleOrNull?.id ==
            track.id,
      );
      await audio.play();
      await show(track.id == main.id ? '音轨 A：低音 440 Hz' : '音轨 B：高音 660 Hz', 6);
      expect(
        player.state.timeline.position,
        greaterThan(const Duration(seconds: 4)),
      );
      expect(
        player.state.audioTracks.where((t) => t.isSelected).single.id,
        track.id,
      );
    }
    await audio.pause();
    await show('暂停：声音应停止', 3);
    await player.stop();
    final video = BytesBuilder();
    for (final name in [
      'init-0.m4s',
      for (var i = 1; i <= 4; i++)
        'chunk-0-${i.toString().padLeft(5, '0')}.m4s',
    ]) {
      final bytes = await rootBundle.load(
        'assets/test_media/dash_timeline/period0/$name',
      );
      video.add(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    }
    final media = video.takeBytes();
    final file = await File('${directory.path}/owned.mp4').writeAsBytes(media);
    final session = await player.load(YlFileSource(file.path));
    await readyAndPlay(player, session);
    await session.pause();
    for (final format in YlSubtitleFormat.values) {
      final bytes = switch (format) {
        YlSubtitleFormat.srt => utf8.encode(
          '1\n00:00:01,000 --> 00:00:03,000\nSRT 字幕 / SUBTITLE\n',
        ),
        YlSubtitleFormat.webvtt => utf8.encode(
          'WEBVTT\n\n00:01.000 --> 00:03.000\nWebVTT 字幕 / SUBTITLE\n',
        ),
        YlSubtitleFormat.ttml => utf8.encode(
          '<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="1s" end="3s">TTML 字幕 / SUBTITLE</p></div></body></tt>',
        ),
        YlSubtitleFormat.ass || YlSubtitleFormat.ssa => utf8.encode(
          assFixture(
            ssa: format == YlSubtitleFormat.ssa,
            wrap: '0',
            text: '${format.name} SUBTITLE',
          ).replaceAll('Ahem', 'sans-serif'),
        ),
        YlSubtitleFormat.pgs => pgsFixture(),
        YlSubtitleFormat.vobsub => vobSub(),
      };
      final subtitle = await File(
        '${directory.path}/${format.name}',
      ).writeAsBytes(bytes);
      final idx = await File('${directory.path}/pair.idx').writeAsString(
        vobIdxText().replaceFirst('ff0000, 00ff00', 'ff0000, 0000ff'),
      );
      await session.replaceExternalSubtitles([
        YlExternalSubtitle(
          id: 'owned',
          format: format,
          source: YlFileSource(subtitle.path),
          companionSource: format == YlSubtitleFormat.vobsub
              ? YlFileSource(idx.path)
              : null,
        ),
      ]);
      await session.seekTo(const Duration(milliseconds: 1500));
      await stateWhere(
        player,
        (s) => (s.timeline.position.inMilliseconds - 1500).abs() < 100,
      );
      await session.selectSubtitleTrack('owned');
      await cue(true);
      await show('${format.name}：显示字幕（PGS/VobSub 为左侧小色块）', 3);
      mounted.value = false;
      await cue(false);
      await show('${format.name}：卸载视图', 1);
      mounted.value = true;
      await cue(true);
      expect(player.state.sessionId, session.id);
      await show('${format.name}：同一播放器恢复字幕', 2);
      await session.selectSubtitleTrack(null);
      await cue(false);
      await show('${format.name}：关闭，字幕应消失', 2);
      await session.selectSubtitleTrack('owned');
      await session.setSubtitleOffset(const Duration(seconds: 2));
      await cue(false);
      await session.setSubtitleOffset(Duration.zero);
      await cue(true);
      await session.seekTo(Duration.zero);
      await stateWhere(
        player,
        (s) => s.timeline.position < const Duration(milliseconds: 100),
      );
      await cue(false);
      await session.play();
      await show('${format.name}：播放，字幕在 1–3 秒显示', 4);
      await cue(false);
      await session.pause();
      debugPrint(
        'P02_DEVICE_RESULT ${jsonEncode({'format': format.name, 'session': session.id.value, 'mediaSha256': sha256.convert(media).toString(), 'subtitleSha256': sha256.convert(bytes).toString(), 'platform': Platform.operatingSystem, 'os': Platform.operatingSystemVersion, 'automated': 'state, clock, subtitle publication and public-view remount; visual/audio observation is separate'})}',
      );
    }
    expect(failures, isEmpty);
    await player.stop();
    await show('P02 测试结束', 3);
  });
}
