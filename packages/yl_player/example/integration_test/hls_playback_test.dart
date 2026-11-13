import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/playback_sessions.dart';

import 'support/authenticated_hls_server.dart';

void main() {
  // Keep the native view rendering while awaiting playback events.
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('opens HLS and produces a native texture first frame', (
    WidgetTester tester,
  ) async {
    final clock = Stopwatch()..start();
    final server = await AuthenticatedHlsServer.start();
    addTearDown(server.close);
    final hlsSource = YlNetworkSource(
      server.masterUri,
      format: YlMediaFormat.hls,
    );
    final controller = await YlPlayerController.create();
    addTearDown(controller.dispose);
    final timeline = <Map<String, Object?>>[];
    void record(String phase, [YlPlayerState? observed]) {
      final state = observed ?? controller.state;
      timeline.add({
        'phase': phase,
        'elapsedUs': clock.elapsedMicroseconds,
        'status': state.status.name,
        'revision': state.revision,
        'positionUs': state.timeline.position.inMicroseconds,
        'durationUs': state.timeline.duration?.inMicroseconds,
        'engine': state.engine.name,
        'textureId': controller.textureId.value,
        'lifecycle': tester.binding.lifecycleState?.name,
      });
    }

    // Preserve timing on assertion failures without adding waits or per-frame IO.
    addTearDown(() {
      record('tearDown');
      final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
      binding.reportData = {
        ...?binding.reportData,
        'hlsFirstFrameTimeline': timeline,
      };
      debugPrint('HLS_FIRST_FRAME_TIMELINE ${jsonEncode(timeline)}');
    });
    YlPlaybackStatus? lastStatus;
    final states = controller.states.listen((state) {
      if (state.status != lastStatus) {
        lastStatus = state.status;
        record('state', state);
      }
    });
    addTearDown(states.cancel);
    record('pumpWidget.begin');
    await tester.pumpWidget(
      MaterialApp(
        home: AspectRatio(
          aspectRatio: 16 / 9,
          child: YlPlayerView(controller: controller),
        ),
      ),
    );
    record('pumpWidget.end');
    final firstFrame = controller.events
        .firstWhere((event) {
          if (event is! YlFirstFrameEvent) return false;
          record('firstFrame.event');
          return true;
        })
        .timeout(const Duration(seconds: 45));

    record('load.begin');
    await loadSession(
      controller,
      hlsSource,
      options: const YlLoadOptions(
        bufferStrategy: YlBufferStrategy.lowLatency(),
      ),
    );
    record('load.end');
    unawaited(
      sessionFor(controller).ready.then(
        (_) => record('ready.completed'),
        onError: (Object error, StackTrace stack) => record('ready.failed'),
      ),
    );
    record('play.begin');
    await sessionFor(controller).play();
    record('play.end');
    record('ready.wait.begin');
    await sessionFor(controller).ready.timeout(const Duration(seconds: 20));
    record('ready.wait.end');
    record('firstFrame.wait.begin');
    await firstFrame;
    record('firstFrame.wait.end');
    record('pump.begin');
    await tester.pump();
    record('pump.end');

    record('assertions.begin');
    expect(controller.textureId.value, isNotNull);
    expect(
      controller.state.status,
      anyOf(YlPlaybackStatus.playing, YlPlaybackStatus.buffering),
    );
    expect(controller.state.engine, isNot(YlPlaybackEngine.unknown));
    record('assertions.end');
  });

  testWidgets('rejecting a fallback source does not tear down current HLS', (
    WidgetTester tester,
  ) async {
    final server = await AuthenticatedHlsServer.start();
    addTearDown(server.close);
    final hlsSource = YlNetworkSource(
      server.masterUri,
      format: YlMediaFormat.hls,
    );
    final controller = await YlPlayerController.create();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: YlPlayerView(controller: controller)),
    );
    final firstFrame = controller.events
        .firstWhere((event) => event is YlFirstFrameEvent)
        .timeout(const Duration(seconds: 45));

    await loadSession(controller, hlsSource);
    await sessionFor(controller).play();
    await sessionFor(controller).ready.timeout(const Duration(seconds: 20));
    await firstFrame;

    await expectLater(
      loadSession(
        controller,
        YlNetworkSource(
          Uri.parse('https://example.invalid/live.mkv'),
          format: YlMediaFormat.matroska,
          intent: YlStreamIntent.live,
        ),
      ),
      throwsA(
        isA<YlPlayerException>().having(
          (error) => error.failure.code,
          'code',
          'container.network_mkv_live_unsupported',
        ),
      ),
    );

    expect(controller.state.engine, YlPlaybackEngine.avPlayer);
    final recoveredState = controller.states
        .firstWhere(
          (state) =>
              state.engine == YlPlaybackEngine.avPlayer &&
              state.status != YlPlaybackStatus.failed,
        )
        .timeout(const Duration(seconds: 5));
    await sessionFor(controller).play();
    await sessionFor(controller).ready.timeout(const Duration(seconds: 20));
    await recoveredState;
  });
}
