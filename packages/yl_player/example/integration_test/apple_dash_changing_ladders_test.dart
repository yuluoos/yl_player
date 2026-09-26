import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final scenario in <_Scenario>[
    const _Scenario(
      name: 'high-only to low-only',
      manifest: 'manifest_high_to_low.mpd',
      firstSize: '640x360',
      secondSize: '320x180',
      firstTrack: 1,
      secondTrack: 0,
    ),
    const _Scenario(
      name: 'low-only to high-only',
      manifest: 'manifest_low_to_high.mpd',
      firstSize: '320x180',
      secondSize: '640x360',
      firstTrack: 0,
      secondTrack: 1,
    ),
    const _Scenario(
      name: 'missing-high multivariant',
      manifest: 'manifest_missing_high.mpd',
      secondSize: '320x180',
      secondTrack: 0,
    ),
  ]) {
    testWidgets('Apple DASH ${scenario.name} plays, seeks and completes', (
      tester,
    ) async {
      final manifest = await rootBundle.loadString(
        'assets/test_media/dash_variants/${scenario.manifest}',
      );
      final server = await DashServer.start(
        variants: true,
        manifestOverride: manifest,
      );
      addTearDown(server.close);
      final player = await appleController(tester);
      final events = <YlPlayerEvent>[];
      final eventSubscription = player.events.listen(events.add);
      addTearDown(eventSubscription.cancel);
      final session = await player.load(
        YlNetworkSource(server.automaticUri, format: YlMediaFormat.dash),
      );
      final naturalPositions = <Duration>[];
      final stateSubscription = player.states.listen((state) {
        if (state.sessionId == session.id) {
          naturalPositions.add(state.timeline.position);
        }
      });
      addTearDown(stateSubscription.cancel);

      await readyAndPlay(player, session);
      expect(
        events.whereType<YlFirstFrameEvent>().any(
          (event) => event.sessionId == session.id,
        ),
        isTrue,
      );
      expect(player.state.sessionId, session.id);
      expect(player.state.engine, YlPlaybackEngine.avPlayer);
      _expectAutomaticInitial(player.state);
      expect(player.state.audioTracks.any((track) => track.isSelected), isTrue);
      _eightSeconds(player);

      final first = await stateWhere(
        player,
        (state) =>
            state.sessionId == session.id &&
            state.timeline.position < const Duration(seconds: 4) &&
            _matchesSize(state, scenario.firstSize),
      );
      _expectAutomaticInitial(first);
      final firstSize = _size(first);

      final natural = await stateWhere(
        player,
        (state) =>
            state.sessionId == session.id &&
            state.timeline.position > const Duration(milliseconds: 4500) &&
            _matchesSize(state, scenario.secondSize),
      );
      _expectAutomaticInitial(natural);
      final naturalSize = _size(natural);
      await stateSubscription.cancel();
      expect(
        naturalPositions.any((p) => p < const Duration(seconds: 4)),
        isTrue,
      );
      expect(
        naturalPositions.any((p) => p > const Duration(milliseconds: 4500)),
        isTrue,
      );
      for (var index = 1; index < naturalPositions.length; index++) {
        expect(
          naturalPositions[index],
          greaterThanOrEqualTo(naturalPositions[index - 1]),
        );
      }

      final seekSizes = <String>[];
      final seekPositions = <int>[];
      for (final (second, expectedSize) in [
        (5, scenario.secondSize),
        (1, scenario.firstSize),
      ]) {
        await session.pause();
        await session.seekTo(Duration(seconds: second));
        await stateWhere(
          player,
          (state) =>
              state.sessionId == session.id &&
              (state.timeline.position - Duration(seconds: second))
                      .inMilliseconds
                      .abs() <=
                  300,
        );
        await session.play();
        final resumed = await stateWhere(
          player,
          (state) =>
              state.sessionId == session.id &&
              state.timeline.position >
                  Duration(milliseconds: second * 1000 + 500) &&
              (second != 1 ||
                  state.timeline.position < const Duration(seconds: 4)) &&
              _matchesSize(state, expectedSize),
        );
        _expectAutomaticInitial(resumed);
        seekSizes.add(_size(resumed));
        seekPositions.add(resumed.timeline.position.inMilliseconds);
      }

      final completed = await stateWhere(
        player,
        (state) =>
            state.sessionId == session.id &&
            state.status == YlPlaybackStatus.completed,
      );
      _expectAutomaticInitial(completed);
      _eightSeconds(player);
      expect(
        player.state.timeline.position,
        greaterThanOrEqualTo(const Duration(milliseconds: 7500)),
      );
      for (final (period, requiredTrack) in [
        (0, scenario.firstTrack),
        (1, scenario.secondTrack),
      ]) {
        final tracks = requiredTrack == null ? [0, 1] : [requiredTrack];
        expect(
          tracks.any(
            (track) =>
                server.childRequests.any(
                  (request) => request.path == '/period$period/init-$track.m4s',
                ) &&
                server.childRequests.any(
                  (request) =>
                      request.path.startsWith('/period$period/chunk-$track-'),
                ),
          ),
          isTrue,
          reason: 'Period $period must request playable video',
        );
        expect(
          server.childRequests.any(
            (request) => request.path == '/period$period/init-2.m4s',
          ),
          isTrue,
        );
        expect(
          server.childRequests.any(
            (request) => request.path.startsWith('/period$period/chunk-2-'),
          ),
          isTrue,
        );
      }
      expect(events.whereType<YlPlaybackFailedEvent>(), isEmpty);
      debugPrint(
        'DASH changing ${scenario.name}: first=$firstSize natural=$naturalSize '
        'seek5=${seekSizes[0]}@${seekPositions[0]}ms '
        'seek1=${seekSizes[1]}@${seekPositions[1]}ms '
        'natural=${naturalPositions.first.inMilliseconds}..'
        '${naturalPositions.last.inMilliseconds}ms '
        'completed=${player.state.timeline.position.inMilliseconds}ms '
        'requests=${server.childRequests.map((request) => request.path).toList()}',
      );
    });
  }
}

void _expectAutomaticInitial(YlPlayerState state) {
  expect(state.videoSelection.isAutomatic, isTrue);
  expect(state.videoSelection.reason, YlVideoSelectionReason.initial);
}

void _eightSeconds(YlPlayerController player) {
  expect(player.state.timeline.duration, isNotNull);
  expect(
    (player.state.timeline.duration! - const Duration(seconds: 8))
        .inMilliseconds
        .abs(),
    lessThanOrEqualTo(50),
  );
}

bool _matchesSize(YlPlayerState state, String? expected) {
  final size = state.videoGeometry?.displaySize;
  if (size == null) return false;
  final actual = '${size.width.round()}x${size.height.round()}';
  return expected == null
      ? actual == '320x180' || actual == '640x360'
      : actual == expected;
}

String _size(YlPlayerState state) {
  final size = state.videoGeometry!.displaySize;
  return '${size.width.round()}x${size.height.round()}';
}

final class _Scenario {
  const _Scenario({
    required this.name,
    required this.manifest,
    this.firstSize,
    required this.secondSize,
    this.firstTrack,
    required this.secondTrack,
  });

  final String name;
  final String manifest;
  final String? firstSize;
  final String secondSize;
  final int? firstTrack;
  final int secondTrack;
}
