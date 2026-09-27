import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final version in [0, 1]) {
    testWidgets(
      'SegmentBase v$version AVC/AAC plays and seeks with exact index ranges',
      (tester) async {
        final cross = version == 1;
        final server = await DashServer.start(
          segmentBaseVersion: version,
          originMode: cross
              ? DashOriginMode.returnToPrimary
              : DashOriginMode.sameOrigin,
        );
        addTearDown(server.close);
        final player = await appleController(tester);
        final states = <YlPlayerState>[];
        final subscription = player.states.listen(states.add);
        addTearDown(subscription.cancel);
        final session = await player.load(
          YlNetworkSource(
            server.explicitUri,
            format: YlMediaFormat.dash,
            request: YlHttpRequest(
              headers: const {'X-Dash-Client': 'ordinary'},
              credentials: const {
                'Authorization': 'Bearer owned-test',
                'Cookie': 'owned=test',
              },
            ),
          ),
        );
        await readyAndPlay(player, session);
        await stateWhere(
          player,
          (s) =>
              s.timeline.position > const Duration(milliseconds: 600) &&
              s.audioTracks.any((t) => t.isSelected) &&
              s.videoGeometry != null,
        );
        expect(
          (player.state.timeline.duration! - const Duration(seconds: 4))
              .inMilliseconds
              .abs(),
          lessThanOrEqualTo(50),
        );
        for (var n = 1; n < states.length; n++) {
          if (states[n].sessionId == session.id &&
              states[n - 1].sessionId == session.id) {
            expect(
              states[n].timeline.position,
              greaterThanOrEqualTo(states[n - 1].timeline.position),
            );
          }
        }
        await session.pause();
        // Runtime projection must reuse the accepted index snapshot.
        final ranges = RegExp(r'indexRange="([0-9]+-[0-9]+)"')
            .allMatches(server.manifestsServed.first)
            .map((m) => 'bytes=${m.group(1)}')
            .toList();
        expect(ranges, hasLength(2));
        List<int> indexCounts() => [
          for (final range in ranges)
            server.childRequests
                .where((r) => r.header('range') == range)
                .length,
        ];
        final before = indexCounts();
        expect(before, [1, 1]);
        await session.setVideoConstraints(
          const YlVideoConstraints(maxWidth: 320, maxHeight: 180),
        );
        for (final millis in [2200, 500]) {
          await session.seekTo(Duration(milliseconds: millis));
          await stateWhere(
            player,
            (s) => (s.timeline.position.inMilliseconds - millis).abs() <= 250,
          );
          await session.play();
          await stateWhere(
            player,
            (s) =>
                s.timeline.position.inMilliseconds > millis + 350 &&
                s.audioTracks.any((t) => t.isSelected),
          );
          await session.pause();
          expect(player.state.sessionId, session.id);
          expect(player.state.failure, isNull);
        }
        expect(indexCounts(), before);
        for (final range in ranges) {
          expect(
            server.childRequests.where((r) => r.header('range') == range),
            isNotEmpty,
          );
        }
        for (final request in server.childRequests) {
          expect(request.header('x-dash-client'), 'ordinary');
          expect(
            request.header('authorization'),
            cross ? isNull : 'Bearer owned-test',
          );
          expect(request.header('cookie'), cross ? isNull : 'owned=test');
        }
        expect(
          server.childRequests.any(
            (r) => r.header('range')?.startsWith('bytes=0-') ?? false,
          ),
          isTrue,
        );
        expect(
          server.childRequests.any(
            (r) =>
                r
                    .header('range')
                    ?.startsWith('bytes=${version == 0 ? 906 : 914}-') ??
                false,
          ),
          isTrue,
        );
      },
    );
  }
}
