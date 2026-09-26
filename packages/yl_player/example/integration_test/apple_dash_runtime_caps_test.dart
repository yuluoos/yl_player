import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';

const _lowCaps = YlVideoConstraints(
  maxWidth: 320,
  maxHeight: 180,
  maxBitrate: 350000,
);
const _upperCaps = YlVideoConstraints(
  maxWidth: 640,
  maxHeight: 360,
  maxBitrate: 700000,
);
const _impossibleCaps = YlVideoConstraints(maxWidth: 160, maxHeight: 90);

typedef _Track = (String, YlTrackKind, bool, String, int, int, int);
const _low = <_Track>[
  (
    'dash-video-w320-h180-b350000',
    YlTrackKind.video,
    false,
    'avc1.42c01e',
    350000,
    320,
    180,
  ),
];
const _high = <_Track>[
  (
    'dash-video-w640-h360-b700000',
    YlTrackKind.video,
    false,
    'avc1.42c01e',
    700000,
    640,
    360,
  ),
];
const _both = <_Track>[..._low, ..._high];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('active explicit DASH tightens and clears without MPD fetch', (
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
    final original = await _sample(
      player,
      session,
      _both,
      (s) => s.timeline.position > const Duration(seconds: 1),
    );
    await session.pause();
    final paused = await stateWhere(
      player,
      (s) => s.sessionId == session.id && s.status == YlPlaybackStatus.paused,
    );
    final saved = paused.timeline.position;
    final roots = _rootCount(server);
    expect(roots, 1);
    final tightenStart = states.length;
    await session.setVideoConstraints(_lowCaps);
    debugPrint('DASH runtime explicit after tighten: ${_brief(player.state)}');
    final tightened = await _sample(
      player,
      session,
      _low,
      (s) => _notPlaying(s) && _hasAudio(s),
    );
    _near(tightened.timeline.position, saved);
    _audioReady(tightened);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final held = player.state;
    _expectState(held, session, _low);
    expect(_notPlaying(held), isTrue);
    _near(held.timeline.position, tightened.timeline.position);
    _expectInterval(states, tightenStart, session, [_both, _low]);
    expect(_rootCount(server), roots);

    await session.play();
    final lowOutput = await _sample(
      player,
      session,
      _low,
      (s) =>
          s.timeline.position > saved + const Duration(milliseconds: 500) &&
          _hasSize(s, '320x180') &&
          _hasAudio(s),
    );
    await session.pause();
    final pausedAfterLow = await stateWhere(
      player,
      (s) => s.sessionId == session.id && s.status == YlPlaybackStatus.paused,
    );

    final clearStart = states.length;
    await session.setVideoConstraints(const YlVideoConstraints());
    final cleared = await _sample(
      player,
      session,
      _both,
      (s) => _notPlaying(s) && _hasAudio(s),
    );
    _near(cleared.timeline.position, pausedAfterLow.timeline.position);
    _audioReady(cleared);
    _expectInterval(states, clearStart, session, [_low, _both]);
    expect(_rootCount(server), roots);
    await session.play();
    final continued = await _sample(
      player,
      session,
      _both,
      (s) =>
          s.timeline.position >
          pausedAfterLow.timeline.position + const Duration(milliseconds: 500),
    );
    _audioReady(continued);
    expect(continued.failure, isNull);
    expect(_rootCount(server), roots);
    debugPrint(
      'DASH runtime explicit: original=${_brief(original)} '
      'saved=${saved.inMilliseconds}ms tightened=${_brief(tightened)} '
      'held=${_brief(held)} lowOutput=${_brief(lowOutput)} '
      'cleared=${_brief(cleared)} '
      'continued=${_brief(continued)} roots=$roots '
      'updateStates=${states.length - tightenStart}',
    );
  });

  testWidgets('failed active automatic DASH cap keeps every accepted state', (
    tester,
  ) async {
    final server = await DashServer.start(variants: true);
    addTearDown(server.close);
    final player = await appleController(tester);
    final states = <YlPlayerState>[];
    final subscription = player.states.listen(states.add);
    addTearDown(subscription.cancel);
    final session = await player.load(
      YlNetworkSource(server.automaticUri),
      options: const YlLoadOptions(videoConstraints: _lowCaps),
    );
    await readyAndPlay(player, session);
    final accepted = await _sample(
      player,
      session,
      _low,
      (s) => s.timeline.position > const Duration(milliseconds: 800),
    );
    final roots = _rootCount(server);
    expect(roots, 1);
    final start = states.length;
    await expectLater(
      session.setVideoConstraints(_impossibleCaps),
      failureCode(YlFailureCodes.qualityConstraintUnsupported),
    );
    final continued = await _sample(
      player,
      session,
      _low,
      (s) =>
          s.timeline.position >
          accepted.timeline.position + const Duration(milliseconds: 500),
    );
    expect(states.length - start, greaterThan(0));
    _expectInterval(states, start, session, [_low]);
    _audioReady(continued);
    expect(continued.failure, isNull);
    expect(_rootCount(server), roots);
    await player.stop();
    final stopped = await stateWhere(
      player,
      (s) =>
          s.status == YlPlaybackStatus.idle &&
          s.sessionId == null &&
          s.videoTracks.isEmpty,
    );
    expect(stopped.audioTracks, isEmpty);
    debugPrint(
      'DASH runtime rejected: accepted=${_brief(accepted)} '
      'continued=${_brief(continued)} failure='
      '${YlFailureCodes.qualityConstraintUnsupported} '
      'states=${states.length - start} roots=$roots stop=${stopped.status}',
    );
  });

  testWidgets('high-to-low active cap checks every Period and seek catalog', (
    tester,
  ) async {
    final manifest = await rootBundle.loadString(
      'assets/test_media/dash_variants/manifest_high_to_low.mpd',
    );
    final server = await DashServer.start(
      variants: true,
      manifestOverride: manifest,
    );
    addTearDown(server.close);
    final player = await appleController(tester);
    final states = <YlPlayerState>[];
    final subscription = player.states.listen(states.add);
    addTearDown(subscription.cancel);
    final session = await player.load(YlNetworkSource(server.automaticUri));
    await readyAndPlay(player, session);
    final high = await _sample(
      player,
      session,
      _high,
      (s) =>
          s.timeline.position < const Duration(seconds: 4) &&
          _hasSize(s, '640x360'),
    );
    final naturalLow = await _sample(
      player,
      session,
      _low,
      (s) =>
          s.timeline.position > const Duration(milliseconds: 4500) &&
          _hasSize(s, '320x180'),
    );
    await session.pause();
    final paused = await stateWhere(
      player,
      (s) => s.sessionId == session.id && s.status == YlPlaybackStatus.paused,
    );
    final roots = _rootCount(server);
    expect(roots, 1);
    final capStart = states.length;
    await session.setVideoConstraints(_upperCaps);
    final capped = await _sample(
      player,
      session,
      _low,
      (s) => _notPlaying(s) && _hasAudio(s),
    );
    _near(capped.timeline.position, paused.timeline.position);
    _audioReady(capped);
    _expectInterval(states, capStart, session, [_low]);
    final capEnd = states.length;
    expect(_rootCount(server), roots);

    // The current low-only Period is feasible, but the first high-only Period
    // cannot satisfy this policy. Admission must inspect the whole program.
    final rejectionStart = states.length;
    await expectLater(
      session.setVideoConstraints(_lowCaps),
      failureCode(YlFailureCodes.qualityConstraintUnsupported),
    );
    _expectInterval(states, rejectionStart, session, [_low]);
    _expectState(player.state, session, _low);
    expect(_rootCount(server), roots);
    final backStart = states.length;
    await session.seekTo(const Duration(seconds: 1));
    debugPrint('DASH runtime periods after back: ${_brief(player.state)}');
    final back = await _sample(
      player,
      session,
      _high,
      (s) =>
          _nearPosition(s.timeline.position, const Duration(seconds: 1)) &&
          _hasAudio(s),
    );
    _audioReady(back);
    _expectInterval(states, backStart, session, [_low, _high]);
    final backEnd = states.length;
    final forwardStart = states.length;
    await session.seekTo(const Duration(seconds: 5));
    debugPrint('DASH runtime periods after forward: ${_brief(player.state)}');
    final forward = await _sample(
      player,
      session,
      _low,
      (s) =>
          _nearPosition(s.timeline.position, const Duration(seconds: 5)) &&
          _hasAudio(s),
    );
    _audioReady(forward);
    _expectInterval(states, forwardStart, session, [_high, _low]);
    final forwardEnd = states.length;
    expect(_rootCount(server), roots);
    final continueStart = states.length;
    await session.play();
    final continued = await _sample(
      player,
      session,
      _low,
      (s) => s.timeline.position > const Duration(milliseconds: 5500),
    );
    expect(continued.failure, isNull);
    _expectInterval(states, continueStart, session, [_low]);
    debugPrint(
      'DASH runtime periods: high=${_brief(high)} '
      'naturalLow=${_brief(naturalLow)} capped=${_brief(capped)} '
      'back=${_brief(back)} forward=${_brief(forward)} '
      'continued=${_brief(continued)} roots=$roots '
      'phaseStates=${capEnd - capStart}/'
      '${backStart - rejectionStart}/'
      '${backEnd - backStart}/'
      '${forwardEnd - forwardStart}/'
      '${states.length - continueStart}',
    );
  });
}

_Track _describe(YlMediaTrack track) => (
  track.id,
  track.kind,
  track.isSelected,
  track.codec ?? '',
  track.bitrate ?? -1,
  track.width ?? -1,
  track.height ?? -1,
);

void _expectState(
  YlPlayerState state,
  YlPlaybackSession session,
  List<_Track> catalog,
) {
  expect(state.sessionId, session.id);
  expect(state.engine, YlPlaybackEngine.avPlayer);
  expect(state.videoSelection.isAutomatic, isTrue);
  expect(state.videoSelection.reason, YlVideoSelectionReason.initial);
  expect(
    state.videoTracks.map(_describe).toList(),
    catalog,
    reason:
        'position=${state.timeline.position.inMilliseconds}ms '
        'revision=${state.revision}',
  );
  expect(state.failure, isNull);
}

Future<YlPlayerState> _sample(
  YlPlayerController player,
  YlPlaybackSession session,
  List<_Track> catalog,
  bool Function(YlPlayerState) where,
) async {
  final state = await stateWhere(
    player,
    (s) =>
        s.sessionId == session.id &&
        where(s) &&
        listEquals(s.videoTracks.map(_describe).toList(), catalog),
  );
  _expectState(state, session, catalog);
  return state;
}

void _expectInterval(
  List<YlPlayerState> states,
  int start,
  YlPlaybackSession session,
  List<List<_Track>> allowed,
) {
  final interval = states.skip(start).toList();
  for (final state in interval) {
    expect(
      allowed.any(
        (catalog) =>
            listEquals(state.videoTracks.map(_describe).toList(), catalog),
      ),
      isTrue,
      reason: 'unexpected catalog at revision ${state.revision}',
    );
    _expectState(
      state,
      session,
      allowed.firstWhere(
        (catalog) =>
            listEquals(state.videoTracks.map(_describe).toList(), catalog),
      ),
    );
  }
}

void _audioReady(YlPlayerState state) {
  expect(state.audioTracks, hasLength(1));
  expect(state.audioTracks.single.kind, YlTrackKind.audio);
  expect(state.audioTracks.single.isSelected, isTrue);
}

bool _hasAudio(YlPlayerState state) =>
    state.audioTracks.length == 1 &&
    state.audioTracks.single.kind == YlTrackKind.audio &&
    state.audioTracks.single.isSelected;

bool _notPlaying(YlPlayerState state) =>
    state.status == YlPlaybackStatus.paused ||
    state.status == YlPlaybackStatus.ready;

int _rootCount(DashServer server) => server.requests
    .where((r) => r.path == '/manifest.mpd' || r.path == '/explicit')
    .length;

void _near(Duration actual, Duration expected) =>
    expect((actual - expected).inMilliseconds.abs(), lessThanOrEqualTo(300));

bool _nearPosition(Duration actual, Duration expected) =>
    (actual - expected).inMilliseconds.abs() <= 300;

bool _hasSize(YlPlayerState state, String expected) {
  final size = state.videoGeometry?.displaySize;
  return size != null &&
      '${size.width.round()}x${size.height.round()}' == expected;
}

String _brief(YlPlayerState state) =>
    '${state.timeline.position.inMilliseconds}ms/${state.status.name}/'
    '${state.videoTracks.map((t) => t.id).join(',')}/'
    'audio=${state.audioTracks.length}';
