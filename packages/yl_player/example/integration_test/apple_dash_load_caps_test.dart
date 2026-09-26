import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';

const _cap = YlVideoConstraints(
  maxWidth: 320,
  maxHeight: 180,
  maxBitrate: 350000,
);
const _capOptions = YlLoadOptions(videoConstraints: _cap);
const _redactionSentinel = 'dash-cap-redaction-probe-740b';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Load cap keeps both DASH Periods at decoded 320x180', (
    tester,
  ) async {
    final server = await DashServer.start(variants: true);
    addTearDown(server.close);
    final player = await appleController(tester);
    final events = _events(player);
    final session = await player.load(
      YlNetworkSource(server.automaticUri),
      options: _capOptions,
    );
    final naturalPositions = <Duration>[];
    final sizes = <String>{};
    final states = player.states.listen((state) {
      if (state.sessionId != session.id) {
        return;
      }
      naturalPositions.add(state.timeline.position);
      final size = state.videoGeometry?.displaySize;
      if (size != null) {
        sizes.add('${size.width.round()}x${size.height.round()}');
      }
    });
    addTearDown(states.cancel);

    await readyAndPlay(player, session);
    expect(_firstFrames(events, session), isNotEmpty);
    expect(player.state.engine, YlPlaybackEngine.avPlayer);
    _expectAutomaticInitial(player.state);
    _expectSize(player.state, '320x180');
    _eightSeconds(player.state);
    final natural = await stateWhere(
      player,
      (state) =>
          state.sessionId == session.id &&
          state.timeline.position > const Duration(milliseconds: 4500),
    );
    _expectAutomaticInitial(natural);
    _expectSize(natural, '320x180');
    await states.cancel();
    expect(naturalPositions.any((p) => p < const Duration(seconds: 4)), isTrue);
    for (var index = 1; index < naturalPositions.length; index++) {
      expect(
        naturalPositions[index],
        greaterThanOrEqualTo(naturalPositions[index - 1]),
      );
    }

    final seekSamples = <int>[];
    for (final (second, upper) in [(5, 8), (1, 4)]) {
      await session.pause();
      await session.seekTo(Duration(seconds: second));
      await stateWhere(
        player,
        (state) =>
            state.sessionId == session.id &&
            (state.timeline.position - Duration(seconds: second)).inMilliseconds
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
            state.timeline.position < Duration(seconds: upper),
      );
      _expectAutomaticInitial(resumed);
      _expectSize(resumed, '320x180');
      seekSamples.add(resumed.timeline.position.inMilliseconds);
    }
    final completed = await stateWhere(
      player,
      (state) =>
          state.sessionId == session.id &&
          state.status == YlPlaybackStatus.completed,
    );
    _expectAutomaticInitial(completed);
    _expectSize(completed, '320x180');
    expect(
      completed.timeline.position,
      greaterThanOrEqualTo(const Duration(milliseconds: 7500)),
    );
    expect(sizes, {'320x180'});
    for (final period in [0, 1]) {
      _expectTrackFetched(server, period, 0);
      _expectTrackFetched(server, period, 2);
      expect(
        server.childRequests.where(
          (r) =>
              r.path.startsWith('/period$period/init-1') ||
              r.path.startsWith('/period$period/chunk-1-'),
        ),
        isEmpty,
      );
    }
    expect(_failures(events, session), isEmpty);
    debugPrint(
      'DASH Load cap: geometry=$sizes natural=${naturalPositions.first.inMilliseconds}..${naturalPositions.last.inMilliseconds}ms seek5=${seekSamples[0]}ms seek1=${seekSamples[1]}ms completed=${completed.timeline.position.inMilliseconds}ms requests=${server.childRequests.map((r) => r.path).toList()}',
    );
  });

  testWidgets('rejected capped Load leaves the old session playing', (
    tester,
  ) async {
    final oldServer = await DashServer.start(variants: true);
    final manifest = await _manifest('manifest_high_to_low.mpd');
    final candidate = await DashServer.start(
      variants: true,
      delayManifest: true,
      manifestOverride: manifest,
    );
    addTearDown(oldServer.close);
    addTearDown(candidate.close);
    final player = await appleController(tester);
    final events = _events(player);
    final old = await player.load(
      YlNetworkSource(oldServer.automaticUri),
      options: _capOptions,
    );
    await readyAndPlay(player, old);
    _expectSize(player.state, '320x180');
    final rejected = expectLater(
      player.load(
        YlNetworkSource(candidate.automaticUri),
        options: _capOptions,
      ),
      failureCode(YlFailureCodes.qualityConstraintUnsupported),
    );
    await candidate.manifestEntered.timeout(const Duration(seconds: 5));
    final before = player.state.timeline.position;
    await stateWhere(
      player,
      (state) =>
          state.sessionId == old.id &&
          state.timeline.position > before + const Duration(milliseconds: 300),
    );
    await old.pause();
    await old.play();
    candidate.releaseDelayedManifest();
    await rejected;
    expect(candidate.childRequests, isEmpty);
    expect(player.state.sessionId, old.id);
    final after = player.state.timeline.position;
    final resumed = await stateWhere(
      player,
      (state) =>
          state.sessionId == old.id &&
          state.timeline.position > after + const Duration(milliseconds: 300),
    );
    _expectSize(resumed, '320x180');
    _expectAutomaticInitial(resumed);
    expect(_firstFrames(events, old), isNotEmpty);
    expect(
      events.whereType<YlFirstFrameEvent>().every((e) => e.sessionId == old.id),
      isTrue,
    );
    expect(_failures(events, old), isEmpty);
    expect(player.state.failure, isNull);
    debugPrint(
      'DASH rejected cap Load: old=${before.inMilliseconds}..${resumed.timeline.position.inMilliseconds}ms oldGeometry=${_size(resumed)} candidateMediaRequests=${candidate.childRequests.length}',
    );
  });

  testWidgets(
    'same cap is idempotent; changed or cleared cap requires new Load',
    (tester) async {
      final constrained = await DashServer.start(variants: true);
      final highToLow = await DashServer.start(
        variants: true,
        manifestOverride: await _manifest('manifest_high_to_low.mpd'),
      );
      addTearDown(constrained.close);
      addTearDown(highToLow.close);
      final player = await appleController(tester);
      final events = _events(player);
      final old = await player.load(
        YlNetworkSource(constrained.automaticUri),
        options: _capOptions,
      );
      await readyAndPlay(player, old);
      await old.setVideoConstraints(_cap);
      await expectLater(
        old.setVideoConstraints(
          const YlVideoConstraints(maxWidth: 160, maxHeight: 90),
        ),
        failureCode(YlFailureCodes.videoConstraintsReloadRequired),
      );
      await expectLater(
        old.setVideoConstraints(const YlVideoConstraints()),
        failureCode(YlFailureCodes.videoConstraintsReloadRequired),
      );
      final before = player.state.timeline.position;
      final continued = await stateWhere(
        player,
        (state) =>
            state.sessionId == old.id &&
            state.timeline.position >
                before + const Duration(milliseconds: 300),
      );
      _expectAutomaticInitial(continued);
      _expectSize(continued, '320x180');
      expect(_failures(events, old), isEmpty);

      final fresh = await player.load(YlNetworkSource(highToLow.automaticUri));
      await readyAndPlay(player, fresh);
      final high = await stateWhere(
        player,
        (state) =>
            state.sessionId == fresh.id &&
            state.timeline.position < const Duration(seconds: 4) &&
            _hasSize(state, '640x360'),
      );
      _expectAutomaticInitial(high);
      _expectSize(high, '640x360');
      _expectTrackFetched(highToLow, 0, 1);
      expect(_firstFrames(events, fresh), isNotEmpty);
      expect(_failures(events, fresh), isEmpty);
      debugPrint(
        'DASH cap mutation: old=${continued.timeline.position.inMilliseconds}ms geometry=${_size(continued)} new=${high.timeline.position.inMilliseconds}ms geometry=${_size(high)} newRequests=${highToLow.childRequests.map((r) => r.path).toList()}',
      );
    },
  );

  testWidgets('oversized decoded frame fails without firstFrame', (
    tester,
  ) async {
    var lying = await _manifest('manifest_high_to_low.mpd');
    lying = lying.replaceFirst(
      'bandwidth="700000" width="640" height="360"',
      'bandwidth="350000" width="320" height="180"',
    );
    lying = lying.replaceFirst(
      'initialization="init-0.m4s" media="chunk-0-',
      'initialization="init-1.m4s" media="chunk-1-',
    );
    final server = await DashServer.start(
      variants: true,
      manifestOverride: lying,
    );
    addTearDown(server.close);
    final player = await appleController(tester);
    final events = _events(player);
    final session = await player.load(
      YlNetworkSource(
        server.automaticUri,
        request: YlHttpRequest(
          credentials: {'Authorization': 'Bearer $_redactionSentinel'},
        ),
      ),
      options: _capOptions,
    );
    // Attach the error handler before ready/play: a rejected first buffer fails this future.
    final firstFramePublished = session.firstFrame.then<bool>(
      (_) => true,
      onError: (Object error, StackTrace stack) => false,
    );
    final failureEvent = player.events
        .where(
          (event) =>
              event is YlPlaybackFailedEvent && event.sessionId == session.id,
        )
        .cast<YlPlaybackFailedEvent>()
        .first
        .timeout(const Duration(seconds: 15));
    await session.ready.timeout(const Duration(seconds: 15));
    try {
      await session.play();
    } on YlPlayerException catch (error) {
      // The oversized first buffer can fail the session before play is acked.
      expect(error.failure.code, 'session.failed');
    }
    final failed = await stateWhere(
      player,
      (state) =>
          state.sessionId == session.id &&
          state.status == YlPlaybackStatus.failed,
    );
    expect(failed.failure?.code, YlFailureCodes.qualityConstraintUnsupported);
    expect(
      await firstFramePublished.timeout(const Duration(seconds: 15)),
      isFalse,
    );
    final observedFailureEvent = await failureEvent;
    expect(
      observedFailureEvent.failure.code,
      YlFailureCodes.qualityConstraintUnsupported,
    );
    expect(_firstFrames(events, session), isEmpty);
    expect(
      _failures(events, session).map((e) => e.failure.code),
      contains(YlFailureCodes.qualityConstraintUnsupported),
    );
    expect(
      server.childRequests.any((r) => r.path == '/period0/init-1.m4s'),
      isTrue,
    );
    expect(
      server.childRequests.any((r) => r.path.startsWith('/period0/chunk-1-')),
      isTrue,
    );
    expect(
      server.requests.any(
        (r) => r.header('authorization') == 'Bearer $_redactionSentinel',
      ),
      isTrue,
    );
    _expectPublicFailureRedacted(failed.failure!, server.automaticUri.origin);
    _expectPublicFailureRedacted(
      observedFailureEvent.failure,
      server.automaticUri.origin,
    );
    debugPrint(
      'DASH lying MPD: session failure=${failed.failure?.code} firstFrame=false requestedHighBytes=${server.childRequests.map((r) => r.path).toList()}',
    );
  });
}

Future<String> _manifest(String name) =>
    rootBundle.loadString('assets/test_media/dash_variants/$name');

List<YlPlayerEvent> _events(YlPlayerController player) {
  final events = <YlPlayerEvent>[];
  final subscription = player.events.listen(events.add);
  addTearDown(subscription.cancel);
  return events;
}

Iterable<YlFirstFrameEvent> _firstFrames(
  List<YlPlayerEvent> events,
  YlPlaybackSession session,
) => events.whereType<YlFirstFrameEvent>().where(
  (e) => e.sessionId == session.id,
);

Iterable<YlPlaybackFailedEvent> _failures(
  List<YlPlayerEvent> events,
  YlPlaybackSession session,
) => events.whereType<YlPlaybackFailedEvent>().where(
  (e) => e.sessionId == session.id,
);

void _expectAutomaticInitial(YlPlayerState state) {
  expect(state.videoSelection.isAutomatic, isTrue);
  expect(state.videoSelection.reason, YlVideoSelectionReason.initial);
}

void _eightSeconds(YlPlayerState state) {
  expect(state.timeline.duration, isNotNull);
  expect(
    (state.timeline.duration! - const Duration(seconds: 8)).inMilliseconds
        .abs(),
    lessThanOrEqualTo(50),
  );
}

bool _hasSize(YlPlayerState state, String expected) =>
    state.videoGeometry != null && _size(state) == expected;

String _size(YlPlayerState state) {
  final size = state.videoGeometry!.displaySize;
  return '${size.width.round()}x${size.height.round()}';
}

void _expectSize(YlPlayerState state, String expected) {
  expect(state.videoGeometry, isNotNull);
  expect(_size(state), expected);
}

void _expectTrackFetched(DashServer server, int period, int track) {
  expect(
    server.childRequests.any((r) => r.path == '/period$period/init-$track.m4s'),
    isTrue,
  );
  expect(
    server.childRequests.any(
      (r) => r.path.startsWith('/period$period/chunk-$track-'),
    ),
    isTrue,
  );
}

void _expectPublicFailureRedacted(YlFailure failure, String origin) {
  for (final value in [
    failure.message,
    failure.code,
    failure.diagnosticId,
    failure.toString(),
  ]) {
    // Compare booleans so an unexpected failure never prints an origin or header.
    expect(
      value.contains(origin),
      isFalse,
      reason: 'Public failure exposed origin',
    );
    expect(
      value.contains(_redactionSentinel),
      isFalse,
      reason: 'Public failure exposed credential',
    );
  }
}
