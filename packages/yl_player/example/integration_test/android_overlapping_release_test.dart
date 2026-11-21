import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/range_media_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'stopping and reopening overlapping video sessions releases their codecs',
    (tester) async {
      final server = await RangeMediaServer.start(
        asset: 'assets/test_media/network_seek_h264_aac.mkv',
      );
      addTearDown(server.close);
      final source = YlNetworkSource(
        server.mediaUri,
        format: YlMediaFormat.matroska,
      );
      const options = YlPlayerOptions(audioPolicy: YlAudioPolicy.appManaged);
      final first = await YlPlayerController.create(options: options);
      addTearDown(first.dispose);
      final second = await YlPlayerController.create(options: options);
      addTearDown(second.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            children: [
              Expanded(child: YlPlayerView(controller: first)),
              Expanded(child: YlPlayerView(controller: second)),
            ],
          ),
        ),
      );

      // Keep each phase observable to the host's process-scoped codec sampler.
      Future<void> observe(String phase) async {
        debugPrint('YL_FOLLOWUP_RESOURCE=$phase');
        await Future<void>.delayed(const Duration(seconds: 3));
      }

      Future<YlPlaybackSession> start(YlPlayerController player) async {
        final session = await player.load(source);
        await readyAndPlay(player, session);
        return session;
      }

      // Android rejects an explicit byte ceiling before activating a session.
      await expectLater(
        first.load(
          source,
          options: const YlLoadOptions(bufferStrategy: strictBuffer),
        ),
        failureCode(YlFailureCodes.policyUnsupported),
      );
      expect(first.state.sessionId, isNull);
      await observe('idle');
      final old = await start(first);
      final peer = await start(second);
      await observe('both');
      await first.stop();
      await stateWhere(first, (s) => s.status == YlPlaybackStatus.idle);
      await expectLater(old.play(), failureCode(YlFailureCodes.sessionStale));
      await peer.seekTo(Duration.zero);
      await peer.play();
      await stateWhere(
        second,
        (s) =>
            s.status == YlPlaybackStatus.playing &&
            s.timeline.position > const Duration(milliseconds: 300),
      );
      await observe('peer');
      final reopened = await start(first);
      expect(reopened.id, isNot(old.id));
      expect(second.state.sessionId, peer.id);
      await observe('reopened');
      await first.stop();
      await second.stop();
      await stateWhere(first, (s) => s.status == YlPlaybackStatus.idle);
      await stateWhere(second, (s) => s.status == YlPlaybackStatus.idle);
      await observe('stopped');
    },
  );
}
