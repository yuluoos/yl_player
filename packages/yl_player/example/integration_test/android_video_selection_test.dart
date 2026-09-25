import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/android_test_support.dart';
import 'support/dash_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('fixed high video survives reordered DASH Periods', (
    tester,
  ) async {
    final server = await DashServer.start(variants: true);
    addTearDown(server.close);
    final player = await _createPlayer(tester);
    addTearDown(player.dispose);
    final states = <YlPlayerState>[];
    final stateSubscription = player.states.listen(states.add);
    addTearDown(stateSubscription.cancel);
    final failures = <YlPlaybackFailedEvent>[];
    final failureSubscription = player.events
        .where((event) => event is YlPlaybackFailedEvent)
        .cast<YlPlaybackFailedEvent>()
        .listen(failures.add);
    addTearDown(failureSubscription.cancel);

    final session = await player.load(
      YlNetworkSource(server.automaticUri, format: YlMediaFormat.dash),
    );
    await session.ready.timeout(const Duration(seconds: 20));
    await waitForState(
      player,
      (state) =>
          state.videoTracks.where((track) => track.height == 360).length == 1,
    );
    final highId = player.state.videoTracks
        .singleWhere((track) => track.height == 360)
        .id;
    await session.selectVideoTrack(highId);
    await session.play();
    await session.firstFrame.timeout(const Duration(seconds: 20));
    await waitForState(
      player,
      (state) =>
          state.videoSelection.fixedTrackId != null &&
          state.videoSelection.reason == YlVideoSelectionReason.user &&
          state.videoGeometry?.encodedSize.height == 360,
    );
    expect(
      player.state.timeline.position,
      lessThan(const Duration(seconds: 4)),
      reason: 'A real high frame must be observed before the Period boundary',
    );
    final confirmedHigh = player.state;
    final afterHighIndex = states.length;

    await waitForState(
      player,
      (state) =>
          state.timeline.position > const Duration(milliseconds: 4500) &&
          state.videoGeometry?.encodedSize.height == 360,
    );
    await waitForState(
      player,
      (state) => state.status == YlPlaybackStatus.completed,
    );
    final afterHigh = [confirmedHigh, ...states.skip(afterHighIndex)];
    expect(afterHigh.length, greaterThan(1));
    for (final state in afterHigh) {
      expect(state.videoSelection.isAutomatic, isFalse);
      expect(state.videoSelection.reason, YlVideoSelectionReason.user);
      final height = state.videoGeometry?.encodedSize.height;
      if (height != null) {
        expect(
          height,
          360,
          reason:
              'No published state after confirmed high may show low video '
              '(revision ${state.revision}, position '
              '${state.timeline.position.inMilliseconds} ms)',
        );
      }
    }
    _expectEightSecondTimeline(player);
    expect(failures, isEmpty);
    expect(
      server.childRequests.any(
        (request) => request.path.startsWith('/period1/chunk-1-'),
      ),
      isTrue,
      reason: 'The reordered Period must request the high representation',
    );
    debugPrint(
      'YL_FIXED_RETAIN highId=$highId firstHigh=${confirmedHigh.timeline.position.inMilliseconds}ms '
      'states=${_observations(afterHigh)} period1HighRequests=${server.childRequests.where((r) => r.path.startsWith('/period1/chunk-1-')).length} '
      'completed=${player.state.timeline.position.inMilliseconds}ms',
    );
  });

  testWidgets('missing high video returns to automatic low across DASH Periods', (
    tester,
  ) async {
    final missingHighManifest = await rootBundle.loadString(
      'assets/test_media/dash_variants/manifest_missing_high.mpd',
    );
    final server = await DashServer.start(
      variants: true,
      manifestOverride: missingHighManifest,
    );
    addTearDown(server.close);
    final player = await _createPlayer(tester);
    addTearDown(player.dispose);
    final states = <YlPlayerState>[];
    final stateSubscription = player.states.listen(states.add);
    addTearDown(stateSubscription.cancel);
    final failures = <YlPlaybackFailedEvent>[];
    final failureSubscription = player.events
        .where((event) => event is YlPlaybackFailedEvent)
        .cast<YlPlaybackFailedEvent>()
        .listen(failures.add);
    addTearDown(failureSubscription.cancel);

    final session = await player.load(
      YlNetworkSource(server.automaticUri, format: YlMediaFormat.dash),
    );
    await session.ready.timeout(const Duration(seconds: 20));
    await waitForState(
      player,
      (state) =>
          state.videoTracks.where((track) => track.height == 360).length == 1,
    );
    final highId = player.state.videoTracks
        .singleWhere((track) => track.height == 360)
        .id;
    await session.selectVideoTrack(highId);
    await session.play();
    await session.firstFrame.timeout(const Duration(seconds: 20));
    await waitForState(
      player,
      (state) =>
          state.videoSelection.fixedTrackId != null &&
          state.videoGeometry?.encodedSize.height == 360,
    );
    expect(
      player.state.timeline.position,
      lessThan(const Duration(seconds: 4)),
      reason: 'A real high frame must be observed before high disappears',
    );
    final confirmedHigh = player.state;
    final afterHighIndex = states.length;

    await waitForState(
      player,
      (state) =>
          state.timeline.position > const Duration(milliseconds: 4500) &&
          state.videoSelection.isAutomatic &&
          state.videoSelection.reason ==
              YlVideoSelectionReason.trackUnavailable &&
          state.videoGeometry?.encodedSize.height == 180,
    );
    final afterHigh = [confirmedHigh, ...states.skip(afterHighIndex)];
    for (final state in afterHigh) {
      if (!state.videoSelection.isAutomatic) {
        final height = state.videoGeometry?.encodedSize.height;
        if (height != null) {
          expect(
            height,
            360,
            reason:
                'A published fixed-high state cannot report low geometry '
                '(revision ${state.revision}, position '
                '${state.timeline.position.inMilliseconds} ms)',
          );
        }
      }
    }
    final firstUnavailable = afterHigh.indexWhere(
      (state) =>
          state.videoSelection.reason ==
          YlVideoSelectionReason.trackUnavailable,
    );
    expect(firstUnavailable, greaterThan(0));
    for (final state in afterHigh.take(firstUnavailable)) {
      expect(state.videoSelection.isAutomatic, isFalse);
      expect(state.videoSelection.reason, YlVideoSelectionReason.user);
    }
    final fallback = afterHigh[firstUnavailable];
    expect(
      fallback.timeline.position,
      greaterThanOrEqualTo(const Duration(seconds: 4)),
      reason:
          'The current Period must reach its 4s boundary before '
          'publishing trackUnavailable (revision ${fallback.revision})',
    );
    expect(fallback.videoSelection.isAutomatic, isTrue);
    expect(fallback.videoTracks.map((track) => track.height), [180]);
    for (final state in afterHigh.skip(firstUnavailable)) {
      expect(state.videoSelection.isAutomatic, isTrue);
      expect(
        state.videoSelection.reason,
        YlVideoSelectionReason.trackUnavailable,
      );
    }
    expect(player.state.videoSelection.fixedTrackId, isNull);
    expect(player.state.videoTracks.map((track) => track.height), [180]);
    _expectEightSecondTimeline(player);
    expect(player.state.timeline.isSeekable, isTrue);
    expect(
      server.childRequests.any(
        (request) => request.path.startsWith('/period0/chunk-1-'),
      ),
      isTrue,
    );
    expect(
      server.childRequests.any(
        (request) => request.path.startsWith('/period1/chunk-0-'),
      ),
      isTrue,
    );
    expect(
      server.childRequests.any(
        (request) => request.path.startsWith('/period1/chunk-1-'),
      ),
      isFalse,
    );

    await session.pause();
    await session.seekTo(const Duration(seconds: 5));
    await waitForState(
      player,
      (state) =>
          (state.timeline.position - const Duration(seconds: 5)).inMilliseconds
              .abs() <=
          300,
    );
    expect(
      player.state.videoSelection.reason,
      YlVideoSelectionReason.trackUnavailable,
    );
    await session.play();
    await waitForState(
      player,
      (state) => state.timeline.position > const Duration(milliseconds: 5500),
    );
    expect(player.state.videoGeometry?.encodedSize.height, 180);
    expect(failures, isEmpty);
    debugPrint(
      'YL_FIXED_MISSING highId=$highId firstHigh=${confirmedHigh.timeline.position.inMilliseconds}ms '
      'states=${_observations(afterHigh)} low=${player.state.videoGeometry?.encodedSize.height} '
      'seek=${player.state.timeline.position.inMilliseconds}ms '
      'period1LowRequests=${server.childRequests.where((r) => r.path.startsWith('/period1/chunk-0-')).length}',
    );
    await player.stop();
    expect(player.state.sessionId, isNull);
    expect(player.state.videoSelection.isAutomatic, isTrue);
    expect(player.state.videoSelection.reason, YlVideoSelectionReason.initial);
  });
}

Future<YlPlayerController> _createPlayer(WidgetTester tester) async {
  final player = await YlPlayerController.create();
  await tester.pumpWidget(MaterialApp(home: YlPlayerView(controller: player)));
  expect(
    player.capabilities.availableEngines,
    contains(YlPlaybackEngine.media3),
  );
  expect(
    player.capabilities.supportedOperations,
    contains(YlPlayerOperation.videoTrackSelection),
  );
  return player;
}

void _expectEightSecondTimeline(YlPlayerController player) {
  final duration = player.state.timeline.duration;
  expect(duration, isNotNull);
  expect(
    (duration! - const Duration(seconds: 8)).inMilliseconds.abs(),
    lessThanOrEqualTo(2),
  );
}

String _observations(Iterable<YlPlayerState> states) => states
    .map(
      (state) =>
          '${state.revision}:${state.timeline.position.inMilliseconds}/'
          '${(state.videoGeometry?.encodedSize.height ?? -1).round()}/'
          '${state.videoSelection.isAutomatic ? 'auto' : 'fixed'}-'
          '${state.videoSelection.reason.name}',
    )
    .join(',');
