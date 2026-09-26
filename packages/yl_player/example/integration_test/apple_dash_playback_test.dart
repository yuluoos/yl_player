import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'package:integration_test/integration_test.dart';

import 'support/dash_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('DASH server explicit-end EOF range returns 416', (tester) async {
    final server = await DashServer.start();
    addTearDown(server.close);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(server.automaticUri);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=999999999-999999999');
    final response = await request.close().timeout(const Duration(seconds: 5));
    expect(response.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    expect(
      response.headers.value(HttpHeaders.contentRangeHeader),
      startsWith('bytes */'),
    );
    expect(
      await response.fold<int>(0, (total, bytes) => total + bytes.length),
      0,
    );
  });

  testWidgets(
    'explicit and automatic DASH render, cross Periods naturally, seek both ways and complete',
    (tester) async {
      final server = await DashServer.start();
      addTearDown(server.close);
      final player = await appleController(tester);
      final events = _events(player);
      final explicit = await player.load(
        YlNetworkSource(server.explicitUri, format: YlMediaFormat.dash),
      );
      await _render(player, explicit, events);
      _eightSeconds(player);
      await player.stop();
      final automatic = await player.load(YlNetworkSource(server.automaticUri));
      final naturalPositions = <Duration>[];
      final subscription = player.states.listen((state) {
        if (state.sessionId == automatic.id) {
          naturalPositions.add(state.timeline.position);
        }
      });
      addTearDown(subscription.cancel);
      await _render(player, automatic, events);
      await stateWhere(
        player,
        (s) => s.timeline.position > const Duration(milliseconds: 4500),
      );
      await subscription.cancel();
      expect(
        naturalPositions.any((p) => p < const Duration(seconds: 4)),
        isTrue,
      );
      expect(
        naturalPositions.last,
        greaterThan(const Duration(milliseconds: 4500)),
      );
      for (var i = 1; i < naturalPositions.length; i++) {
        expect(
          naturalPositions[i],
          greaterThanOrEqualTo(naturalPositions[i - 1]),
        );
      }
      _eightSeconds(player);
      expect(player.state.timeline.isSeekable, isTrue);
      for (final second in [5, 1]) {
        await automatic.pause();
        await automatic.seekTo(Duration(seconds: second));
        await stateWhere(
          player,
          (s) =>
              (s.timeline.position - Duration(seconds: second)).inMilliseconds
                  .abs() <=
              300,
        );
        await automatic.play();
        await stateWhere(
          player,
          (s) =>
              s.timeline.position > Duration(milliseconds: second * 1000 + 500),
        );
      }
      await stateWhere(player, (s) => s.status == YlPlaybackStatus.completed);
      expect(
        player.state.timeline.position,
        greaterThanOrEqualTo(const Duration(milliseconds: 7500)),
      );
      _eightSeconds(player);
      _bothPeriods(server);
      expect(events.whereType<YlPlaybackFailedEvent>(), isEmpty);
      debugPrint(
        'DASH timeline: duration=8000ms natural=${naturalPositions.first.inMilliseconds}..${naturalPositions.last.inMilliseconds}ms; seek5>5.5 seek1>1.5 completed=${player.state.timeline.position.inMilliseconds}ms; AVPlayer current-session firstFrame; audio+video both Periods fetched',
      );
    },
  );

  for (final mode in DashOriginMode.values) {
    testWidgets('DASH ${mode.name} credentials on every MPD/init/media request', (
      tester,
    ) async {
      final server = await DashServer.start(originMode: mode);
      addTearDown(server.close);
      final player = await appleController(tester);
      final events = _events(player);
      final session = await player.load(_credentialSource(server.automaticUri));
      await _render(player, session, events);
      await stateWhere(
        player,
        (s) => s.timeline.position > const Duration(milliseconds: 4500),
      );
      await session.pause();
      _bothPeriods(server);
      for (final request in server.requests) {
        expect(request.header('x-dash-client'), 'ordinary-test-value');
        _credentials(
          request,
          present:
              request.path == '/manifest.mpd' ||
              mode == DashOriginMode.sameOrigin,
        );
        if (request.path.endsWith('.m4s')) {
          expect(
            request.origin,
            mode == DashOriginMode.crossOrigin ? 'secondary' : 'primary',
          );
        }
      }
      expect(events.whereType<YlPlaybackFailedEvent>(), isEmpty);
      debugPrint(
        'DASH ${mode.name}: firstFrame + natural>4.5s; validated ${server.requests.length} requests including both audio/video Periods',
      );
    });
  }

  testWidgets(
    'MPD redirect A to B to A permanently strips descendant credentials',
    (tester) async {
      final server = await DashServer.start();
      addTearDown(server.close);
      final player = await appleController(tester);
      final events = _events(player);
      final session = await player.load(_credentialSource(server.redirectUri));
      await _render(player, session, events);
      await stateWhere(
        player,
        (s) => s.timeline.position > const Duration(milliseconds: 4500),
      );
      await session.pause();
      for (final path in [
        '/redirect.mpd',
        '/redirect-hop.mpd',
        '/manifest.mpd',
      ]) {
        expect(server.requestsFor(path), isNotEmpty);
      }
      _bothPeriods(server);
      debugPrint(
        'DASH redirect history: ${server.requests.map((r) => '${r.origin}${r.path} credentialPresent=${r.header('authorization') != null}').join(', ')}',
      );
      for (final request in server.requests) {
        expect(request.header('x-dash-client'), 'ordinary-test-value');
        // Reentered original roots must retain prior cross-origin stripping.
        _credentials(
          request,
          present: identical(request, server.requests.first),
        );
        expect(
          request.origin,
          request.path == '/redirect-hop.mpd' ? 'secondary' : 'primary',
        );
      }
      expect(events.whereType<YlPlaybackFailedEvent>(), isEmpty);
      debugPrint(
        'DASH redirect primary/redirect.mpd -> secondary/redirect-hop.mpd -> primary/manifest.mpd: ${server.requests.length} requests credential ancestry checked',
      );
    },
  );

  testWidgets(
    'malformed candidate preserves old session while pending and after rejection',
    (tester) async {
      final server = await DashServer.start();
      final candidateServer = await DashServer.start(
        delayManifest: true,
        manifestOverride: '<MPD><broken>',
      );
      addTearDown(server.close);
      addTearDown(candidateServer.close);
      final player = await appleController(tester);
      final events = _events(player);
      final old = await player.load(YlNetworkSource(server.automaticUri));
      await _render(player, old, events);
      final rejected = expectLater(
        player.load(YlNetworkSource(candidateServer.automaticUri)),
        failureCode(YlFailureCodes.dashManifestInvalid),
      );
      await candidateServer.manifestEntered.timeout(const Duration(seconds: 5));
      debugPrint('DASH invalid candidate: MPD entered');
      final before = player.state.timeline.position;
      await stateWhere(
        player,
        (s) =>
            s.sessionId == old.id &&
            s.timeline.position > before + const Duration(milliseconds: 300),
      );
      debugPrint('DASH invalid candidate: old advanced, pause');
      await old.pause();
      debugPrint('DASH invalid candidate: play old');
      await old.play();
      debugPrint('DASH invalid candidate: release malformed MPD');
      candidateServer.releaseDelayedManifest();
      await rejected;
      expect(player.state.sessionId, old.id);
      final after = player.state.timeline.position;
      await stateWhere(
        player,
        (s) =>
            s.sessionId == old.id &&
            s.timeline.position > after + const Duration(milliseconds: 300),
      );
      expect(
        events.whereType<YlFirstFrameEvent>().every(
          (e) => e.sessionId == old.id,
        ),
        isTrue,
      );
      expect(events.whereType<YlPlaybackFailedEvent>(), isEmpty);
      expect(player.state.failure, isNull);
    },
  );

  for (final replace in [false, true]) {
    testWidgets(
      'pending MPD ${replace ? 'rapid replacement' : 'stop'} suppresses late publication',
      (tester) async {
        final server = await DashServer.start();
        final held = await DashServer.start(delayManifest: true);
        addTearDown(server.close);
        addTearDown(held.close);
        final player = await appleController(tester);
        final events = _events(player);
        final old = await player.load(YlNetworkSource(server.automaticUri));
        await _render(player, old, events);
        final cancelled = expectLater(
          player.load(YlNetworkSource(held.automaticUri)),
          failureCode(YlFailureCodes.loadCancelled),
        );
        await held.manifestEntered.timeout(const Duration(seconds: 5));
        // Pause the accepted session before direct replacement so only the
        // replacement can legitimately publish events after this boundary.
        await old.pause();
        var stoppedIndex = events.length;
        YlPlaybackSession? replacement;
        if (replace) {
          replacement = await player.load(
            YlNetworkSource(server.explicitUri, format: YlMediaFormat.dash),
          );
          await _render(player, replacement, events);
        } else {
          await player.stop();
          stoppedIndex = events.length;
        }
        await cancelled;
        held.releaseDelayedManifest();
        await held.settle();
        await Future<void>.delayed(const Duration(milliseconds: 750));
        if (replace) {
          expect(player.state.sessionId, replacement!.id);
          expect(
            events
                .skip(stoppedIndex)
                .every((e) => e.sessionId == replacement!.id),
            isTrue,
          );
        } else {
          expect(events.skip(stoppedIndex), isEmpty);
          expect(player.state.sessionId, isNull);
        }
        expect(player.state.status, isNot(YlPlaybackStatus.failed));
        await expectLater(old.play(), failureCode(YlFailureCodes.sessionStale));
      },
    );
  }

  testWidgets(
    'committed DASH with held media stops and replacement receives no late old events',
    (tester) async {
      final held = await DashServer.start(delayMedia: true);
      final server = await DashServer.start();
      addTearDown(held.close);
      addTearDown(server.close);
      final player = await appleController(tester);
      final events = _events(player);
      final old = await player.load(YlNetworkSource(held.automaticUri));
      await old.play();
      await held.mediaEntered.timeout(const Duration(seconds: 10));
      await player.stop();
      final index = events.length;
      final replacement = await player.load(
        YlNetworkSource(server.automaticUri),
      );
      await _render(player, replacement, events);
      held.releaseDelayedMedia();
      await held.settle();
      await Future<void>.delayed(const Duration(milliseconds: 750));
      expect(player.state.sessionId, replacement.id);
      expect(
        events.skip(index).every((e) => e.sessionId == replacement.id),
        isTrue,
      );
      expect(events.skip(index).whereType<YlPlaybackFailedEvent>(), isEmpty);
      await expectLater(old.play(), failureCode(YlFailureCodes.sessionStale));
    },
  );

  testWidgets('DASH root 403 is sanitized and cannot publish a session', (
    tester,
  ) async {
    final server = await DashServer.start(rootStatusCode: 403);
    addTearDown(server.close);
    final player = await appleController(tester);
    final events = _events(player);
    final source = _credentialSource(
      server.automaticUri.replace(query: 'signature=private-query-sentinel'),
    );
    try {
      await player.load(source);
      fail('403 MPD unexpectedly loaded');
    } on YlPlayerException catch (error) {
      expect(error.failure.code, YlFailureCodes.networkHttpForbidden);
      _sanitized(error.failure, source.uri);
    }
    expect(server.requestsFor('/manifest.mpd'), isNotEmpty);
    expect(server.childRequests, isEmpty);
    expect(player.state.sessionId, isNull);
    expect(events.whereType<YlFirstFrameEvent>(), isEmpty);
  });

  testWidgets('missing DASH media produces a sanitized public failure', (
    tester,
  ) async {
    final server = await DashServer.start(missingMedia: true);
    addTearDown(server.close);
    final player = await appleController(tester);
    final events = _events(player);
    final source = _credentialSource(
      server.automaticUri.replace(query: 'signature=private-query-sentinel'),
    );
    YlFailure? failure;
    try {
      final session = await player.load(source);
      await session.play();
    } on YlPlayerException catch (error) {
      failure = error.failure;
    }
    if (failure == null) {
      final failed = player.state.status == YlPlaybackStatus.failed
          ? player.state
          : await player.states
                .firstWhere((s) => s.status == YlPlaybackStatus.failed)
                .timeout(const Duration(seconds: 45));
      failure = failed.failure;
    }
    expect(failure, isNotNull);
    expect(failure!.code, 'avplayer.first_frame_timeout');
    _sanitized(failure, source.uri);
    expect(
      server.childRequests.any((r) => r.path.endsWith('chunk-0-00001.m4s')),
      isTrue,
    );
    expect(events.whereType<YlFirstFrameEvent>(), isEmpty);
    debugPrint('DASH missing media HTTP404 public code=${failure.code}');
  });

  testWidgets(
    'DASH strict managed bounded and hardware policies reject before I/O',
    (tester) async {
      final server = await DashServer.start();
      final candidate = await DashServer.start();
      addTearDown(server.close);
      addTearDown(candidate.close);
      final player = await appleController(tester);
      final old = await player.load(YlNetworkSource(server.automaticUri));
      await readyAndPlay(player, old);
      await old.pause();
      for (final (network, options) in [
        (strictNetwork, const YlLoadOptions()),
        (
          const YlNetworkPolicy.platformDefault(),
          const YlLoadOptions(bufferStrategy: strictBuffer),
        ),
        (
          const YlNetworkPolicy.platformDefault(),
          const YlLoadOptions(
            decoderPolicyOverride: YlDecoderPolicy.hardwareRequired,
          ),
        ),
      ]) {
        await expectLater(
          player.load(
            YlNetworkSource(
              candidate.automaticUri,
              format: YlMediaFormat.dash,
              networkPolicy: network,
            ),
            options: options,
          ),
          failureCode(YlFailureCodes.policyUnsupported),
        );
        expect(candidate.requests, isEmpty);
        expect(player.state.sessionId, old.id);
      }
      await old.play();
      final before = player.state.timeline.position;
      await stateWhere(player, (s) => s.timeline.position > before);
    },
  );
}

List<YlPlayerEvent> _events(YlPlayerController player) {
  final events = <YlPlayerEvent>[];
  final subscription = player.events.listen(events.add);
  addTearDown(subscription.cancel);
  return events;
}

Future<void> _render(
  YlPlayerController player,
  YlPlaybackSession session,
  List<YlPlayerEvent> events,
) async {
  await readyAndPlay(player, session);
  expect(
    events.whereType<YlFirstFrameEvent>().any((e) => e.sessionId == session.id),
    isTrue,
  );
  expect(player.state.sessionId, session.id);
  expect(player.state.engine, YlPlaybackEngine.avPlayer);
  expect(player.state.videoGeometry?.displaySize.width, greaterThan(0));
  expect(player.state.videoGeometry?.displaySize.height, greaterThan(0));
  expect(player.state.audioTracks.any((t) => t.isSelected), isTrue);
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

void _bothPeriods(DashServer server) {
  for (final period in [0, 1]) {
    for (final track in [0, 1]) {
      expect(
        server.childRequests.any(
          (r) => r.path == '/period$period/init-$track.m4s',
        ),
        isTrue,
        reason: 'Period $period track $track initialization',
      );
      expect(
        server.childRequests.any(
          (r) => r.path.startsWith('/period$period/chunk-$track-'),
        ),
        isTrue,
        reason: 'Period $period track $track media',
      );
    }
  }
}

YlNetworkSource _credentialSource(Uri uri) => YlNetworkSource(
  uri,
  format: YlMediaFormat.dash,
  request: YlHttpRequest(
    headers: const {'X-Dash-Client': 'ordinary-test-value'},
    credentials: const {
      'Authorization': 'Bearer dash-test-credential',
      'Cookie': 'dash-session=test-only',
      'Proxy-Authorization': 'Basic dash-test-proxy',
      'X-Session': 'dash-custom-credential',
    },
  ),
);

void _credentials(RecordedDashRequest request, {required bool present}) {
  // Compare booleans so a mismatch never prints credential values.
  for (final (name, value) in [
    ('authorization', 'Bearer dash-test-credential'),
    ('cookie', 'dash-session=test-only'),
    ('proxy-authorization', 'Basic dash-test-proxy'),
    ('x-session', 'dash-custom-credential'),
  ]) {
    expect(
      present ? request.header(name) == value : request.header(name) == null,
      isTrue,
      reason:
          '${request.origin}${request.path}: $name presence must be $present',
    );
  }
}

void _sanitized(YlFailure failure, Uri uri) {
  final text =
      '${failure.code} ${failure.message} ${failure.diagnosticId} $failure';
  for (final secret in [
    'dash-test-credential',
    'dash-session',
    'dash-test-proxy',
    'dash-custom-credential',
    'private-query-sentinel',
    uri.toString(),
  ]) {
    expect(
      text.contains(secret),
      isFalse,
      reason: 'Public failure must omit private request data',
    );
  }
}
