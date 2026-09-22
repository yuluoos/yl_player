import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/android_test_support.dart';
import 'support/dash_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'explicit extensionless and automatic MPD render and preserve the eight-second Period timeline',
    (tester) async {
      final server = await DashServer.start();
      addTearDown(server.close);
      final player = await _createPlayer(tester);
      addTearDown(player.dispose);
      final frames = <YlFirstFrameEvent>[];
      final failures = <YlPlaybackFailedEvent>[];
      final frameSubscription = player.events
          .where((event) => event is YlFirstFrameEvent)
          .cast<YlFirstFrameEvent>()
          .listen(frames.add);
      addTearDown(frameSubscription.cancel);
      final failureSubscription = player.events
          .where((event) => event is YlPlaybackFailedEvent)
          .cast<YlPlaybackFailedEvent>()
          .listen(failures.add);
      addTearDown(failureSubscription.cancel);

      final explicit = await player.load(
        YlNetworkSource(server.explicitUri, format: YlMediaFormat.dash),
      );
      await explicit.play();
      await explicit.firstFrame.timeout(const Duration(seconds: 20));
      expect(frames.last.sessionId, explicit.id);
      expect(server.requestsFor('/explicit'), isNotEmpty);
      expect(player.state.engine, YlPlaybackEngine.media3);
      _expectEightSecondTimeline(player);
      await player.stop();

      final automatic = await player.load(YlNetworkSource(server.automaticUri));
      await automatic.play();
      await automatic.firstFrame.timeout(const Duration(seconds: 20));
      expect(frames.last.sessionId, automatic.id);
      expect(server.requestsFor('/manifest.mpd'), isNotEmpty);
      _expectEightSecondTimeline(player);
      expect(player.state.timeline.isSeekable, isTrue);
      await automatic.pause();
      await automatic.seekTo(const Duration(seconds: 5));
      await waitForState(
        player,
        (state) =>
            (state.timeline.position - const Duration(seconds: 5))
                .inMilliseconds
                .abs() <=
            300,
      );
      expect(
        player.state.timeline.position,
        greaterThan(const Duration(seconds: 4)),
      );
      await automatic.play();
      await waitForState(
        player,
        (state) => state.timeline.position > const Duration(milliseconds: 5500),
      );
      expect(
        server.childRequests.any(
          (request) => request.path.startsWith('/period1/chunk-0-'),
        ),
        isTrue,
        reason: 'Seek to program time 5s must load video from Period 2',
      );
      await waitForState(
        player,
        (state) => state.status == YlPlaybackStatus.completed,
      );
      expect(
        player.state.timeline.position,
        greaterThanOrEqualTo(const Duration(milliseconds: 7500)),
      );
      expect(failures, isEmpty);
      expect(
        server.childRequests.any((request) => request.path.contains('/init-')),
        isTrue,
      );
      expect(
        server.childRequests.any((request) => request.path.contains('/chunk-')),
        isTrue,
      );
    },
  );

  for (final mode in DashOriginMode.values) {
    testWidgets(
      'DASH ${mode.name} keeps ordinary headers and applies inherited credential policy',
      (tester) async {
        final server = await DashServer.start(originMode: mode);
        final player = await _createPlayer(tester);
        addTearDown(player.dispose);
        try {
          final session = await player.load(
            YlNetworkSource(
              server.automaticUri,
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
            ),
          );
          await session.play();
          await session.firstFrame.timeout(const Duration(seconds: 20));

          final manifest = server.requestsFor('/manifest.mpd');
          expect(manifest, isNotEmpty);
          _expectCredentials(manifest.first, present: true);
          final children = server.childRequests.toList(growable: false);
          expect(
            children.any((request) => request.path.contains('/init-')),
            isTrue,
          );
          expect(
            children.any((request) => request.path.contains('/chunk-')),
            isTrue,
          );
          for (final request in children) {
            expect(request.header('x-dash-client'), 'ordinary-test-value');
            expect(
              request.origin,
              mode == DashOriginMode.crossOrigin ? 'secondary' : 'primary',
            );
            _expectCredentials(
              request,
              present: mode == DashOriginMode.sameOrigin,
            );
          }
          expect(player.state.engine, YlPlaybackEngine.media3);
        } finally {
          await server.close();
        }
      },
    );
  }

  testWidgets('DASH segment HTTP failure becomes a public sanitized failure', (
    tester,
  ) async {
    final server = await DashServer.start(failMedia: true);
    addTearDown(server.close);
    final player = await _createPlayer(tester);
    addTearDown(player.dispose);
    final failedEvents = <YlPlaybackFailedEvent>[];
    final failureSubscription = player.events
        .where((event) => event is YlPlaybackFailedEvent)
        .cast<YlPlaybackFailedEvent>()
        .listen(failedEvents.add);
    addTearDown(failureSubscription.cancel);
    Object? loadError;
    YlPlaybackSession? session;
    try {
      session = await player.load(
        YlNetworkSource(
          server.automaticUri,
          format: YlMediaFormat.dash,
          request: YlHttpRequest(
            credentials: const {
              'Authorization': 'Bearer must-never-appear-publicly',
            },
          ),
        ),
      );
      await session.play();
    } catch (error) {
      loadError = error;
    }
    if (loadError == null) {
      await waitForState(
        player,
        (state) => state.status == YlPlaybackStatus.failed,
      );
    }
    if (loadError != null) {
      expect(loadError, isA<YlPlayerException>());
    }
    final failure = loadError == null
        ? failedEvents.single.failure
        : (loadError as YlPlayerException).failure;
    expect(failure.code, YlFailureCodes.networkHttpForbidden);
    expect(
      failure.message,
      'The media server refused the request. Check access credentials and request configuration.',
    );
    expect(failure.toString(), isNot(contains('must-never-appear-publicly')));
    expect(failure.toString(), isNot(contains(server.automaticUri.toString())));
    expect(
      server.childRequests.any(
        (request) => request.path.endsWith('chunk-0-00001.m4s'),
      ),
      isTrue,
    );
  });

  testWidgets('stopping delayed DASH suppresses old-session events', (
    tester,
  ) async {
    final readyServer = await DashServer.start();
    final delayedServer = await DashServer.start(delayMedia: true);
    addTearDown(readyServer.close);
    addTearDown(delayedServer.close);
    final player = await _createPlayer(tester);
    addTearDown(player.dispose);
    final current = await player.load(
      YlNetworkSource(readyServer.automaticUri, format: YlMediaFormat.dash),
    );
    await current.play();
    await current.firstFrame.timeout(const Duration(seconds: 20));
    final pending = player.load(
      YlNetworkSource(delayedServer.automaticUri, format: YlMediaFormat.dash),
    );
    final cancelled = expectLater(
      pending,
      throwsA(failureCode(YlFailureCodes.loadCancelled)),
    );
    final publishedAfterStop = <YlPlayerEvent>[];
    await _waitForRequest(
      delayedServer,
      (request) => request.path.endsWith('chunk-0-00001.m4s'),
    );
    await player.stop();
    await cancelled;
    final subscription = player.events.listen(publishedAfterStop.add);
    addTearDown(subscription.cancel);
    delayedServer.releaseDelayedMedia();
    await Future<void>.delayed(const Duration(milliseconds: 750));
    expect(publishedAfterStop, isEmpty);
    expect(player.state.status, isNot(YlPlaybackStatus.failed));
    await expectLater(
      current.play(),
      throwsA(failureCode(YlFailureCodes.sessionStale)),
    );
  });
}

Future<YlPlayerController> _createPlayer(WidgetTester tester) async {
  final player = await YlPlayerController.create();
  await tester.pumpWidget(MaterialApp(home: YlPlayerView(controller: player)));
  expect(
    player.capabilities.availableEngines,
    contains(YlPlaybackEngine.media3),
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

void _expectCredentials(RecordedDashRequest request, {required bool present}) {
  expect(
    request.header('authorization'),
    present ? 'Bearer dash-test-credential' : isNull,
  );
  expect(request.header('cookie'), present ? 'dash-session=test-only' : isNull);
  expect(
    request.header('proxy-authorization'),
    present ? 'Basic dash-test-proxy' : isNull,
  );
  expect(
    request.header('x-session'),
    present ? 'dash-custom-credential' : isNull,
  );
}

Future<void> _waitForRequest(
  DashServer server,
  bool Function(RecordedDashRequest request) predicate,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!server.requests.any(predicate)) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'Timed out waiting for DASH request; paths: ${server.requests.map((r) => r.path).join(', ')}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}
