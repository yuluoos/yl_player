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
      const attempts = 3;
      final mode = kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug';
      Map<String, Object?> Function()? readResources;
      Directory? samplerDirectory;
      addTearDown(() async => samplerDirectory?.delete(recursive: true));
      var aborted = false;
      final outcomes = <String>[];
      for (var attempt = 1; attempt <= attempts; attempt++) {
        ResourceSeries? series;
        Timer? timer;
        Directory? directory;
        YlPlayerController? player;
        var outcome = aborted ? 'skipped' : 'failed';
        var sampleFailed = false;
        var cleaned = false;
        var engine = 'unknown';
        var decoder = 'unknown';
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
            player = await createResourceOwner<YlPlayerController>(
              YlPlayerController.create(
                options: const YlPlayerOptions(
                  audioPolicy: YlAudioPolicy.appManaged,
                ),
              ),
              timeout: const Duration(seconds: 10),
              release: (latePlayer) => latePlayer.dispose(),
            );
            await tester.pumpWidget(
              MaterialApp(home: YlPlayerView(controller: player)),
            );
            final session = await player
                .load(YlFileSource(file.path, format: YlMediaFormat.matroska))
                .timeout(const Duration(seconds: 20));
            await session.play().timeout(const Duration(seconds: 10));
            await session.firstFrame.timeout(const Duration(seconds: 10));
            engine = player.state.engine.name;
            decoder = player.state.decoderMode.name;
            expect(player.state.videoGeometry, isNotNull);
            expect(player.state.audioTracks.any((t) => t.isSelected), isTrue);
            series.enter('playing');
            await stateWhere(
              player,
              (s) => s.timeline.position >= const Duration(seconds: 2),
            );
            expect(player.state.failure, isNull);
            series.enter('disposing');
            await player.dispose().timeout(const Duration(seconds: 5));
            player = null;
            await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
            cleaned = true;
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
            if (!cleaned) {
              try {
                await player?.dispose().timeout(const Duration(seconds: 5));
                await tester.pumpWidget(const SizedBox.shrink());
                cleaned = true;
              } catch (_) {
                if (outcome != 'timeout') outcome = 'failed';
              }
            }
            try {
              await directory
                  ?.delete(recursive: true)
                  .timeout(const Duration(seconds: 5));
            } catch (_) {
              cleaned = false;
              if (outcome != 'timeout') outcome = 'failed';
            }
            if (!cleaned || sampleFailed || outcome != 'passed') aborted = true;
          }
        }
        final rows = series?.close() ?? <Map<String, Object?>>[];
        debugPrint(
          'YL_RESOURCE_SERIES=${jsonEncode({'schemaVersion': 1, 'runId': runId, 'attempt': attempt, 'plannedAttempts': attempts, 'pid': pid, 'buildMode': mode, 'intervalMs': 250, 'engine': engine, 'decoder': decoder, 'outcome': outcome, 'samples': rows})}',
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
