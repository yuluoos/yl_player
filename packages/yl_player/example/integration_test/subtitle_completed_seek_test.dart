import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'paused seek after completion restores current subtitle and remains paused',
    (tester) async {
      final dir = await Directory.systemTemp.createTemp('p02-completed-seek-');
      addTearDown(() => dir.delete(recursive: true));
      final bytes = BytesBuilder();
      for (final name in [
        'init-0.m4s',
        for (var i = 1; i <= 4; i++)
          'chunk-0-${i.toString().padLeft(5, '0')}.m4s',
      ]) {
        final data = await rootBundle.load(
          'assets/test_media/dash_timeline/period0/$name',
        );
        bytes.add(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      }
      final video = await File(
        '${dir.path}/owned.mp4',
      ).writeAsBytes(bytes.takeBytes());
      final subtitle = await File(
        '${dir.path}/owned.srt',
      ).writeAsString('1\n00:00:01,000 --> 00:00:03,000\nRESTORED CUE\n');
      final player = await YlPlayerController.create(
        enableTextSubtitles: true,
        options: const YlPlayerOptions(audioPolicy: YlAudioPolicy.appManaged),
      );
      addTearDown(player.dispose);
      addTearDown(() => runApp(const SizedBox.shrink()));
      await tester.pumpWidget(
        MaterialApp(home: YlPlayerView(controller: player)),
      );
      final session = await player.load(YlFileSource(video.path));
      await readyAndPlay(player, session);
      await session.replaceExternalSubtitles([
        YlExternalSubtitle(
          id: 'owned',
          format: YlSubtitleFormat.srt,
          source: YlFileSource(subtitle.path),
        ),
      ]);
      await session.selectSubtitleTrack('owned');
      await stateWhere(player, (s) => s.status == YlPlaybackStatus.completed);
      await session.pause();
      await session.seekTo(const Duration(seconds: 4));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        player.state.status,
        YlPlaybackStatus.completed,
        reason: 'Seeking to EOF must not manufacture an interior landing.',
      );
      await session.seekTo(const Duration(milliseconds: 1500));
      await stateWhere(
        player,
        (s) => (s.timeline.position.inMilliseconds - 1500).abs() < 100,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      debugPrint(
        'P02_COMPLETED_SEEK status=${player.state.status.name} positionMs=${player.state.timeline.position.inMilliseconds} firstFrame=${player.isCurrentFramePresented} visibleCues=${find.text('RESTORED CUE', findRichText: true).evaluate().length}',
      );
      expect(player.state.status, YlPlaybackStatus.paused);
      expect(find.text('RESTORED CUE', findRichText: true), findsOneWidget);
      final position = player.state.timeline.position;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(
        (player.state.timeline.position - position).abs(),
        lessThan(const Duration(milliseconds: 100)),
      );
      expect(player.state.sessionId, session.id);
      expect(player.state.failure, isNull);
    },
  );
}
