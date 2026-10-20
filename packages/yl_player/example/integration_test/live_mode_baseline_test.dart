import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/live_mode_series.dart';
import 'support/resource_series.dart';

/// One protocol and mode per fresh relay/session. The selected mode experiences
/// the complete network trajectory; transactions have their own test entry.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'owned live independent mode baseline',
    (tester) async {
      final config = parseLiveModeConfig({
        'runId': const String.fromEnvironment('YL_LIVE_RUN'),
        'protocol': const String.fromEnvironment('YL_LIVE_PROTOCOL'),
        'url': const String.fromEnvironment('YL_LIVE_URL'),
        'owned': const String.fromEnvironment('YL_LIVE_OWNED'),
        'mediaHash': const String.fromEnvironment('YL_LIVE_MEDIA_SHA256'),
        'profileId': const String.fromEnvironment('YL_LIVE_PROFILE'),
        'profileHash': const String.fromEnvironment('YL_LIVE_PROFILE_SHA256'),
        'baselineMode': const String.fromEnvironment('YL_LIVE_BASELINE_MODE'),
      });
      final mode = YlLivePlaybackMode.values.byName(config['baselineMode']!);
      final clock = Stopwatch()..start();
      YlPlayerController? player;
      LiveModeSeries? series;
      String? sessionId;
      var outcome = 'failed', stage = 'create', cleaned = false;
      try {
        final owner = await createResourceOwner<YlPlayerController>(
          YlPlayerController.create(),
          timeout: const Duration(seconds: 20),
          release: (p) => p.dispose(),
        );
        player = owner;
        await tester.pumpWidget(
          MaterialApp(home: YlPlayerView(controller: owner)),
        );
        stage = 'load';
        final session = await owner
            .load(
              YlNetworkSource(
                Uri.parse(config['url']!),
                intent: YlStreamIntent.live,
                format: config['protocol'] == 'hls'
                    ? YlMediaFormat.hls
                    : YlMediaFormat.flv,
              ),
              options: YlLoadOptions(
                bufferStrategy: mode == YlLivePlaybackMode.lowLatency
                    ? const YlBufferStrategy.lowLatency()
                    : const YlBufferStrategy.smoothPlayback(),
              ),
            )
            .timeout(const Duration(seconds: 20));
        sessionId = session.id.value;
        await session.ready.timeout(const Duration(seconds: 20));
        expect(owner.state.livePlayback?.mode, mode);
        series = LiveModeSeries(session.id);
        await session.play().timeout(const Duration(seconds: 10));
        await session.firstFrame.timeout(const Duration(seconds: 20));
        stage = 'baseline';
        final start = clock.elapsed;
        while (clock.elapsed - start < const Duration(seconds: 36)) {
          final state = owner.state;
          expect(state.sessionId, session.id);
          expect(state.failure, isNull);
          expect(state.livePlayback?.mode, mode);
          series.add(state, clock.elapsedMicroseconds, stage: stage);
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        final observations = series.samples;
        final firstClock =
            observations.first['mediaClockUs'] ??
            observations.first['positionUs'];
        final lastClock =
            observations.last['mediaClockUs'] ??
            observations.last['positionUs'];
        expect(lastClock as int, greaterThan(firstClock as int));
        outcome = 'completed';
      } on TimeoutException {
        outcome = 'timeout';
      } catch (_) {
        outcome = 'failed';
      } finally {
        try {
          await player?.dispose().timeout(const Duration(seconds: 5));
          await tester.pumpWidget(const SizedBox.shrink());
          cleaned = player != null;
        } catch (_) {
          cleaned = false;
        }
        for (final sample in series?.samples ?? <Map<String, Object?>>[]) {
          debugPrint(
            'YL_LIVE_SAMPLE=${jsonEncode({'runId': config['runId'], ...sample})}',
            wrapWidth: 100000,
          );
        }
        debugPrint(
          'YL_LIVE_RESULT=${jsonEncode({'schemaVersion': 2, 'scenario': 'baseline', 'baselineMode': config['baselineMode'], 'sessionId': sessionId, 'sampleCount': series?.samples.length ?? 0, 'runId': config['runId'], 'protocol': config['protocol'], 'profileId': config['profileId'], 'profileHash': config['profileHash'], 'declaredMediaHash': config['mediaHash'], 'platform': Platform.operatingSystem, 'buildMode': kReleaseMode
              ? 'release'
              : kProfileMode
              ? 'profile'
              : 'debug', 'outcome': outcome, 'stage': stage, 'cleaned': cleaned, 'commits': <Object>[], 'rapidSwitchVerified': false, 'staleStopVerified': false, 'endToEndLatencyUs': null, 'evidence': 'public-state-only'})}',
          wrapWidth: 100000,
        );
        // Preserve every sample and the result before the test process exits.
        await debugPrintDone.timeout(const Duration(seconds: 30));
      }
      expect(outcome, 'completed');
      expect(cleaned, isTrue);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
