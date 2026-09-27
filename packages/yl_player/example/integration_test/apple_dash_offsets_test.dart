import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';

const _high = 'dash-video-w640-h360-b700000';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final list in [false, true]) {
    testWidgets(
      'shifted DASH ${list ? 'SegmentList' : r'$Time$'} preserves program time and selection',
      (tester) async {
        final server = await DashServer.start(
          presentationOffsets: true,
          offsetSegmentList: list,
        );
        addTearDown(server.close);
        final player = await appleController(tester);
        final states = <YlPlayerState>[];
        final events = <YlPlayerEvent>[];
        final subscription = player.states.listen(states.add);
        final eventSubscription = player.events.listen(events.add);
        addTearDown(subscription.cancel);
        addTearDown(eventSubscription.cancel);
        final session = await player.load(
          YlNetworkSource(
            list ? server.automaticUri : server.explicitUri,
            format: list ? YlMediaFormat.automatic : YlMediaFormat.dash,
          ),
        );
        await readyAndPlay(player, session);
        expect(
          player.state.timeline.position,
          lessThan(const Duration(seconds: 1)),
        );
        expect(
          (player.state.timeline.duration! - const Duration(seconds: 8))
              .inMilliseconds
              .abs(),
          lessThanOrEqualTo(50),
        );
        await session.pause();
        await session.selectVideoTrack(_high);
        await session.play();
        final high = await stateWhere(
          player,
          (s) =>
              s.videoSelection.fixedTrackId == _high &&
              _width(s) == 640 &&
              s.timeline.position > const Duration(milliseconds: 300) &&
              s.audioTracks.any((t) => t.isSelected),
        );
        expect(high.timeline.position, lessThan(const Duration(seconds: 2)));
        final first = states.indexOf(high);
        expect(first, greaterThanOrEqualTo(0));
        await stateWhere(
          player,
          (s) =>
              s.timeline.position > const Duration(milliseconds: 4500) &&
              _width(s) == 640,
        );
        final fixedStates = states.sublist(first);
        for (var i = 0; i < fixedStates.length; i++) {
          final state = fixedStates[i];
          expect(state.sessionId, session.id);
          expect(state.videoSelection.fixedTrackId, _high);
          expect(state.videoTracks.map((t) => t.id), contains(_high));
          expect(state.failure, isNull);
          if (state.videoGeometry != null) expect(_width(state), 640);
          if (i > 0) {
            expect(
              state.timeline.position,
              greaterThanOrEqualTo(fixedStates[i - 1].timeline.position),
            );
          }
        }
        for (final seconds in [5, 1]) {
          await session.pause();
          await session.seekTo(Duration(seconds: seconds));
          await stateWhere(
            player,
            (s) =>
                (s.timeline.position - Duration(seconds: seconds))
                    .inMilliseconds
                    .abs() <=
                300,
          );
          await session.play();
          await stateWhere(
            player,
            (s) =>
                s.timeline.position >
                    Duration(milliseconds: seconds * 1000 + 400) &&
                _width(s) == 640,
          );
        }
        await session.pause();
        await session.selectVideoTrack(null);
        await session.setVideoConstraints(
          const YlVideoConstraints(
            maxWidth: 320,
            maxHeight: 180,
            maxBitrate: 350000,
          ),
        );
        await session.play();
        final low = await stateWhere(
          player,
          (s) =>
              _width(s) == 320 &&
              s.timeline.position > const Duration(milliseconds: 1900),
        );
        expect(low.videoSelection.isAutomatic, isTrue);
        expect(low.sessionId, session.id);
        final invalid = await DashServer.start(
          manifestOverride: '''
<MPD type="static" mediaPresentationDuration="PT4S"><Period duration="PT4S">
<AdaptationSet contentType="video" mimeType="video/mp4"><Representation id="v" codecs="avc1.42c01e" bandwidth="350000" width="320" height="180">
<SegmentTemplate timescale="10" presentationTimeOffset="100" initialization="init.m4s" media="\$Time\$.m4s"><SegmentTimeline><S t="99" d="40"/></SegmentTimeline></SegmentTemplate>
</Representation></AdaptationSet></Period></MPD>''',
        );
        addTearDown(invalid.close);
        await expectLater(
          player.load(YlNetworkSource(invalid.automaticUri)),
          failureCode(YlFailureCodes.containerUnsupported),
        );
        expect(invalid.childRequests, isEmpty);
        expect(player.state.sessionId, session.id);
        final before = player.state.timeline.position;
        await stateWhere(
          player,
          (s) =>
              s.timeline.position > before + const Duration(milliseconds: 300),
        );
        await stateWhere(player, (s) => s.status == YlPlaybackStatus.completed);
        expect(
          player.state.timeline.position,
          greaterThanOrEqualTo(const Duration(milliseconds: 7500)),
        );
        expect(player.state.failure, isNull);
        expect(events.whereType<YlPlaybackFailedEvent>(), isEmpty);
        for (final period in [0, 1]) {
          final origin = period == 0 ? 10 : 30;
          expect(
            server.childRequests.any(
              (r) => r.path == '/period$period/chunk-1-${origin * 12288}.m4s',
            ),
            isTrue,
          );
          expect(
            server.childRequests.any(
              (r) => r.path == '/period$period/chunk-2-${origin * 48000}.m4s',
            ),
            isTrue,
          );
        }
        expect(
          server.requests.where(
            (r) => r.path == '/manifest.mpd' || r.path == '/explicit',
          ),
          hasLength(1),
        );
        debugPrint(
          'DASH offsets ${list ? "list" : "time"}: media origins10/30s; firstHigh=${high.timeline.position.inMilliseconds}ms; fixed natural=${fixedStates.last.timeline.position.inMilliseconds}ms; seek5/1; auto low=${low.timeline.position.inMilliseconds}ms; completed=${player.state.timeline.position.inMilliseconds}ms; roots1; rejected candidate preserved session',
        );
        await player.stop();
      },
    );
  }
}

int? _width(YlPlayerState state) =>
    state.videoGeometry?.displaySize.width.round();
