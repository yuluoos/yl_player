import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/fake_player_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'public selection renders DASH cues; subsequent subtitle error preserves video',
    () async {
      final dir = await Directory.systemTemp.createTemp('yl-dash-subtitle-');
      addTearDown(() => dir.delete(recursive: true));
      final root = await File('${dir.path}/root.mpd').writeAsString(
        '''<MPD mediaPresentationDuration="PT6S"><Period duration="PT6S"><AdaptationSet mimeType="text/vtt"><Representation id="en"><SegmentTemplate duration="2" media="s-\$Number\$.vtt"/></Representation></AdaptationSet></Period></MPD>''',
      );
      for (final n in [1, 2]) {
        await File('${dir.path}/s-$n.vtt').writeAsString(
          'WEBVTT\n\n00:00:0${(n - 1) * 2}.000 --> 00:00:0${n * 2}.000\nowned $n\n',
        );
      }
      await File('${dir.path}/s-3.vtt').writeAsString('damaged');
      final backend = FakePlatformPlayer();
      final player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
        enableTextSubtitles: true,
      );
      addTearDown(player.dispose);
      const id = YlPlaybackSessionId('dash-subtitle');
      final pending = player.load(YlFileSource(root.path));
      backend.commit(id);
      final session = await pending;
      await session.discoverEmbeddedSubtitles();
      await session.selectSubtitleTrack(
        player.state.subtitles.tracks.single.id,
      );
      void position(int seconds) => backend.emitState(
        backend.state.copyWith(
          revision: backend.state.revision + 1,
          status: YlPlaybackStatus.playing,
          timeline: YlTimeline(position: Duration(seconds: seconds)),
        ),
      );
      position(1);
      backend.emitFirstFrame(id);
      expect(player.textSubtitleCues.single.text.toPlainText(), 'owned 1');
      final event = player.events
          .where((e) => e is YlPlaybackFailedEvent)
          .cast<YlPlaybackFailedEvent>()
          .first;
      position(3);
      final failed = await event.timeout(const Duration(seconds: 3));
      expect(failed.failure.scope, YlFailureScope.command);
      expect(failed.failure.code, YlFailureCodes.subtitleMalformed);
      expect(player.state.status, YlPlaybackStatus.playing);
      expect(player.state.failure, isNull);
      expect(player.state.timeline.position, const Duration(seconds: 3));
      expect(player.isCurrentFramePresented, isTrue);
      expect(player.textSubtitleCues, isEmpty);
    },
  );
}
