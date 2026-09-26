import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';

const _low = (
  'dash-video-w320-h180-b350000',
  YlTrackKind.video,
  false,
  'avc1.42c01e',
  350000,
  320,
  180,
);
const _high = (
  'dash-video-w640-h360-b700000',
  YlTrackKind.video,
  false,
  'avc1.42c01e',
  700000,
  640,
  360,
);
const _cap = YlLoadOptions(
  videoConstraints: YlVideoConstraints(
    maxWidth: 320,
    maxHeight: 180,
    maxBitrate: 350000,
  ),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reordered two-quality Periods keep stable public IDs', (
    tester,
  ) async {
    final server = await DashServer.start(variants: true);
    addTearDown(server.close);
    final player = await appleController(tester);
    final states = <YlPlayerState>[];
    final subscription = player.states.listen(states.add);
    addTearDown(subscription.cancel);
    final session = await player.load(
      YlNetworkSource(server.explicitUri, format: YlMediaFormat.dash),
    );
    await readyAndPlay(player, session);
    final first = await _sample(
      player,
      session,
      (s) =>
          s.timeline.position < const Duration(seconds: 4) &&
          _hasFixtureSize(s),
      [_low, _high],
    );
    _expectFixtureSize(first);
    final natural = await _sample(
      player,
      session,
      (s) =>
          s.timeline.position > const Duration(milliseconds: 4500) &&
          _hasFixtureSize(s),
      [_low, _high],
    );
    _expectFixtureSize(natural);
    final back = await _seekSample(player, session, 1, [
      _low,
      _high,
    ], fixtureSize: true);
    _expectFixtureSize(back);
    final forward = await _seekSample(player, session, 5, [
      _low,
      _high,
    ], fixtureSize: true);
    _expectFixtureSize(forward);
    await session.play();
    final completed = await stateWhere(
      player,
      (s) =>
          s.sessionId == session.id && s.status == YlPlaybackStatus.completed,
    );
    _expectState(completed, session, [_low, _high]);
    _expectCompleted(completed);
    for (final state in states.where(
      (s) => s.sessionId == session.id && s.videoTracks.isNotEmpty,
    )) {
      _expectState(state, session, [_low, _high]);
    }
    expect(
      states.any(
        (s) =>
            s.sessionId == session.id &&
            s.timeline.position < const Duration(seconds: 4),
      ),
      isTrue,
    );
    expect(
      states.any(
        (s) =>
            s.sessionId == session.id &&
            s.timeline.position > const Duration(milliseconds: 4500),
      ),
      isTrue,
    );
    debugPrint(
      'DASH catalog reordered: first=${_observation(first)} '
      'natural=${_observation(natural)} back=${_observation(back)} '
      'forward=${_observation(forward)} completed=${_observation(completed)} '
      'states=${states.where((s) => s.sessionId == session.id).length}',
    );
  });

  testWidgets('high-to-low catalog follows actual time, including deltas', (
    tester,
  ) async {
    final server = await DashServer.start(
      variants: true,
      manifestOverride: await _manifest('manifest_high_to_low.mpd'),
    );
    addTearDown(server.close);
    final player = await appleController(tester);
    final states = <YlPlayerState>[];
    final subscription = player.states.listen(states.add);
    addTearDown(subscription.cancel);
    final session = await player.load(YlNetworkSource(server.automaticUri));
    await readyAndPlay(player, session);
    final first = await _sample(
      player,
      session,
      (s) =>
          s.timeline.position < const Duration(seconds: 4) &&
          _hasSize(s, '640x360'),
      [_high],
    );
    _expectSize(first, '640x360');
    final natural = await _sample(
      player,
      session,
      (s) =>
          s.timeline.position > const Duration(milliseconds: 4500) &&
          _hasSize(s, '320x180'),
      [_low],
    );
    _expectSize(natural, '320x180');
    final back = await _seekSample(player, session, 1, [
      _high,
    ], size: '640x360');
    _expectSize(back, '640x360');
    final forward = await _seekSample(player, session, 5, [
      _low,
    ], size: '320x180');
    _expectSize(forward, '320x180');
    await session.play();
    final completed = await stateWhere(
      player,
      (s) =>
          s.sessionId == session.id && s.status == YlPlaybackStatus.completed,
    );
    _expectState(completed, session, [_low]);
    _expectCompleted(completed);

    final catalogStates = states
        .where((s) => s.sessionId == session.id && s.videoTracks.isNotEmpty)
        .toList();
    expect(catalogStates, isNotEmpty);
    var highStates = 0;
    var lowStates = 0;
    for (final state in catalogStates) {
      final expected = state.timeline.position < const Duration(seconds: 4)
          ? [_high]
          : [_low];
      _expectState(state, session, expected);
      if (expected.first == _high) {
        highStates++;
      } else {
        lowStates++;
      }
    }
    expect(highStates, greaterThan(0));
    expect(lowStates, greaterThan(0));
    debugPrint(
      'DASH catalog changing: first=${_observation(first)} '
      'natural=${_observation(natural)} back=${_observation(back)} '
      'forward=${_observation(forward)} completed=${_observation(completed)} '
      'highStates=$highStates lowStates=$lowStates',
    );
  });

  testWidgets('capped catalog survives failed candidate and Stop clears it', (
    tester,
  ) async {
    final accepted = await DashServer.start(variants: true);
    final candidate = await DashServer.start(
      variants: true,
      delayManifest: true,
      manifestOverride: await _manifest('manifest_high_to_low.mpd'),
    );
    addTearDown(accepted.close);
    addTearDown(candidate.close);
    final player = await appleController(tester);
    final states = <YlPlayerState>[];
    final subscription = player.states.listen(states.add);
    addTearDown(subscription.cancel);
    final old = await player.load(
      YlNetworkSource(accepted.explicitUri, format: YlMediaFormat.dash),
      options: _cap,
    );
    await readyAndPlay(player, old);
    final first = await _sample(
      player,
      old,
      (s) =>
          s.timeline.position < const Duration(seconds: 4) &&
          _hasSize(s, '320x180'),
      [_low],
    );
    _expectSize(first, '320x180');
    final natural = await _sample(
      player,
      old,
      (s) =>
          s.timeline.position > const Duration(milliseconds: 4500) &&
          _hasSize(s, '320x180'),
      [_low],
    );
    _expectSize(natural, '320x180');
    await old.pause();
    await old.seekTo(const Duration(seconds: 1));
    final back = await _sample(
      player,
      old,
      (s) =>
          s.timeline.position >= const Duration(milliseconds: 1500) &&
          s.timeline.position < const Duration(seconds: 4) &&
          _hasSize(s, '320x180'),
      [_low],
      play: true,
    );
    // A rejected candidate must never publish a transient new session or
    // clear the accepted catalog, even if later states restore the old one.
    final candidateStateStart = states.length;
    final rejected = expectLater(
      player.load(YlNetworkSource(candidate.automaticUri), options: _cap),
      failureCode(YlFailureCodes.qualityConstraintUnsupported),
    );
    await candidate.manifestEntered.timeout(const Duration(seconds: 5));
    final before = player.state.timeline.position;
    final during = await _sample(
      player,
      old,
      (s) => s.timeline.position > before + const Duration(milliseconds: 300),
      [_low],
    );
    candidate.releaseDelayedManifest();
    await rejected;
    expect(candidate.childRequests, isEmpty);
    expect(player.state.sessionId, old.id);
    expect(player.state.failure, isNull);
    final after = player.state.timeline.position;
    final preserved = await _sample(
      player,
      old,
      (s) => s.timeline.position > after + const Duration(milliseconds: 300),
      [_low],
    );
    _expectSize(preserved, '320x180');
    final candidateInterval = states.sublist(candidateStateStart);
    expect(candidateInterval, isNotEmpty);
    for (final state in candidateInterval) {
      _expectState(state, old, [_low]);
    }
    for (final state in states.where(
      (s) => s.sessionId == old.id && s.videoTracks.isNotEmpty,
    )) {
      _expectState(state, old, [_low]);
    }
    await player.stop();
    final stopped = await stateWhere(
      player,
      (s) => s.status == YlPlaybackStatus.idle && s.videoTracks.isEmpty,
    );
    expect(stopped.videoTracks, isEmpty);
    expect(stopped.videoSelection.isAutomatic, isTrue);
    debugPrint(
      'DASH catalog cap: first=${_observation(first)} '
      'natural=${_observation(natural)} back=${_observation(back)} '
      'during=${_observation(during)} preserved=${_observation(preserved)} '
      'candidateIntervalStates=${candidateInterval.length} '
      'candidateMediaRequests=${candidate.childRequests.length} '
      'stopTracks=${stopped.videoTracks.length}',
    );
  });
}

typedef _TrackDescription = (String, YlTrackKind, bool, String, int, int, int);

_TrackDescription _describe(YlMediaTrack track) => (
  track.id,
  track.kind,
  track.isSelected,
  track.codec ?? '',
  track.bitrate ?? -1,
  track.width ?? -1,
  track.height ?? -1,
);

bool _hasCatalog(YlPlayerState state, List<_TrackDescription> expected) =>
    listEquals(state.videoTracks.map(_describe).toList(), expected);

void _expectState(
  YlPlayerState state,
  YlPlaybackSession session,
  List<_TrackDescription> expected,
) {
  expect(state.sessionId, session.id);
  expect(state.engine, YlPlaybackEngine.avPlayer);
  expect(state.videoSelection.isAutomatic, isTrue);
  expect(state.videoSelection.reason, YlVideoSelectionReason.initial);
  expect(
    state.videoTracks.map(_describe).toList(),
    expected,
    reason:
        'position=${state.timeline.position.inMilliseconds}ms '
        'revision=${state.revision}',
  );
}

Future<YlPlayerState> _sample(
  YlPlayerController player,
  YlPlaybackSession session,
  bool Function(YlPlayerState) atPosition,
  List<_TrackDescription> expected, {
  bool play = false,
}) async {
  if (play) await session.play();
  final state = await stateWhere(
    player,
    (s) =>
        s.sessionId == session.id && atPosition(s) && _hasCatalog(s, expected),
  );
  _expectState(state, session, expected);
  return state;
}

Future<YlPlayerState> _seekSample(
  YlPlayerController player,
  YlPlaybackSession session,
  int second,
  List<_TrackDescription> expected, {
  String? size,
  bool fixtureSize = false,
}) async {
  await session.pause();
  await session.seekTo(Duration(seconds: second));
  final lower = Duration(milliseconds: second * 1000 + 500);
  final upper = Duration(seconds: second == 1 ? 4 : 8);
  return _sample(
    player,
    session,
    (s) =>
        s.timeline.position > lower &&
        s.timeline.position < upper &&
        (size == null || _hasSize(s, size)) &&
        (!fixtureSize || _hasFixtureSize(s)),
    expected,
    play: true,
  );
}

void _expectSize(YlPlayerState state, String expected) {
  final size = state.videoGeometry?.displaySize;
  expect(size, isNotNull);
  expect('${size!.width.round()}x${size.height.round()}', expected);
}

bool _hasSize(YlPlayerState state, String expected) {
  final size = state.videoGeometry?.displaySize;
  return size != null &&
      '${size.width.round()}x${size.height.round()}' == expected;
}

bool _hasFixtureSize(YlPlayerState state) =>
    _hasSize(state, '320x180') || _hasSize(state, '640x360');

void _expectFixtureSize(YlPlayerState state) {
  final size = state.videoGeometry?.displaySize;
  expect(size, isNotNull);
  expect(
    '${size!.width.round()}x${size.height.round()}',
    anyOf('320x180', '640x360'),
  );
}

void _expectCompleted(YlPlayerState state) {
  expect(state.timeline.duration, isNotNull);
  expect(
    (state.timeline.duration! - const Duration(seconds: 8)).inMilliseconds
        .abs(),
    lessThanOrEqualTo(50),
  );
  expect(
    state.timeline.position,
    greaterThanOrEqualTo(const Duration(milliseconds: 7500)),
  );
}

String _observation(YlPlayerState state) {
  final size = state.videoGeometry?.displaySize;
  final geometry = size == null
      ? 'unknown'
      : '${size.width.round()}x${size.height.round()}';
  return '${state.timeline.position.inMilliseconds}ms/$geometry/'
      '${state.videoTracks.map((t) => t.id).join(',')}';
}

Future<String> _manifest(String name) =>
    rootBundle.loadString('assets/test_media/dash_variants/$name');
