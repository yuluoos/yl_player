import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/abr_network_series.dart';
import 'support/abr_network_preflight.dart';
import 'support/first_frame_probe.dart';
import 'support/resource_series.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'capture one owned DASH network policy run',
    (tester) async {
      final config = parseAbrConfig({
        'runId': const String.fromEnvironment('YL_ABR_RUN'),
        'mode': const String.fromEnvironment('YL_ABR_MODE'),
        'url': const String.fromEnvironment('YL_ABR_URL'),
        'profileId': const String.fromEnvironment('YL_ABR_PROFILE'),
        'profileHash': const String.fromEnvironment('YL_ABR_PROFILE_SHA256'),
        'mediaHash': const String.fromEnvironment('YL_ABR_MEDIA_SHA256'),
      });
      final clock = Stopwatch();
      final probe = FirstFrameProbe(nowUs: () => clock.elapsedMicroseconds);
      YlPlayerController? player;
      AbrNetworkSeries? series;
      StreamSubscription<YlPlayerEvent>? subscription;
      var outcome = 'failed';
      var stage = 'preflight';
      int? policyAckUs;
      Map<String, int>? clockAlignment;
      var cleaned = false;
      var cleanupStage = 'subscription';
      try {
        // HEAD does not arm the server. Fail before player creation on identity
        // mismatch or a server already used by another attempt.
        await preflightAbr(config);
        stage = 'create';
        player = await createResourceOwner<YlPlayerController>(
          YlPlayerController.create(),
          timeout: const Duration(seconds: 20),
          release: (p) => p.dispose(),
        );
        await tester.pumpWidget(
          MaterialApp(home: YlPlayerView(controller: player)),
        );
        subscription = player.events.listen((event) {
          if (event is YlFirstFrameEvent) probe.observe(event.sessionId.value);
        });
        clock.start();
        probe.start();
        stage = 'load';
        final session = await player
            .load(
              YlNetworkSource(
                Uri.parse(config['url']!),
                format: YlMediaFormat.dash,
              ),
              options: YlLoadOptions(
                videoConstraints: config['mode'] == 'caps'
                    ? const YlVideoConstraints(
                        maxWidth: 320,
                        maxHeight: 180,
                        maxBitrate: 350000,
                      )
                    : const YlVideoConstraints(),
              ),
            )
            .timeout(const Duration(seconds: 20));
        probe.bind(session.id.value);
        series = AbrNetworkSeries(session.id);
        series.add(player.state, clock.elapsedMicroseconds);
        await session.ready.timeout(const Duration(seconds: 20));
        stage = 'policy';
        if (config['mode'] == 'fixed') {
          final tracks = player.state.videoTracks
              .where(
                (t) => t.width == 640 && t.height == 360 && t.bitrate == 700000,
              )
              .toList();
          if (tracks.length != 1) {
            throw StateError('Owned high track unavailable');
          }
          await session
              .selectVideoTrack(tracks.single.id)
              .timeout(const Duration(seconds: 10));
        }
        policyAckUs = clock.elapsedMicroseconds;
        stage = 'play';
        await session.play().timeout(const Duration(seconds: 10));
        await session.firstFrame.timeout(const Duration(seconds: 20));
        clockAlignment = await alignAbrClock(
          config,
          nowUs: () => clock.elapsedMicroseconds,
        );
        stage = 'observe';
        while (clock.elapsed < const Duration(seconds: 180)) {
          series.add(player.state, clock.elapsedMicroseconds);
          if (player.state.failure != null) throw StateError('Playback failed');
          if (player.state.status == YlPlaybackStatus.completed) {
            if (player.state.timeline.position <
                const Duration(milliseconds: 39500)) {
              throw StateError('Owned programme ended early');
            }
            outcome = 'completed';
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        if (outcome != 'completed') outcome = 'timeout';
      } on TimeoutException {
        outcome = 'timeout';
      } catch (_) {
        outcome = 'failed'; // Never print native/URL/track exception contents.
      } finally {
        probe.close();
        try {
          await subscription?.cancel();
          if (player != null) {
            cleanupStage = 'dispose';
            await player.dispose().timeout(const Duration(seconds: 5));
          }
          cleanupStage = 'unmount';
          await tester.pumpWidget(const SizedBox.shrink());
          // A timed-out create may still own a late native value whose cleanup
          // is handled by createResourceOwner, but not yet verified here.
          cleaned = player != null || stage == 'preflight';
        } catch (error) {
          debugPrint(
            'YL_ABR_CLEANUP_FAILURE=${jsonEncode({'stage': cleanupStage, 'kind': error is TimeoutException ? 'timeout' : error.runtimeType.toString()})}',
          );
          cleaned = false;
        }
        for (final sample in series?.samples ?? <Map<String, Object?>>[]) {
          debugPrint(
            'YL_ABR_SAMPLE=${jsonEncode({'runId': config['runId'], ...sample})}',
            wrapWidth: 100000,
          );
        }
        debugPrint(
          'YL_ABR_RESULT=${jsonEncode({
            'schemaVersion': 1,
            for (final key in ['runId', 'mode', 'profileId', 'profileHash', 'mediaHash']) key: config[key],
            'platform': Platform.operatingSystem,
            'buildMode': kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
            'outcome': outcome,
            'stage': stage,
            'cleaned': cleaned,
            'sampleCount': series?.samples.length ?? 0,
            'policyAckUs': policyAckUs,
            'firstFrameUs': clock.isRunning ? probe.fields('observation')['firstFrameUs'] : null,
            'endToEndLatencyUs': null,
            'physicalOutputVerified': false,
            'baselineComparable': false,
            'sampleIntervalMs': 250,
            'clockRelation': clockAlignment == null ? 'load-vs-first-get-unsynchronized' : 'profile-head-bracket',
            'clockAlignment': clockAlignment,
          })}',
          wrapWidth: 100000,
        );
        // Preserve every sample and the result before the test process exits.
        await debugPrintDone.timeout(const Duration(seconds: 30));
      }
      expect(
        outcome,
        'completed',
        reason: 'Capture failure preserved in YL_ABR_RESULT',
      );
      expect(cleaned, isTrue, reason: 'Capture cleanup must finish');
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
