import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'large exact clocks retain eight second program across boundary seeks and replacement',
    (tester) async {
      final server = await DashServer.start(timelineMarkers: true);
      final held = await DashServer.start(
        timelineMarkers: true,
        delayManifest: true,
      );
      addTearDown(server.close);
      addTearDown(held.close);
      final player = await appleController(tester);
      final events = <YlPlayerEvent>[];
      final subscription = player.events.listen(events.add);
      addTearDown(subscription.cancel);
      final session = await player.load(YlNetworkSource(server.automaticUri));
      await readyAndPlay(player, session);
      await stateWhere(
        player,
        (s) =>
            s.audioTracks.any((t) => t.isSelected) && s.videoGeometry != null,
      );
      expect(
        (player.state.timeline.duration! - const Duration(seconds: 8))
            .inMilliseconds
            .abs(),
        lessThanOrEqualTo(50),
      );
      for (final millis in [3800, 4000, 4200, 500]) {
        await session.pause();
        await session.seekTo(Duration(milliseconds: millis));
        await stateWhere(
          player,
          (s) => (s.timeline.position.inMilliseconds - millis).abs() <= 100,
        );
        await session.play();
        await stateWhere(
          player,
          (s) =>
              s.timeline.position.inMilliseconds > millis + 200 &&
              s.audioTracks.any((t) => t.isSelected),
        );
        expect(player.state.sessionId, session.id);
        expect(player.state.failure, isNull);
      }
      await session.pause();
      final cancelled = expectLater(
        player.load(YlNetworkSource(held.automaticUri)),
        failureCode(YlFailureCodes.loadCancelled),
      );
      await held.manifestEntered.timeout(const Duration(seconds: 5));
      final eventBoundary = events.length;
      final replacement = await player.load(
        YlNetworkSource(server.automaticUri),
      );
      await readyAndPlay(player, replacement);
      await cancelled;
      held.releaseDelayedManifest();
      await held.settle();
      await stateWhere(
        player,
        (s) => s.timeline.position > const Duration(milliseconds: 400),
      );
      expect(player.state.sessionId, replacement.id);
      expect(
        events.skip(eventBoundary).every((e) => e.sessionId == replacement.id),
        isTrue,
      );
      expect(held.childRequests, isEmpty);
      for (final period in [0, 1]) {
        expect(
          server.childRequests.any((r) => r.path.startsWith('/period$period/')),
          isTrue,
        );
      }
    },
  );

  testWidgets(
    'seven unsupported timeline dimensions fail before media and preserve active session',
    (tester) async {
      final server = await DashServer.start(timelineMarkers: true);
      addTearDown(server.close);
      final player = await appleController(tester);
      final session = await player.load(YlNetworkSource(server.automaticUri));
      await readyAndPlay(player, session);
      await session.pause();
      final matrix =
          jsonDecode(
                await rootBundle.loadString(
                  'assets/test_media/dash_timeline/matrix.json',
                ),
              )
              as List;
      expect(matrix, hasLength(7));
      for (final row in matrix.cast<Map<String, dynamic>>()) {
        final mpd = await rootBundle.loadString(
          'assets/test_media/dash_timeline/${row['mpd']}',
        );
        final candidate = await DashServer.start(
          timelineMarkers: true,
          manifestOverride: mpd,
        );
        try {
          await expectLater(
            player.load(YlNetworkSource(candidate.automaticUri)),
            failureCode(YlFailureCodes.containerUnsupported),
            reason: row['id'] as String,
          );
          expect(candidate.childRequests, isEmpty, reason: row['id'] as String);
          expect(player.state.sessionId, session.id);
          expect(player.state.failure, isNull);
        } finally {
          await candidate.close();
        }
      }
      final before = player.state.timeline.position;
      await session.play();
      await stateWhere(
        player,
        (s) => s.timeline.position > before + const Duration(milliseconds: 200),
      );
    },
  );
}
