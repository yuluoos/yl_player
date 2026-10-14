import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';

/// Same owned media and public expectations on Android, iOS and macOS.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const cases = <String, int>{
    'independent-pto': 4000,
    'clip-end': 3500,
    'gap': 9000,
    'overlap': 7000,
    'unknown-middle': 8000,
    'multiple-base': 4000,
    'fractional-microsecond': 334,
    'cross-codec': 3000,
    'resolution': 3000,
    'audio-added': 3000,
    'absolute-base': 4000,
    'absolute-list': 4000,
  };
  testWidgets('managed DASH fixed AVC disappears and HEVC can be fixed', (
    tester,
  ) async {
    // The owned encoder is 24 fps; hvcC is Main, compatibility 6, level 63, constraints 90.
    // Fixed selection needs authoritative metadata for the device frame-rate envelope.
    final manifest =
        (await rootBundle.loadString(
              'assets/test_media/dash_timeline/cross-codec.mpd',
            ))
            .replaceAll(' width=', ' frameRate="24" width=')
            .replaceAll('codecs="hvc1"', 'codecs="hvc1.1.6.L63.90"');
    final server = await DashServer.start(
      timelineMarkers: true,
      manifestOverride: manifest,
    );
    addTearDown(server.close);
    final player = await appleController(tester);
    final session = await player.load(
      YlNetworkSource(server.automaticUri, networkPolicy: strictNetwork),
    );
    await session.ready.timeout(const Duration(seconds: 15));
    await stateWhere(player, (s) => s.videoTracks.isNotEmpty);
    await session.selectVideoTrack(player.state.videoTracks.first.id);
    await readyAndPlay(player, session);
    await stateWhere(
      player,
      (s) =>
          s.timeline.position.inMilliseconds >= 1800 &&
          s.videoGeometry?.encodedSize.width == 640,
    );
    expect(
      player.state.videoSelection.reason,
      YlVideoSelectionReason.trackUnavailable,
    );
    await session.pause();
    await session.selectVideoTrack(player.state.videoTracks.first.id);
    expect(player.state.videoSelection.isAutomatic, isFalse);
    await session.seekTo(const Duration(milliseconds: 2100));
    await session.play();
    await stateWhere(player, (s) => s.timeline.position.inMilliseconds >= 2300);
    expect(player.state.videoSelection.isAutomatic, isFalse);
    expect(player.state.videoGeometry?.encodedSize.width, 640);
    await session.pause();
    await session.seekTo(const Duration(milliseconds: 500));
    await session.play();
    await stateWhere(
      player,
      (s) =>
          s.timeline.position.inMilliseconds >= 700 &&
          s.timeline.position.inMilliseconds < 1500,
    );
    expect(
      player.state.videoSelection.reason,
      YlVideoSelectionReason.trackUnavailable,
    );
    expect(player.state.failure, isNull);
    await player.stop();
  });
  for (final entry in cases.entries) {
    testWidgets('managed DASH programme ${entry.key}', (tester) async {
      final manifest = await rootBundle.loadString(
        'assets/test_media/dash_timeline/${entry.key}.mpd',
      );
      final server = await DashServer.start(
        timelineMarkers: true,
        manifestOverride: manifest,
      );
      addTearDown(server.close);
      final player = await appleController(tester);
      final observed = <YlPlayerState>[];
      final subscription = player.states.listen(observed.add);
      addTearDown(subscription.cancel);
      final session = await player.load(
        YlNetworkSource(server.automaticUri, networkPolicy: strictNetwork),
      );
      final watch = Stopwatch()..start();
      if (entry.key == 'gap') {
        final ready = await stateWhere(player, (s) => s.audioTracks.isNotEmpty);
        await session.selectAudioTrack(ready.audioTracks.first.id);
      }
      await readyAndPlay(player, session);
      final completed = await stateWhere(
        player,
        (s) => s.status == YlPlaybackStatus.completed,
      );
      expect(completed.failure, isNull);
      expect(completed.sessionId, session.id);
      expect(
        (completed.timeline.duration!.inMilliseconds - entry.value).abs(),
        lessThanOrEqualTo(2),
      );
      expect(
        (completed.timeline.position.inMilliseconds - entry.value).abs(),
        lessThanOrEqualTo(50),
      );
      expect(
        watch.elapsedMilliseconds,
        greaterThanOrEqualTo(entry.value - 180),
      );
      if (entry.key == 'gap') {
        expect(
          observed.any(
            (s) =>
                s.timeline.position.inMilliseconds >= 4200 &&
                s.timeline.position.inMilliseconds <= 4800 &&
                s.videoGeometry == null,
          ),
          isTrue,
          reason: 'The declared blank interval must hide the previous picture.',
        );
      }
      if (entry.key == 'cross-codec' || entry.key == 'resolution') {
        expect(
          observed.any((s) => s.videoGeometry?.encodedSize.width == 640),
          isTrue,
        );
      }
      if (entry.key == 'audio-added') {
        expect(completed.audioTracks, hasLength(2));
        final initial = observed.firstWhere(
          (s) => s.audioTracks.any((t) => t.isSelected),
        );
        expect(
          completed.audioTracks.singleWhere((t) => t.isSelected).id,
          initial.audioTracks.singleWhere((t) => t.isSelected).id,
        );
      }
      if (entry.value > 1000) {
        await session.pause();
        await session.seekTo(const Duration(milliseconds: 500));
        await session.play();
        await stateWhere(
          player,
          (s) =>
              s.status == YlPlaybackStatus.playing &&
              s.timeline.position.inMilliseconds >= 650 &&
              s.timeline.position.inMilliseconds < 1500,
        );
        expect(player.state.failure, isNull);
      }
      await player.stop();
      expect(player.state.status, YlPlaybackStatus.idle);
    });
  }
}
