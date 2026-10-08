import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/continuous_start.dart';
import 'support/display_cleanup.dart';
import 'support/resource_series.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'one session continuous synthetic AVC for twenty minutes',
    (tester) async {
      const runId = String.fromEnvironment('YL_RESOURCE_RUN_ID');
      const encoded = String.fromEnvironment('YL_RESOURCE_LIBRARY_BYTES');
      if (!Platform.isMacOS ||
          !kProfileMode ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(runId) ||
          encoded.isEmpty ||
          encoded.length > 131072) {
        throw const FormatException(
          'Continuous profile configuration required',
        );
      }
      final cleanup = DisplayTrialCleanup();
      Directory? directory;
      YlPlayerController? player;
      StreamSubscription<YlPlayerState>? subscription;
      var sequence = 0;
      var outcome = 'failed';
      String? errorType;
      var cleaned = false;
      var invalidState = false;
      var stage = 'setup';
      Timer? startupTimer;
      final disposedSamples = <Map<String, Object?>>[];
      Map<String, Object?> Function()? read;
      void emit(Map<String, Object?> value) => debugPrintSynchronously(
        'YL_CONTINUOUS=${jsonEncode({'schemaVersion': 1, 'runId': runId, 'pid': pid, 'sequence': sequence++, ...value})}',
        wrapWidth: 100000,
      );
      try {
        final bytes = base64Decode(encoded);
        if (bytes.isEmpty || bytes.length > 98304) {
          throw const FormatException('Invalid sampler payload');
        }
        directory = await Directory.systemTemp.createTemp('yl_continuous_');
        final library = File('${directory.path}/resources.dylib');
        await library.writeAsBytes(bytes, flush: true);
        read = openResourceSampler(library.path);
        final asset = await rootBundle.load(
          'assets/test_media/format_matrix/continuous-avc-aac.mkv',
        );
        final media = File('${directory.path}/owned.mkv');
        await media.writeAsBytes(
          asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
          flush: true,
        );
        final active = await cleanup.create(
          YlPlayerController.create(
            options: const YlPlayerOptions(
              audioPolicy: YlAudioPolicy.appManaged,
            ),
          ),
          timeout: const Duration(seconds: 10),
          release: (late) => late.dispose(),
        );
        player = active;
        await tester.pumpWidget(
          MaterialApp(home: YlPlayerView(controller: active)),
        );
        stage = 'load';
        startupTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          final s = active.state;
          debugPrintSynchronously(
            'YL_CONTINUOUS_STARTUP=${jsonEncode({'stage': stage, 'status': s.status.name, 'positionUs': s.timeline.position.inMicroseconds, 'failureCode': s.failure?.code, 'engine': s.engine.name, 'decoder': s.decoderMode.name})}',
          );
        });
        final session = await active
            .load(YlFileSource(media.path, format: YlMediaFormat.matroska))
            .timeout(const Duration(seconds: 20));
        stage = 'play';
        await session.play().timeout(const Duration(seconds: 10));
        stage = 'firstFrame';
        await session.firstFrame.timeout(const Duration(seconds: 10));
        stage = 'warmup';
        await waitForContinuousStart(
          current: () => active.state,
          states: active.states,
          sessionId: session.id,
        );
        startupTimer.cancel();
        final series = ResourceSeries(read: read);
        final clock = Stopwatch()..start();
        subscription = active.states.listen((s) {
          if (s.failure != null ||
              s.sessionId != session.id ||
              s.status != YlPlaybackStatus.playing) {
            invalidState = true;
          }
        });
        var first = true;
        while (true) {
          if (first) {
            series.enter('playing');
            first = false;
          } else {
            series.sample();
          }
          final state = active.state;
          emit({
            'kind': 'tick',
            'sessionId': state.sessionId?.value ?? '',
            'positionUs': state.timeline.position.inMicroseconds,
            'status': state.status.name,
            'failure': invalidState || state.failure != null,
            'engine': state.engine.name,
            'decoder': state.decoderMode.name,
            'audioSelected': state.audioTracks.any((t) => t.isSelected),
            'videoPresent': state.videoGeometry != null,
            'resource': series.observations.last,
          });
          if (invalidState || state.failure != null) {
            throw StateError(
              'Playback state changed during continuous observation',
            );
          }
          if (clock.elapsed >= const Duration(minutes: 20)) break;
          await Future<void>.delayed(const Duration(seconds: 5));
        }
        outcome = 'passed';
      } on YlPlayerException catch (error) {
        errorType = 'YlPlayerException';
        debugPrintSynchronously(
          'YL_CONTINUOUS_FAILURE=${jsonEncode({'stage': stage, 'failureCode': error.failure.code})}',
        );
      } on TimeoutException {
        outcome = 'timeout';
        errorType = 'TimeoutException';
      } catch (error) {
        errorType = error.runtimeType.toString();
      } finally {
        startupTimer?.cancel();
        await subscription?.cancel();
        cleaned = await cleanup.run([
          () async {
            await player?.dispose();
            player = null;
          },
          () => tester.pumpWidget(const SizedBox.shrink()),
        ]);
        if (read != null) {
          try {
            final series = ResourceSeries(read: read)..enter('disposed');
            await Future<void>.delayed(const Duration(seconds: 2));
            series.sample();
            disposedSamples.addAll(series.close());
          } catch (_) {
            cleaned = false;
          }
        }
        cleaned =
            await cleanup.run([
              () async {
                await directory?.delete(recursive: true);
              },
            ]) &&
            cleaned;
        if (!cleaned) {
          outcome = 'failed';
          errorType ??= 'CleanupUnconfirmed';
        }
        emit({
          'kind': 'result',
          'outcome': outcome,
          'cleaned': cleaned,
          'errorType': errorType,
          'disposedSamples': disposedSamples,
        });
      }
      expect(outcome, 'passed', reason: 'All continuous observations retained');
    },
    timeout: const Timeout(Duration(minutes: 22)),
  );
}
