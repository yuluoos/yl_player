import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/android_frame_observation.dart';
import 'support/apple_strict_support.dart' show readyAndPlay, stateWhere;
import 'support/live_mode_series.dart';

const _sourceHash =
    'cfe009b1b03b6cacf4ae9f037eed4441a32b99508d4fabccb429bea439cf570b';
const _probe = MethodChannel('yl_player_example/debug/frame_observation');

/// Use the pinned rolling playlist served by tool/playback_network/live_fixture.py.
Uri _fixture() => Uri.parse(
  parseLiveModeConfig({
    'runId': const String.fromEnvironment('YL_LIVE_RUN'),
    'protocol': 'hls',
    'owned': 'true',
    'mediaHash': _sourceHash,
    'url': const String.fromEnvironment('P04_HLS'),
  })['url']!,
);

Future<YlPlayerController> _mount(WidgetTester tester) async {
  final player = await YlPlayerController.create();
  addTearDown(player.dispose);
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: YlPlayerView(controller: player),
    ),
  );
  return player;
}

Future<({int first, int last, int requestId})> _window(
  HttpClient client,
  Uri source,
) async {
  final response = await (await client.getUrl(
    source,
  )).close().timeout(const Duration(seconds: 5));
  expect(response.statusCode, HttpStatus.ok);
  expect(response.headers.value('x-yl-media-sha256'), _sourceHash);
  expect(
    response.headers.value('x-yl-run-id'),
    const String.fromEnvironment('YL_LIVE_RUN'),
  );
  final body = await utf8.decoder
      .bind(response)
      .join()
      .timeout(const Duration(seconds: 5));
  final first = int.parse(
    RegExp(r'#EXT-X-MEDIA-SEQUENCE:(\d+)').firstMatch(body)![1]!,
  );
  final size = '#EXTINF:'.allMatches(body).length;
  expect(size, greaterThan(0));
  return (
    first: first,
    last: first + size - 1,
    requestId: int.parse(response.headers.value('x-yl-request-id')!),
  );
}

Future<int?> _rendered() async =>
    (await _probe.invokeMapMethod<String, dynamic>(
          'playbackOutput',
        ))?['rendered']
        as int?;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('default HLS retries two 503 responses and presents a frame', (
    tester,
  ) async {
    final media = _fixture();
    final player = await _mount(tester);
    final master = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => master.close(force: true));
    final statuses = <int>[];
    final times = <int>[];
    final clock = Stopwatch()..start();
    master.listen((request) async {
      if (request.uri.path != '/master.m3u8') {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        final status = statuses.length < 2
            ? HttpStatus.serviceUnavailable
            : HttpStatus.ok;
        statuses.add(status);
        times.add(clock.elapsedMilliseconds);
        request.response.statusCode = status;
        if (status == HttpStatus.ok) {
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write(
            '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=350000\n$media\n',
          );
        }
      }
      await request.response.close();
    });
    final session = await player
        .load(
          YlNetworkSource(
            Uri.parse('http://127.0.0.1:${master.port}/master.m3u8'),
            format: YlMediaFormat.hls,
            intent: YlStreamIntent.live,
          ),
        )
        .timeout(const Duration(seconds: 25));
    await readyAndPlay(player, session);
    expect(player.isCurrentFramePresented, isTrue);
    await stateWhere(player, (s) => s.status == YlPlaybackStatus.playing);
    await player.stop();
    debugPrintSynchronously(
      'YL_HLS_503=${jsonEncode({'statuses': statuses, 'requestMs': times, 'firstFrame': true, 'session': session.id.value})}',
    );
    expect(statuses, [503, 503, 200]);
  });

  testWidgets(
    'Android HLS resumes video after the entire paused window expires',
    (tester) async {
      final uri = _fixture();
      final player = await _mount(tester);
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      addTearDown(() => client.close(force: true));
      final session = await player.load(
        YlNetworkSource(
          uri,
          format: YlMediaFormat.hls,
          intent: YlStreamIntent.live,
        ),
      );
      await readyAndPlay(player, session);
      final retries = <int>[];
      final subscription = player.events.listen((event) {
        if (event is YlRetryScheduledEvent && event.sessionId == session.id) {
          retries.add(event.retryIndex);
        }
      });
      addTearDown(subscription.cancel);
      final observer = AndroidFrameObservation();
      await observer.installActive(session.id.value);
      addTearDown(observer.remove);

      for (final mode in [
        YlLivePlaybackMode.smoothPlayback,
        YlLivePlaybackMode.lowLatency,
      ]) {
        await session.setLivePlaybackMode(mode);
        await stateWhere(
          player,
          (s) =>
              s.livePlayback?.mode == mode &&
              s.status == YlPlaybackStatus.playing,
        );
        await Future<void>.delayed(const Duration(seconds: 3));
        await session.pause();
        await stateWhere(player, (s) => s.status == YlPlaybackStatus.paused);
        final pausedWindow = await _window(client, uri);
        final pause = Stopwatch()..start();
        var current = pausedWindow;
        while (current.first <= pausedWindow.last &&
            pause.elapsed < const Duration(seconds: 40)) {
          await Future<void>.delayed(const Duration(seconds: 1));
          expect(player.state.sessionId, session.id);
          expect(player.state.status, YlPlaybackStatus.paused);
          current = await _window(client, uri);
        }
        expect(current.first, greaterThan(pausedWindow.last));
        final priorRetries = retries.length;
        final resume = Stopwatch()..start();
        await session.play().timeout(const Duration(seconds: 5));
        int? lastClock, lastFrames;
        var advance = 0, frames = 0;
        while (resume.elapsed < const Duration(seconds: 10)) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final count = await _rendered();
          final state = player.state;
          expect(state.failure, isNull);
          expect(state.sessionId, session.id);
          final clock =
              (state.metrics.mediaClockPosition ?? state.timeline.position)
                  .inMicroseconds;
          if (count == null || state.status != YlPlaybackStatus.playing) {
            lastClock = lastFrames = null;
            advance = frames = 0;
            continue;
          }
          if (lastClock != null &&
              lastFrames != null &&
              clock >= lastClock &&
              count >= lastFrames) {
            advance += clock - lastClock;
            frames += count - lastFrames;
          } else {
            advance = frames = 0;
          }
          lastClock = clock;
          lastFrames = count;
          if (advance >= 500000 && frames > 0) break;
        }
        final resumeMs = resume.elapsedMilliseconds;
        final pauseMs = pause.elapsedMilliseconds - resumeMs;
        expect(advance, greaterThanOrEqualTo(500000));
        expect(frames, greaterThan(0));
        // Observe playback beyond the old six-segment buffer. Request IDs let
        // the fixture receipt identify media fetched strictly after resuming.
        await Future<void>.delayed(const Duration(seconds: 16));
        expect(player.state.failure, isNull);
        expect(player.state.status, YlPlaybackStatus.playing);
        final followFrames = await _rendered();
        expect(followFrames, isNotNull);
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(player.state.failure, isNull);
        final endFrames = await _rendered();
        expect(endFrames, isNotNull);
        final followDelta = endFrames! - followFrames!;
        final end = await _window(client, uri);
        debugPrintSynchronously(
          'YL_HLS_RESUME=${jsonEncode({
            'mode': mode.name,
            'session': session.id.value,
            'oldWindow': [pausedWindow.first, pausedWindow.last],
            'newWindow': [current.first, current.last],
            'requestAtResume': current.requestId,
            'requestAtEnd': end.requestId,
            'followFrames': followDelta,
            'pauseMs': pauseMs,
            'resumeMs': resumeMs,
            'advanceUs': advance,
            'frames': frames,
            'retriesAfterResume': retries.skip(priorRetries).toList(),
            'status': player.state.status.name,
          })}',
        );
        expect(followDelta, greaterThan(0));
        expect(player.state.sessionId, session.id);
        expect(player.state.status, YlPlaybackStatus.playing);
        expect(player.state.failure, isNull);
        expect(player.state.livePlayback?.mode, mode);
      }
      await player.stop();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
