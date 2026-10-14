import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final replace in [false, true]) {
    testWidgets(
      'DASH delayed reconfiguration ${replace ? 'replacement' : 'stop'} rejects late output',
      (tester) async {
        final manifest = await rootBundle.loadString(
          'assets/test_media/dash_timeline/cross-codec.mpd',
        );
        final delayed = await DashServer.start(
          timelineMarkers: true,
          manifestOverride: manifest,
          delayedMediaPrefix: '/hevc/',
        );
        addTearDown(delayed.close);
        final next = await DashServer.start(
          timelineMarkers: true,
          manifestOverride: await rootBundle.loadString(
            'assets/test_media/dash_timeline/independent-pto.mpd',
          ),
        );
        addTearDown(next.close);
        final player = await appleController(tester);
        final session = await player.load(
          YlNetworkSource(
            delayed.automaticUri,
            format: YlMediaFormat.dash,
            networkPolicy: strictNetwork,
          ),
        );
        await readyAndPlay(player, session);
        await session.pause();
        Object? seekError;
        final seeking = session
            .seekTo(const Duration(milliseconds: 2000))
            .catchError((Object error) {
              seekError = error;
            });
        await delayed.mediaEntered.timeout(const Duration(seconds: 10));
        final YlPlaybackSession? replacement;
        if (replace) {
          replacement = await player.load(
            YlNetworkSource(
              next.automaticUri,
              format: YlMediaFormat.dash,
              networkPolicy: strictNetwork,
            ),
          );
          await readyAndPlay(player, replacement);
        } else {
          replacement = null;
          await player.stop();
        }
        final after = <YlPlayerEvent>[];
        final subscription = player.events.listen(after.add);
        addTearDown(subscription.cancel);
        delayed.releaseDelayedMedia();
        await seeking.timeout(const Duration(seconds: 5));
        if (seekError != null) expect(seekError, isA<YlPlayerException>());
        await delayed.settle();
        await tester.pump(const Duration(milliseconds: 500));
        expect(after.where((e) => e.sessionId == session.id), isEmpty);
        expect(player.state.failure, isNull);
        if (replacement != null) {
          expect(player.state.sessionId, replacement.id);
          await stateWhere(
            player,
            (s) => s.timeline.position.inMilliseconds >= 500,
          );
          expect(player.state.videoGeometry?.encodedSize.width, 320);
          await player.stop();
        } else {
          await stateWhere(player, (s) => s.status == YlPlaybackStatus.idle);
          expect(player.state.sessionId, isNull);
        }
        await expectLater(
          session.play(),
          failureCode(YlFailureCodes.sessionStale),
        );
        await player.dispose();
        await player.dispose();
      },
    );
  }
}
