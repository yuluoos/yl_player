import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'compatible DASH ladder renders across reordered Periods and seeks',
    (tester) async {
      final server = await DashServer.start(variants: true);
      addTearDown(server.close);
      final player = await appleController(tester);
      final events = <YlPlayerEvent>[];
      final eventSubscription = player.events.listen(events.add);
      addTearDown(eventSubscription.cancel);
      final session = await player.load(
        YlNetworkSource(server.automaticUri, format: YlMediaFormat.dash),
      );
      final positions = <Duration>[];
      final stateSubscription = player.states.listen((state) {
        if (state.sessionId == session.id) {
          positions.add(state.timeline.position);
        }
      });
      addTearDown(stateSubscription.cancel);
      await readyAndPlay(player, session);
      expect(
        events.whereType<YlFirstFrameEvent>().any(
          (e) => e.sessionId == session.id,
        ),
        isTrue,
      );
      expect(player.state.engine, YlPlaybackEngine.avPlayer);
      final observedSizes = <String>{};
      void recordSize() {
        final size = player.state.videoGeometry?.displaySize;
        expect(size, isNotNull);
        expect([320, 640], contains(size!.width.round()));
        expect([180, 360], contains(size.height.round()));
        observedSizes.add('${size.width.round()}x${size.height.round()}');
      }

      recordSize();
      expect(player.state.audioTracks.any((track) => track.isSelected), isTrue);
      expect(
        (player.state.timeline.duration! - const Duration(seconds: 8))
            .inMilliseconds
            .abs(),
        lessThanOrEqualTo(50),
      );
      await stateWhere(
        player,
        (s) => s.timeline.position > const Duration(milliseconds: 4500),
      );
      recordSize();
      await stateSubscription.cancel();
      expect(
        positions.any((position) => position < const Duration(seconds: 4)),
        isTrue,
      );
      for (var i = 1; i < positions.length; i++) {
        expect(positions[i], greaterThanOrEqualTo(positions[i - 1]));
      }
      for (final second in [5, 1]) {
        await session.pause();
        await session.seekTo(Duration(seconds: second));
        await stateWhere(
          player,
          (s) =>
              (s.timeline.position - Duration(seconds: second)).inMilliseconds
                  .abs() <=
              300,
        );
        await session.play();
        await stateWhere(
          player,
          (s) =>
              s.timeline.position > Duration(milliseconds: second * 1000 + 500),
        );
        recordSize();
      }
      await stateWhere(player, (s) => s.status == YlPlaybackStatus.completed);
      expect(
        player.state.timeline.position,
        greaterThanOrEqualTo(const Duration(milliseconds: 7500)),
      );
      final requested = <String>[];
      for (final period in [0, 1]) {
        final videoTracks = [
          for (final track in [0, 1])
            if (server.childRequests.any(
                  (r) => r.path == '/period$period/init-$track.m4s',
                ) &&
                server.childRequests.any(
                  (r) => r.path.startsWith('/period$period/chunk-$track-'),
                ))
              track,
        ];
        expect(
          videoTracks,
          isNotEmpty,
          reason: 'Playable video in Period $period',
        );
        expect(
          server.childRequests.any(
            (r) => r.path == '/period$period/init-2.m4s',
          ),
          isTrue,
        );
        expect(
          server.childRequests.any(
            (r) => r.path.startsWith('/period$period/chunk-2-'),
          ),
          isTrue,
        );
        requested.add('period$period=$videoTracks');
      }
      expect(events.whereType<YlPlaybackFailedEvent>(), isEmpty);
      debugPrint(
        'DASH variants: firstFrame; sizes=$observedSizes; requested video $requested; natural=${positions.first.inMilliseconds}..${positions.last.inMilliseconds}ms; seek5>5.5 seek1>1.5 completed=${player.state.timeline.position.inMilliseconds}ms; shared audio both Periods. Requests are not proof of ABR switching.',
      );
    },
  );
}
