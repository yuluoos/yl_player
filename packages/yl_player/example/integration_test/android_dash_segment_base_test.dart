import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final version in [0, 1]) {
    testWidgets(
      'Android SegmentBase v$version plays the same owned AVC/AAC fixture',
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
        for (final millis in [2200, 500]) {
          await session.pause();
          await session.seekTo(Duration(milliseconds: millis));
          await session.play();
          await stateWhere(
            player,
            (s) =>
                s.timeline.position.inMilliseconds > millis + 350 &&
                s.timeline.position.inMilliseconds < millis + 1500 &&
                s.audioTracks.any((t) => t.isSelected),
          );
          expect(player.state.sessionId, session.id);
          expect(player.state.failure, isNull);
        }
        final ranges = RegExp(
          r'indexRange="([0-9]+)-([0-9]+)"',
        ).allMatches(server.manifestsServed.first).toList();
        expect(ranges, hasLength(2));
        for (var track = 0; track < 2; track++) {
          final requests = server.childRequests
              .where((r) => r.path.endsWith('indexed-$track.mp4'))
              .toList();
          expect(requests, isNotEmpty);
          final start = int.parse(ranges[track].group(1)!);
          final end = int.parse(ranges[track].group(2)!);
          // Media3 can combine adjacent init/index ranges into one bounded read.
          expect(
            requests.any((r) {
              final m = RegExp(
                r'^bytes=(\d+)-(\d+)$',
              ).firstMatch(r.header('range') ?? '');
              return m != null &&
                  int.parse(m.group(1)!) <= start &&
                  int.parse(m.group(2)!) >= end;
            }),
            isTrue,
          );
          expect(
            requests.any(
              (r) =>
                  r.header('range')?.startsWith('bytes=${end + 1}-') ?? false,
            ),
            isTrue,
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
      },
    );
  }
}
