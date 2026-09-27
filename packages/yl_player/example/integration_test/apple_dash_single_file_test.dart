import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';

const _high = 'dash-video-w640-h360-b700000';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final cross in [false, true]) {
    testWidgets(
      'single-file DASH ${cross ? 'cross origin' : 'same origin'} preserves range playback and policy',
      (tester) async {
        final server = await DashServer.start(
          singleFileSegmentList: true,
          originMode: cross
              ? DashOriginMode.crossOrigin
              : DashOriginMode.sameOrigin,
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
            cross ? server.automaticUri : server.explicitUri,
            format: cross ? YlMediaFormat.automatic : YlMediaFormat.dash,
            request: YlHttpRequest(
              headers: const {'X-Dash-Client': 'ordinary-test-value'},
              credentials: const {
                'Authorization': 'Bearer single-test',
                'Cookie': 'single=test',
              },
            ),
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
<BaseURL>packed.m4s</BaseURL><SegmentList duration="2"><Initialization range="0-99"/><SegmentURL mediaRange="200-100"/><SegmentURL mediaRange="200-399"/></SegmentList>
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
          for (final track in [1, 2]) {
            final requests = server.requestsFor(
              '/period$period/packed-p$period-$track.m4s',
            );
            expect(requests, isNotEmpty);
            final ranges = requests.map((r) => r.header('range')).toSet();
            expect(
              ranges.any((r) => r != null && r.startsWith('bytes=0-')),
              isTrue,
              reason: 'Initialization must use byte range',
            );
            expect(
              ranges.any(
                (r) => r != null && RegExp(r'^bytes=[1-9]\d*-\d+$').hasMatch(r),
              ),
              isTrue,
              reason: 'Media must use nonzero closed byte range',
            );
          }
        }
        expect(server.childRequests, isNotEmpty);
        for (final request in server.childRequests) {
          expect(request.path, contains('/packed-'));
          expect(request.header('range'), matches(r'^bytes=\d+-\d+$'));
          expect(request.origin, cross ? 'secondary' : 'primary');
          expect(request.header('x-dash-client'), 'ordinary-test-value');
          expect(
            cross
                ? request.header('authorization') == null
                : request.header('authorization') == 'Bearer single-test',
            isTrue,
          );
          expect(
            cross
                ? request.header('cookie') == null
                : request.header('cookie') == 'single=test',
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
          'DASH single file ${cross ? "cross" : "same"}: ranges and credentials verified; firstHigh=${high.timeline.position.inMilliseconds}ms; fixed natural=${fixedStates.last.timeline.position.inMilliseconds}ms; seek5/1; auto low=${low.timeline.position.inMilliseconds}ms; completed=${player.state.timeline.position.inMilliseconds}ms; roots1; rejected candidate preserved session',
        );
        await player.stop();
      },
    );
  }
}

int? _width(YlPlayerState state) =>
    state.videoGeometry?.displaySize.width.round();
