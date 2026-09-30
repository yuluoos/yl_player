import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/resource_series.dart';
import 'support/display_cleanup.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'owned AVC process resource instrumentation smoke',
    (tester) async {
      const runId = String.fromEnvironment('YL_RESOURCE_RUN_ID');
      const encodedLibrary = String.fromEnvironment(
        'YL_RESOURCE_LIBRARY_BYTES',
      );
      if (!Platform.isMacOS ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(runId) ||
          encodedLibrary.isEmpty ||
          encodedLibrary.length > 131072) {
        throw const FormatException('Resource probe configuration is required');
      }
      const profileCycles = bool.fromEnvironment('YL_RESOURCE_PROFILE_CYCLES');
      const harnessOnly = bool.fromEnvironment('YL_RESOURCE_HARNESS_ONLY');
      const workload = harnessOnly ? 'harness-only' : 'playback';
      if ((profileCycles && !kProfileMode) || (harnessOnly && !profileCycles)) {
        throw const FormatException('Resource cycles require profile mode');
      }
      const attempts = profileCycles ? 10 : 3;
      final mode = kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug';
      Map<String, Object?> Function()? readResources;
      Directory? samplerDirectory;
      addTearDown(
        () async => samplerDirectory
            ?.delete(recursive: true)
            .timeout(const Duration(seconds: 5)),
      );
      var aborted = false;
      final outcomes = <String>[];
      for (var attempt = 1; attempt <= attempts; attempt++) {
        final cleanup = DisplayTrialCleanup();
        var cleanupAttempted = false;
        ResourceSeries? series;
        Timer? timer;
        Directory? directory;
        YlPlayerController? player;
        var outcome = aborted ? 'skipped' : 'failed';
        var sampleFailed = false;
        var cleaned = false;
        var engine = 'unknown';
        var decoder = 'unknown';
        void emitObservation() => debugPrint(
          'YL_RESOURCE_OBSERVATION=${jsonEncode({'workload': workload, 'runId': runId, 'attempt': attempt, 'outcome': outcome, 'samples': series?.observations ?? []})}',
          wrapWidth: 100000,
        );
        Future<bool> releaseTrial() {
          cleanupAttempted = true;
          return cleanup.run([
            () async {
              await player?.dispose();
              player = null;
            },
            () => tester.pumpWidget(const SizedBox.shrink()),
            () async {
              await directory?.delete(recursive: true);
            },
          ]);
        }

        if (!aborted) {
          try {
            if (readResources == null) {
              final bytes = base64Decode(encodedLibrary);
              if (bytes.isEmpty || bytes.length > 98304) {
                throw const FormatException('Invalid sampler payload');
              }
              samplerDirectory = await Directory.systemTemp.createTemp(
                'yl_sampler_',
              );
              final sampler = File('${samplerDirectory.path}/resources.dylib');
              await sampler.writeAsBytes(bytes, flush: true);
              readResources = openResourceSampler(sampler.path);
            }
            series = ResourceSeries(read: readResources);
            directory = await Directory.systemTemp.createTemp('yl_resource_');
            final asset = await rootBundle.load(
              'assets/test_media/format_matrix/mkv-avc-aac.mkv',
            );
            final file = File('${directory.path}/owned.mkv');
            await file.writeAsBytes(
              asset.buffer.asUint8List(
                asset.offsetInBytes,
                asset.lengthInBytes,
              ),
            );
            await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
            series.enter('idle');
            timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
              try {
                series!.sample();
              } catch (_) {
                sampleFailed = true;
                timer?.cancel();
              }
            });
            await Future<void>.delayed(const Duration(seconds: 2));
            series.enter('opening');
            if (harnessOnly) {
              // Keep fixture I/O, UI mount, sampling and cleanup, without
              // creating a player. "playing" is only the phase clock here.
              await tester.pumpWidget(
                const MaterialApp(home: SizedBox.shrink()),
              );
              series.enter('playing');
              await Future<void>.delayed(const Duration(seconds: 2));
            } else {
              final activePlayer = await cleanup.create<YlPlayerController>(
                YlPlayerController.create(
                  options: const YlPlayerOptions(
                    audioPolicy: YlAudioPolicy.appManaged,
                  ),
                ),
                timeout: const Duration(seconds: 10),
                release: (latePlayer) => latePlayer.dispose(),
              );
              player = activePlayer;
              await tester.pumpWidget(
                MaterialApp(home: YlPlayerView(controller: activePlayer)),
              );
              final session = await activePlayer
                  .load(YlFileSource(file.path, format: YlMediaFormat.matroska))
                  .timeout(const Duration(seconds: 20));
              await session.play().timeout(const Duration(seconds: 10));
              await session.firstFrame.timeout(const Duration(seconds: 10));
              engine = activePlayer.state.engine.name;
              decoder = activePlayer.state.decoderMode.name;
              expect(activePlayer.state.videoGeometry, isNotNull);
              expect(
                activePlayer.state.audioTracks.any((t) => t.isSelected),
                isTrue,
              );
              series.enter('playing');
              await stateWhere(
                activePlayer,
                (s) => s.timeline.position >= const Duration(seconds: 2),
              );
              expect(activePlayer.state.failure, isNull);
            }
            series.enter('disposing');
            emitObservation();
            cleaned = await releaseTrial();
            if (!cleaned) throw StateError('Resource cleanup unconfirmed');
            series.enter('disposed');
            await Future<void>.delayed(const Duration(seconds: 2));
            series.sample();
            outcome = sampleFailed ? 'failed' : 'passed';
          } on TimeoutException {
            outcome = 'timeout';
          } catch (_) {
            outcome = 'failed';
          } finally {
            timer?.cancel();
            emitObservation();
            if (!cleanupAttempted) cleaned = await releaseTrial();
            if (!cleaned && outcome != 'timeout') outcome = 'failed';
            if (!cleaned || sampleFailed || outcome != 'passed') aborted = true;
          }
        }
        final rows = series?.close() ?? <Map<String, Object?>>[];
        debugPrint(
          'YL_RESOURCE_SERIES=${jsonEncode({'schemaVersion': 2, 'workload': workload, 'runId': runId, 'attempt': attempt, 'plannedAttempts': attempts, 'pid': pid, 'buildMode': mode, 'intervalMs': 250, 'engine': engine, 'decoder': decoder, 'outcome': outcome, 'samples': rows})}',
          wrapWidth: 100000,
        );
        outcomes.add(outcome);
      }
      expect(
        outcomes,
        everyElement('passed'),
        reason: 'Resource trials retained all outcomes',
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
