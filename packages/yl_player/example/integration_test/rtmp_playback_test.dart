import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/android_frame_observation.dart';
import 'support/apple_strict_support.dart';

const host = String.fromEnvironment('YL_RTMP_HOST', defaultValue: '127.0.0.1');
Uri endpoint([String path = 'owned']) =>
    Uri.parse('rtmp://$host:19351/live/$path');
Future<Map<String, dynamic>> control(String operation) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('http://$host:19352/$operation'),
    );
    final response = await request.close().timeout(const Duration(seconds: 5));
    expect(response.statusCode, 200);
    final result =
        jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
    expect(result['errors'], isEmpty);
    return result;
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> peerWhere(
  bool Function(Map<String, dynamic>) match,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  do {
    final result = await control('stats');
    if (match(result)) return result;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  } while (DateTime.now().isBefore(deadline));
  throw StateError('Peer observation deadline');
}

Future<void> advance(
  YlPlayerController player, {
  int milliseconds = 3000,
}) async {
  await stateWhere(player, (s) => s.timeline.position > Duration.zero);
  final start = player.state.timeline.position;
  final wall = Stopwatch()..start();
  await Future<void>.delayed(Duration(milliseconds: milliseconds));
  await stateWhere(
    player,
    (s) => s.timeline.position >= start + Duration(milliseconds: milliseconds),
  );
  debugPrint(
    'RTMP advance ${start.inMilliseconds} -> ${player.state.timeline.position.inMilliseconds}; wall=${wall.elapsedMilliseconds}ms mediaClock=${player.state.metrics.mediaClockPosition}',
  );
}

Future<YlPlaybackSession> render(
  YlPlayerController player, [
  String path = 'owned',
]) async {
  final events = <YlPlayerEvent>[];
  final sub = player.events.listen(events.add);
  try {
    final session = await player.load(YlNetworkSource(endpoint(path)));
    await readyAndPlay(player, session);
    expect(
      events.whereType<YlFirstFrameEvent>().any(
        (e) => e.sessionId == session.id,
      ),
      isTrue,
    );
    expect(player.state.timeline.isLive, isTrue);
    expect(player.state.timeline.isSeekable, isFalse);
    expect(player.state.timeline.duration, isNull);
    expect(player.state.videoGeometry, isNotNull);
    expect(player.state.audioTracks.isNotEmpty, path == 'owned');
    return session;
  } finally {
    await sub.cancel();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await control('normal');
    await peerWhere((s) => s['active'] == 0);
  });
  testWidgets('RTMP independent AVC AAC and AVC-only mounted output and stop', (
    tester,
  ) async {
    final player = await appleController(tester);
    for (final path in ['owned', 'video']) {
      await render(player, path);
      await advance(player);
      final before = await control('stats');
      await player.stop();
      await peerWhere(
        (s) => s['closed'] > before['closed'] && s['active'] == 0,
      );
    }
  });
  testWidgets(
    'RTMP policy assess load parity rejects before connect and survivor advances',
    (tester) async {
      final player = await appleController(tester);
      final old = await render(player);
      final before = await control('stats');
      final cases = <(YlNetworkSource, YlLoadOptions, String)>[
        (
          YlNetworkSource(endpoint().replace(scheme: 'rtmps')),
          const YlLoadOptions(),
          YlFailureCodes.networkProtocolUnsupported,
        ),
        (
          YlNetworkSource(
            endpoint(),
            request: YlHttpRequest(headers: const {'x-owned': 'sentinel'}),
          ),
          const YlLoadOptions(),
          YlFailureCodes.policyUnsupported,
        ),
        (
          YlNetworkSource(
            endpoint(),
            request: YlHttpRequest(
              credentials: const {'authorization': 'sentinel'},
            ),
          ),
          const YlLoadOptions(),
          YlFailureCodes.policyUnsupported,
        ),
        (
          YlNetworkSource(endpoint(), networkPolicy: strictNetwork),
          const YlLoadOptions(),
          YlFailureCodes.policyUnsupported,
        ),
        (
          YlNetworkSource(endpoint()),
          const YlLoadOptions(bufferStrategy: strictBuffer),
          YlFailureCodes.policyUnsupported,
        ),
        (
          YlNetworkSource(endpoint(), intent: YlStreamIntent.onDemand),
          const YlLoadOptions(),
          YlFailureCodes.policyUnsupported,
        ),
        (
          YlNetworkSource(endpoint(), format: YlMediaFormat.mp4),
          const YlLoadOptions(),
          YlFailureCodes.containerUnsupported,
        ),
        (
          YlNetworkSource(endpoint()),
          const YlLoadOptions(startPosition: Duration(seconds: 1)),
          YlFailureCodes.policyUnsupported,
        ),
      ];
      for (final (source, options, code) in cases) {
        final assessment = await player.assess(source, options: options);
        expect(assessment.rejection?.code, code);
        expect(assessment.rejection!.message, isNotEmpty);
        expect(assessment.rejection!.message, isNot(contains('sentinel')));
        await expectLater(
          player.load(source, options: options),
          failureCode(code),
        );
        expect(player.state.sessionId, old.id);
      }
      for (final position in [Duration.zero, const Duration(seconds: 1)]) {
        await expectLater(
          old.seekTo(position),
          failureCode(YlFailureCodes.policyUnsupported),
        );
      }
      expect((await control('stats'))['accepted'], before['accepted']);
      await advance(player);
      await player.stop();
    },
  );
  testWidgets(
    'RTMP missing candidate preserves survivor without claiming lease rollback',
    (tester) async {
      final player = await appleController(tester);
      final old = await render(player);
      await expectLater(
        player.load(YlNetworkSource(endpoint('missing-owned'))),
        failureCode(YlFailureCodes.networkRtmpHandshakeFailed),
      );
      expect(player.state.sessionId, old.id);
      expect(player.state.failure, isNull);
      await old.pause();
      await old.play();
      await advance(player);
      await player.stop();
    },
  );
  testWidgets(
    'RTMP silent setup cancellation and replacement fence stale work',
    (tester) async {
      final player = await appleController(tester);
      for (final replacement in [false, true]) {
        final before = await control('silent');
        final cancelled = expectLater(
          player.load(YlNetworkSource(endpoint())),
          failureCode(YlFailureCodes.loadCancelled),
        );
        await peerWhere((s) => s['accepted'] == before['accepted'] + 1);
        final clock = Stopwatch()..start();
        await control('normal');
        YlPlaybackSession? fresh;
        if (replacement) {
          fresh = await render(player);
        } else {
          await player.stop();
        }
        await cancelled;
        expect(clock.elapsed, lessThan(const Duration(seconds: 15)));
        await peerWhere((s) => s['closed'] >= before['closed'] + 1);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(player.state.sessionId, fresh?.id);
        if (fresh != null) await advance(player);
        await player.stop();
      }
    },
  );
  testWidgets('RTMP public pause suspends blocked input beyond fifteen seconds', (
    tester,
  ) async {
    final player = await appleController(tester);
    final session = await render(player);
    await advance(player);
    final before = await control('hold');
    // Observe exhausted public buffering while playback still requests input.
    await stateWhere(
      player,
      (s) =>
          s.status == YlPlaybackStatus.buffering ||
          (s.timeline.bufferedPosition - s.timeline.position).inMilliseconds <=
              50,
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    debugPrint(
      'RTMP pre-pause status=${player.state.status} position=${player.state.timeline.position.inMilliseconds} buffered=${player.state.timeline.bufferedPosition.inMilliseconds}',
    );
    await session.pause();
    final budget = player.state.metrics.reconnectCount;
    await Future<void>.delayed(const Duration(seconds: 20));
    final held = await control('stats');
    expect(held['heldBytes'], greaterThan(0));
    expect(held['accepted'], before['accepted']);
    expect(held['closed'], before['closed']);
    expect(player.state.metrics.reconnectCount, budget);
    expect(player.state.failure, isNull);
    await control('release');
    await session.play();
    await advance(player);
    expect(player.state.sessionId, session.id);
    expect((await control('stats'))['accepted'], before['accepted']);
    debugPrint(
      'RTMP pause20s same connection heldBytes=${held['heldBytes']} reconnect=$budget',
    );
    await player.stop();
  });
  testWidgets(
    'RTMP three lifetime recoveries fresh output fourth drop terminal and stop fences backoff',
    (tester) async {
      final player = await appleController(tester);
      final session = await render(player);
      final observer = AndroidFrameObservation();
      if (Platform.isAndroid) {
        await observer.installActive(session.id.value);
        addTearDown(observer.remove);
      }
      final retries = <YlRetryScheduledEvent>[];
      final retrySub = player.events
          .where((e) => e is YlRetryScheduledEvent)
          .cast<YlRetryScheduledEvent>()
          .listen(retries.add);
      addTearDown(retrySub.cancel);
      final initial = await control('stats');
      bool publicFrame(Map<Object?, Object?> r) =>
          r['kind'] == 'frame' &&
          r['sessionId'] == session.id.value &&
          r['public'] == true &&
          r['matchesCurrentSurface'] == true;
      for (var attempt = 1; attempt <= 3; attempt++) {
        final framesBefore = Platform.isAndroid
            ? (await observer.read()).where(publicFrame).length
            : 0;
        await control('drop');
        await peerWhere((s) => s['accepted'] == initial['accepted'] + attempt);
        await stateWhere(
          player,
          (s) =>
              s.metrics.reconnectCount == attempt &&
              s.status == YlPlaybackStatus.playing,
        );
        if (Platform.isAndroid) {
          final deadline = DateTime.now().add(const Duration(seconds: 12));
          var frames = 0;
          do {
            final records = await observer.read();
            expect(
              records.where(
                (r) =>
                    r['kind'] == 'observationError' || r['kind'] == 'overflow',
              ),
              isEmpty,
            );
            frames = records.where(publicFrame).length;
            if (frames > framesBefore) break;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          } while (DateTime.now().isBefore(deadline));
          expect(frames, greaterThan(framesBefore));
          debugPrint(
            'RTMP Android recovered public frames $framesBefore->$frames',
          );
        }
        expect(player.state.sessionId, session.id);
        expect(player.state.audioTracks, isNotEmpty);
        await advance(player);
        debugPrint(
          'RTMP actual output recovered attempt=$attempt sameSession=${session.id}',
        );
      }
      await control('drop');
      await stateWhere(player, (s) => s.status == YlPlaybackStatus.failed);
      expect(
        player.state.failure?.code,
        Platform.isAndroid
            ? YlFailureCodes.networkRtmpDisconnected
            : 'network.retry_exhausted',
      );
      final terminal = player.state.failure!;
      expect(terminal.message, isNotEmpty);
      expect(terminal.message, isNot(contains('rtmp://')));
      expect(terminal.message, isNot(contains(host)));
      expect(terminal.message, isNot(contains('live/owned')));
      debugPrint(
        'RTMP terminal code=${terminal.code} message=${terminal.message} diagnosticPresent=${terminal.diagnosticId.isNotEmpty}',
      );
      expect(retries.map((e) => e.retryIndex), [1, 2, 3]);
      expect(retries.map((e) => e.delay.inMilliseconds), [500, 1000, 2000]);
      expect(retries.every((e) => e.sessionId == session.id), isTrue);
      debugPrint(
        'RTMP retries: ${retries.map((e) => '${e.retryIndex}:${e.delay.inMilliseconds}ms').join(',')}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect((await control('stats'))['accepted'], initial['accepted'] + 3);
      if (Platform.isAndroid) await observer.remove();
      await player.stop();
      await render(player);
      final scheduled = player.events
          .where((e) => e is YlRetryScheduledEvent)
          .cast<YlRetryScheduledEvent>()
          .first
          .timeout(const Duration(seconds: 10));
      final beforeStop = await control('drop');
      final pendingRetry = await scheduled;
      expect(pendingRetry.retryIndex, 1);
      expect(pendingRetry.delay, const Duration(milliseconds: 500));
      await player.stop();
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect((await control('stats'))['accepted'], beforeStop['accepted']);
      expect(player.state.sessionId, isNull);
    },
  );
}
