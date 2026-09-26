import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';

const _highId = 'dash-video-w640-h360-b700000';
const _lowId = 'dash-video-w320-h180-b350000';
const _lowCaps = YlVideoConstraints(
  maxWidth: 320,
  maxHeight: 180,
  maxBitrate: 350000,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('fixed high survives reordered IDs then user auto and low', (
    tester,
  ) async {
    final server = await DashServer.start(variants: true);
    addTearDown(server.close);
    final player = await appleController(tester);
    _capability(player);
    final states = <YlPlayerState>[];
    final subscription = player.states.listen(states.add);
    addTearDown(subscription.cancel);
    final session = await player.load(
      YlNetworkSource(server.explicitUri, format: YlMediaFormat.dash),
    );
    final ready = await _readyPaused(player, session);
    _expectMode(ready, null, YlVideoSelectionReason.initial);
    _expectCatalog(ready, {_lowId, _highId});
    _audioReady(ready);
    await session.selectVideoTrack(_highId);
    final installed = await _state(player, session, (s) => _fixedHigh(s));
    _expectCatalog(installed, {_lowId, _highId});
    final roots = _roots(server);
    expect(roots, 1);

    await session.play();
    final high = await _state(
      player,
      session,
      (s) =>
          _fixedHigh(s) &&
          s.timeline.position < const Duration(seconds: 4) &&
          _size(s) == '640x360' &&
          _hasAudio(s) &&
          s.timeline.position > const Duration(milliseconds: 300),
    );
    _audioReady(high);
    final highStart = states.indexOf(high);
    expect(highStart, greaterThanOrEqualTo(0));
    final laterHigh = await _state(
      player,
      session,
      (s) =>
          _fixedHigh(s) &&
          s.timeline.position > const Duration(milliseconds: 4500) &&
          _size(s) == '640x360',
    );
    await session.pause();
    await _state(player, session, _nonplaying);
    final fixedEnd = states.length;
    _audit(states, session.id, end: fixedEnd);
    _auditHighGeometry(states, highStart, fixedEnd);
    expect(
      server.childRequests.any((r) => r.path.startsWith('/period1/chunk-1-')),
      isTrue,
    );
    expect(_roots(server), roots);

    await session.selectVideoTrack(null);
    final automatic = await _state(
      player,
      session,
      (s) =>
          s.videoSelection.isAutomatic &&
          s.videoSelection.reason == YlVideoSelectionReason.user &&
          _nonplaying(s),
    );
    _expectCatalog(automatic, {_lowId, _highId});
    await session.selectVideoTrack(_lowId);
    final lowInstalled = await _state(
      player,
      session,
      (s) => _fixedLow(s) && _nonplaying(s),
    );
    _expectCatalog(lowInstalled, {_lowId, _highId});
    await session.play();
    final low = await _state(
      player,
      session,
      (s) =>
          _fixedLow(s) &&
          _size(s) == '320x180' &&
          _hasAudio(s) &&
          s.timeline.position >
              laterHigh.timeline.position + const Duration(milliseconds: 300),
    );
    _audioReady(low);
    _audit(states, session.id);
    expect(_roots(server), roots);
    debugPrint(
      'APPLE_FIXED_RETAIN firstHigh=${high.timeline.position.inMilliseconds}ms '
      'period1High=${laterHigh.timeline.position.inMilliseconds}ms '
      'low=${low.timeline.position.inMilliseconds}ms states=${states.length} roots=$roots',
    );
    await _stopReset(player, states, session.id);
  });

  testWidgets('fixed high rejects conflicting caps then auto permits low cap', (
    tester,
  ) async {
    final server = await DashServer.start(variants: true);
    addTearDown(server.close);
    final player = await appleController(tester);
    _capability(player);
    final states = <YlPlayerState>[];
    final subscription = player.states.listen(states.add);
    addTearDown(subscription.cancel);
    final session = await player.load(YlNetworkSource(server.automaticUri));
    final ready = await _readyPaused(player, session);
    _audioReady(ready);
    await session.selectVideoTrack(_highId);
    await session.play();
    final high = await _state(
      player,
      session,
      (s) =>
          _fixedHigh(s) &&
          _size(s) == '640x360' &&
          _hasAudio(s) &&
          s.timeline.position > const Duration(milliseconds: 300) &&
          s.timeline.position < const Duration(seconds: 4),
    );
    final highStart = states.indexOf(high);
    await session.pause();
    final paused = await _state(
      player,
      session,
      (s) => _fixedHigh(s) && _nonplaying(s),
    );
    final roots = _roots(server);
    expect(roots, 1);
    final beforeReject = states.length;
    await expectLater(
      session.setVideoConstraints(_lowCaps),
      failureCode(YlFailureCodes.qualityConstraintUnsupported),
    );
    final rejectedStates = states.length - beforeReject;
    expect(player.state.videoSelection.fixedTrackId, _highId);
    _expectCatalog(player.state, {_lowId, _highId});
    _audit(states, session.id);
    _auditHighGeometry(states, highStart, states.length);
    expect(_roots(server), roots);

    await session.play();
    final stillHigh = await _state(
      player,
      session,
      (s) =>
          _fixedHigh(s) &&
          _size(s) == '640x360' &&
          s.timeline.position >
              paused.timeline.position + const Duration(milliseconds: 350),
    );
    await session.pause();
    await _state(player, session, (s) => _fixedHigh(s) && _nonplaying(s));
    final fixedEnd = states.length;
    _auditHighGeometry(states, highStart, fixedEnd);
    await session.selectVideoTrack(null);
    final automatic = await _state(
      player,
      session,
      (s) =>
          s.videoSelection.isAutomatic &&
          s.videoSelection.reason == YlVideoSelectionReason.user &&
          _nonplaying(s),
    );
    await session.setVideoConstraints(_lowCaps);
    final capped = await _state(
      player,
      session,
      (s) =>
          s.videoSelection.isAutomatic &&
          s.videoSelection.reason == YlVideoSelectionReason.user &&
          s.videoTracks.length == 1 &&
          s.videoTracks.single.id == _lowId &&
          _nonplaying(s) &&
          _hasAudio(s),
    );
    _audioReady(capped);
    final beforeInvalid = states.length;
    await expectLater(
      session.selectVideoTrack(_highId),
      failureCode('policy.video_selection_unsupported'),
    );
    final invalidStates = states.length - beforeInvalid;
    expect(player.state.videoSelection.isAutomatic, isTrue);
    _expectCatalog(player.state, {_lowId});
    await session.play();
    final low = await _state(
      player,
      session,
      (s) =>
          s.videoSelection.isAutomatic &&
          _size(s) == '320x180' &&
          _hasAudio(s) &&
          s.timeline.position >
              stillHigh.timeline.position + const Duration(milliseconds: 300),
    );
    _audioReady(low);
    _audit(states, session.id);
    _auditAutomatic(
      states,
      states.indexOf(automatic),
      YlVideoSelectionReason.user,
    );
    expect(_roots(server), roots);
    debugPrint(
      'APPLE_FIXED_CAPS high=${high.timeline.position.inMilliseconds}ms '
      'continuedHigh=${stillHigh.timeline.position.inMilliseconds}ms '
      'low=${low.timeline.position.inMilliseconds}ms '
      'rejectionStates=$rejectedStates invalidStates=$invalidStates '
      'roots=$roots',
    );
    await _stopReset(player, states, session.id);
  });

  testWidgets('missing high naturally falls back and stays auto after seek', (
    tester,
  ) async {
    final manifest = await rootBundle.loadString(
      'assets/test_media/dash_variants/manifest_missing_high.mpd',
    );
    final server = await DashServer.start(
      variants: true,
      manifestOverride: manifest,
    );
    addTearDown(server.close);
    final player = await appleController(tester);
    _capability(player);
    final states = <YlPlayerState>[];
    final subscription = player.states.listen(states.add);
    addTearDown(subscription.cancel);
    final session = await player.load(
      YlNetworkSource(server.explicitUri, format: YlMediaFormat.dash),
    );
    final ready = await _readyPaused(player, session);
    _audioReady(ready);
    await session.selectVideoTrack(_highId);
    await session.play();
    final high = await _state(
      player,
      session,
      (s) =>
          _fixedHigh(s) &&
          _size(s) == '640x360' &&
          _hasAudio(s) &&
          s.timeline.position > const Duration(milliseconds: 300) &&
          s.timeline.position < const Duration(seconds: 4),
    );
    final highStart = states.indexOf(high);
    final fallbackLow = await _state(
      player,
      session,
      (s) =>
          s.videoSelection.isAutomatic &&
          s.videoSelection.reason == YlVideoSelectionReason.trackUnavailable &&
          s.timeline.position > const Duration(milliseconds: 4500) &&
          _size(s) == '320x180' &&
          _hasAudio(s),
    );
    _audioReady(fallbackLow);
    final fallbackIndex = states.indexWhere(
      (s) => s.videoSelection.reason == YlVideoSelectionReason.trackUnavailable,
      highStart + 1,
    );
    expect(fallbackIndex, greaterThan(highStart));
    expect(
      states[fallbackIndex].timeline.position,
      greaterThanOrEqualTo(const Duration(seconds: 4)),
    );
    _auditHighGeometry(states, highStart, fallbackIndex);
    _audit(states, session.id);
    final roots = _roots(server);
    expect(roots, 1);
    expect(
      server.childRequests.any((r) => r.path.startsWith('/period1/chunk-0-')),
      isTrue,
    );

    await session.pause();
    await session.seekTo(const Duration(seconds: 1));
    final back = await _state(
      player,
      session,
      (s) =>
          s.videoSelection.isAutomatic &&
          s.videoSelection.reason == YlVideoSelectionReason.trackUnavailable &&
          _near(s.timeline.position, const Duration(seconds: 1)) &&
          _nonplaying(s),
    );
    _expectCatalog(back, {_lowId, _highId});
    await session.setVideoConstraints(_lowCaps);
    final capped = await _state(
      player,
      session,
      (s) =>
          s.videoSelection.isAutomatic &&
          s.videoSelection.reason == YlVideoSelectionReason.trackUnavailable &&
          s.videoTracks.length == 1 &&
          s.videoTracks.single.id == _lowId &&
          _nonplaying(s) &&
          _hasAudio(s),
    );
    _audioReady(capped);
    await session.play();
    final firstPeriodLow = await _state(
      player,
      session,
      (s) =>
          s.videoSelection.isAutomatic &&
          s.videoSelection.reason == YlVideoSelectionReason.trackUnavailable &&
          _size(s) == '320x180' &&
          s.timeline.position >
              back.timeline.position + const Duration(milliseconds: 400) &&
          s.timeline.position < const Duration(seconds: 4),
    );
    _audit(states, session.id);
    for (final state in states.skip(fallbackIndex)) {
      expect(
        state.videoSelection.isAutomatic,
        isTrue,
        reason: 'sticky fallback revision ${state.revision}',
      );
      expect(
        state.videoSelection.reason,
        YlVideoSelectionReason.trackUnavailable,
      );
    }
    expect(_roots(server), roots);
    debugPrint(
      'APPLE_FIXED_MISSING high=${high.timeline.position.inMilliseconds}ms '
      'fallbackAt=${states[fallbackIndex].timeline.position.inMilliseconds}ms '
      'low=${fallbackLow.timeline.position.inMilliseconds}ms '
      'back=${back.timeline.position.inMilliseconds}ms '
      'firstPeriodLow=${firstPeriodLow.timeline.position.inMilliseconds}ms '
      'states=${states.length} roots=$roots',
    );
    await _stopReset(player, states, session.id);
  });
}

void _capability(YlPlayerController player) => expect(
  player.capabilities.supportedOperations,
  contains(YlPlayerOperation.videoTrackSelection),
);

Future<YlPlayerState> _readyPaused(
  YlPlayerController player,
  YlPlaybackSession session,
) async {
  await session.ready.timeout(const Duration(seconds: 15));
  await session.pause();
  final ready = await _state(
    player,
    session,
    (s) => _nonplaying(s) && s.videoTracks.isNotEmpty && _hasAudio(s),
  );
  expect(ready.timeline.duration, const Duration(seconds: 8));
  return ready;
}

Future<YlPlayerState> _state(
  YlPlayerController player,
  YlPlaybackSession session,
  bool Function(YlPlayerState) matches,
) => stateWhere(player, (s) => s.sessionId == session.id && matches(s));

bool _fixedHigh(YlPlayerState s) =>
    s.videoSelection.fixedTrackId == _highId &&
    s.videoSelection.reason == YlVideoSelectionReason.user;
bool _fixedLow(YlPlayerState s) =>
    s.videoSelection.fixedTrackId == _lowId &&
    s.videoSelection.reason == YlVideoSelectionReason.user;
bool _nonplaying(YlPlayerState s) =>
    s.status == YlPlaybackStatus.ready || s.status == YlPlaybackStatus.paused;
bool _hasAudio(YlPlayerState s) =>
    s.audioTracks.length == 1 &&
    s.audioTracks.single.kind == YlTrackKind.audio &&
    s.audioTracks.single.isSelected;
void _audioReady(YlPlayerState s) => expect(_hasAudio(s), isTrue);
bool _near(Duration a, Duration b) => (a - b).inMilliseconds.abs() <= 300;
String? _size(YlPlayerState s) {
  final size = s.videoGeometry?.displaySize;
  return size == null ? null : '${size.width.round()}x${size.height.round()}';
}

int _roots(DashServer server) => server.requests
    .where((r) => r.path == '/manifest.mpd' || r.path == '/explicit')
    .length;

void _expectMode(YlPlayerState s, String? id, YlVideoSelectionReason reason) {
  expect(s.videoSelection.fixedTrackId, id);
  expect(s.videoSelection.reason, reason);
}

void _expectCatalog(YlPlayerState s, Set<String> ids) =>
    expect(s.videoTracks.map((t) => t.id).toSet(), ids);

void _audit(List<YlPlayerState> states, YlPlaybackSessionId id, {int? end}) {
  final emitted = states.take(end ?? states.length).toList();
  final firstSessionState = emitted.indexWhere((s) => s.sessionId == id);
  expect(firstSessionState, greaterThanOrEqualTo(0));
  // Controller setup can emit an idle state before Load creates this session.
  final slice = emitted.skip(firstSessionState).toList();
  expect(slice, isNotEmpty);
  expect(slice.where((s) => s.videoSelection.fixedTrackId != null), isNotEmpty);
  var engineEstablished = false;
  for (final s in slice) {
    expect(s.sessionId, id, reason: 'revision ${s.revision}');
    // The Load-paired loading state precedes AVPlayer engine assignment.
    if (s.engine == YlPlaybackEngine.avPlayer) engineEstablished = true;
    expect(
      s.engine,
      engineEstablished ? YlPlaybackEngine.avPlayer : YlPlaybackEngine.unknown,
      reason: 'revision ${s.revision}',
    );
    expect(s.failure, isNull, reason: 'revision ${s.revision}');
    final fixedId = s.videoSelection.fixedTrackId;
    if (fixedId != null) {
      expect(
        s.videoSelection.reason,
        YlVideoSelectionReason.user,
        reason: 'revision ${s.revision}',
      );
      expect(
        s.videoTracks.any((t) => t.id == fixedId),
        isTrue,
        reason: 'revision ${s.revision}',
      );
    }
    for (final track in s.videoTracks) {
      expect(track.isSelected, isFalse, reason: 'revision ${s.revision}');
    }
  }
  expect(engineEstablished, isTrue);
}

void _auditHighGeometry(List<YlPlayerState> states, int start, int end) {
  expect(start, greaterThanOrEqualTo(0));
  expect(end, greaterThan(start));
  for (final s in states.skip(start).take(end - start)) {
    expect(
      _fixedHigh(s),
      isTrue,
      reason:
          'fixed interval revision ${s.revision} at ${s.timeline.position.inMilliseconds}ms',
    );
    _expectCatalog(s, {_lowId, _highId});
    if (s.videoGeometry != null) {
      expect(
        _size(s),
        '640x360',
        reason:
            'fixed high revision ${s.revision} at ${s.timeline.position.inMilliseconds}ms',
      );
    }
  }
}

void _auditAutomatic(
  List<YlPlayerState> states,
  int start,
  YlVideoSelectionReason reason,
) {
  expect(start, greaterThanOrEqualTo(0));
  expect(states.length, greaterThan(start));
  for (final s in states.skip(start)) {
    expect(
      s.videoSelection.isAutomatic,
      isTrue,
      reason: 'automatic interval revision ${s.revision}',
    );
    expect(
      s.videoSelection.reason,
      reason,
      reason: 'automatic interval revision ${s.revision}',
    );
  }
}

Future<void> _stopReset(
  YlPlayerController player,
  List<YlPlayerState> states,
  YlPlaybackSessionId id,
) async {
  await player.stop();
  final stopped = await stateWhere(
    player,
    (s) => s.sessionId == null && s.status == YlPlaybackStatus.idle,
  );
  expect(stopped.videoTracks, isEmpty);
  expect(stopped.videoSelection.isAutomatic, isTrue);
  expect(stopped.videoSelection.reason, YlVideoSelectionReason.initial);
  expect(states.where((s) => s.sessionId == id), isNotEmpty);
}
