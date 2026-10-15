import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/apple_strict_support.dart' show stateWhere;
import 'support/capture_composition.dart';

const _assets = 'assets/test_media/format_matrix';
const _caseIds = [
  'mp4-avc-aac',
  'mov-hevc-aac',
  'mkv-avc-aac',
  'webm-vp9-opus',
  'flv-avc-mp3',
  'ts-avc-ac3',
  'ps-mpeg2-mp3',
  'ps-avc-mp3',
  'avi-avc-mp3',
  'mkv-av1-opus',
  'mkv-avc-eac3',
  'mkv-avc-dts',
  'mkv-avc-flac',
  'mkv-avc-opus',
  'mkv-avc-opus-silk',
  'mkv-avc-opus-hybrid',
  'mkv-avc-vorbis',
  'webm-vp9-vorbis',
  'mkv-hevc-main10-aac',
  'mkv-avc-ac3-51',
  'mkv-avc-aac-no-cues',
  'mp4-truncated',
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  var aborted = false;
  final runId =
      'format-${Platform.operatingSystem}-${DateTime.now().microsecondsSinceEpoch}';
  const verifyPixels = bool.fromEnvironment(
    'YL_FORMAT_VERIFY_PIXELS',
    defaultValue: true,
  );
  // Optional host-observation control for slow simulator screenshots. Keep the
  // ordinary 1x run and its failures; record this rate on every separate row.
  const playbackRate = bool.fromEnvironment('YL_FORMAT_SLOW_CAPTURE')
      ? 0.25
      : 1.0;
  double? captureScale;
  for (final id in _caseIds) {
    for (final transport in [
      'file',
      'http',
      'renamed-file',
      if (['ps-avc-mp3', 'webm-vp9-vorbis', 'mp4-avc-aac'].contains(id))
        'wrong-known-file',
      if (id == 'mp4-avc-aac' || id == 'mp4-truncated') ...[
        'extensionless-file',
        'renamed-http',
      ],
    ]) {
      testWidgets('$id / $transport', (tester) async {
        expect(aborted, isFalse, reason: 'Previous cleanup did not finish');
        final catalog =
            jsonDecode(await rootBundle.loadString('$_assets/cases.json'))
                as Map<String, dynamic>;
        expect(
          (catalog['cases'] as List).map((r) => r['id']).toSet(),
          _caseIds.toSet(),
        );
        final row = (catalog['cases'] as List)
            .cast<Map<String, dynamic>>()
            .singleWhere((r) => r['id'] == id);
        final data = await rootBundle.load('$_assets/${row['file']}');
        final bytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        final directory = await Directory.systemTemp.createTemp('yl_format_');
        final name = transport == 'wrong-known-file'
            ? (id == 'mp4-avc-aac'
                  ? 'wrong-extension.mkv'
                  : 'wrong-extension.mp4')
            : transport.startsWith('renamed-')
            ? 'wrong-extension.bin'
            : transport == 'extensionless-file'
            ? 'no-extension'
            : row['file'] as String;
        final file = File('${directory.path}/$name');
        await file.writeAsBytes(bytes, flush: true);
        HttpServer? server;
        if (transport == 'http' || transport == 'renamed-http') {
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server.listen((request) async {
            final response = request.response;
            response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
            response.headers.contentType = ContentType.binary;
            final range = request.headers.value(HttpHeaders.rangeHeader);
            var start = 0;
            var end = bytes.length - 1;
            if (range != null) {
              final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
              if (match == null) {
                response.statusCode = 416;
                await response.close();
                return;
              }
              start = int.parse(match[1]!);
              if (match[2]!.isNotEmpty) {
                end = int.parse(match[2]!).clamp(0, end);
              }
              if (start > end) {
                response.statusCode = 416;
                await response.close();
                return;
              }
              response.statusCode = 206;
              response.headers.set(
                HttpHeaders.contentRangeHeader,
                'bytes $start-$end/${bytes.length}',
              );
            }
            response.contentLength = end - start + 1;
            if (request.method != 'HEAD') {
              response.add(bytes.sublist(start, end + 1));
            }
            await response.close();
          });
        }
        YlPlayerController? player;
        var stage = 'create';
        var outcome = 'failed';
        String? code;
        String? category;
        String? scope;
        var firstFrame = false;
        var seek = false;
        var completed = false;
        var audioSelected = false;
        var cleaned = false;
        var engine = 'unknown';
        var decoder = 'unknown';
        var pixelsVerified = false;
        var retainCaptures = false;
        final pixelEvidence = <Map<String, Object>>[];
        final captureKey = GlobalKey();
        Future<void> marker(int second, String phase) async {
          final boundary =
              captureKey.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final expected = [
            [255, 0, 0],
            [0, 255, 0],
            [0, 0, 255],
            [255, 255, 255],
          ][second];
          final deadline = Stopwatch()..start();
          while (true) {
            await tester.pump(const Duration(milliseconds: 30));
            final (image, scale, top) = await captureComposition(boundary);
            try {
              if (captureScale != null && captureScale != scale) {
                retainCaptures = true;
                fail('Capture scale changed within a run');
              }
              captureScale = scale;
              final data = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              final x = image.width ~/ 2;
              final y = (top + boundary.size.height * scale / 2).round();
              final offset = (y * image.width + x) * 4;
              final rgb = [
                for (var c = 0; c < 3; c++) data.getUint8(offset + c),
              ];
              // Screen captures pass through the host display ICC profile.
              // Identify the four primary-colour markers there; exact decoded
              // RGB/planes are checked separately in the native output tests.
              // Black, grey and every other fixture marker must still fail.
              final screenCapture = Platform.isMacOS || Platform.isIOS;
              final matched = screenCapture
                  ? second == 3
                        ? rgb.every((value) => value >= 220) &&
                              (rgb.reduce((a, b) => a > b ? a : b) -
                                      rgb.reduce((a, b) => a < b ? a : b)) <=
                                  35
                        : rgb[second] >= 180 &&
                              [
                                for (var c = 0; c < 3; c++)
                                  if (c != second) c,
                              ].every((c) => rgb[second] - rgb[c] >= 100)
                  : List.generate(
                      3,
                      (c) => (rgb[c] - expected[c]).abs() <= 40,
                    ).every((v) => v);
              final png = (await image.toByteData(
                format: ui.ImageByteFormat.png,
              ))!;
              await File('${directory.path}/$phase-$second.png').writeAsBytes(
                png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
              );
              if (matched) {
                pixelEvidence.add({
                  'phase': phase,
                  'marker': second,
                  'rgb': rgb,
                  'positionUs': player!.state.timeline.position.inMicroseconds,
                  'comparison': screenCapture
                      ? 'display-primary-marker-identity'
                      : 'decoded-rgb-tolerance-40',
                });
                return;
              }
              if (deadline.elapsed > const Duration(seconds: 3)) {
                retainCaptures = true;
                fail('Displayed marker mismatch: $phase/$second, rgb=$rgb');
              }
            } finally {
              image.dispose();
            }
          }
        }

        try {
          player = await YlPlayerController.create(
            options: const YlPlayerOptions(
              audioPolicy: YlAudioPolicy.appManaged,
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: RepaintBoundary(
                key: captureKey,
                child: YlPlayerView(controller: player),
              ),
            ),
          );
          stage = 'load';
          final source = server == null
              ? YlFileSource(file.path)
              : YlNetworkSource(
                  Uri.parse('http://127.0.0.1:${server.port}/$name'),
                  intent: YlStreamIntent.onDemand,
                );
          final session = await player
              .load(source)
              .timeout(const Duration(seconds: 12));
          stage = 'ready';
          await session.ready.timeout(const Duration(seconds: 10));
          if (playbackRate != 1.0) {
            await session.setPlaybackSpeed(playbackRate);
          }
          stage = 'first-frame';
          await session.play();
          await session.firstFrame.timeout(const Duration(seconds: 10));
          firstFrame = true;
          await tester.pump(const Duration(milliseconds: 30));
          if (id == 'ts-avc-ac3') {
            expect(
              player.state.timeline.position.inMilliseconds,
              lessThan(1000),
            );
            expect(
              player.state.timeline.duration!.inMilliseconds,
              closeTo(4000, 100),
            );
          }
          stage = 'progress';
          if (!verifyPixels) {
            await stateWhere(
              player,
              (s) => s.timeline.position > const Duration(milliseconds: 400),
            );
          }
          expect(player.state.videoGeometry, isNotNull);
          audioSelected = player.state.audioTracks.any((t) => t.isSelected);
          expect(audioSelected, isTrue);
          if (id.startsWith('webm-vp9')) {
            if (!Platform.isAndroid) {
              expect(player.state.engine.name, 'managedFallback');
            }
            expect(player.state.decoderMode.name, 'hardware');
          }
          if (id == 'flv-avc-mp3' ||
              id == 'ts-avc-ac3' ||
              id == 'avi-avc-mp3') {
            expect(player.state.timeline.isLive, isFalse);
            expect(player.state.timeline.isSeekable, isTrue);
            expect(player.state.timeline.duration, isNotNull);
          }
          if (verifyPixels) {
            stage = 'pixel-markers';
            for (var second = 0; second < 4; second++) {
              if (second > 0) {
                await stateWhere(
                  player,
                  (s) => s.timeline.position.inMilliseconds >= second * 1000,
                );
              }
              // Observe the actual target frame while rendering can progress.
              // Pausing on a timeline event can freeze an older queued surface.
              await marker(second, 'play');
            }
          }
          stage = 'seek';
          const targets = [2000, 1250, 0];
          for (final targetMs in targets) {
            await session.pause();
            await session.seekTo(Duration(milliseconds: targetMs));
            await stateWhere(
              player,
              (s) =>
                  (s.timeline.position.inMilliseconds - targetMs).abs() <= 300,
            );
            await session.play();
            if (!verifyPixels) {
              await stateWhere(
                player,
                (s) =>
                    s.timeline.position >
                    Duration(milliseconds: targetMs + 350),
              );
            }
            expect(player.state.failure, isNull);
            if (verifyPixels) {
              stage = 'seek-pixels';
              await marker(targetMs ~/ 1000, 'seek-$targetMs');
            }
            if (id.startsWith('webm-vp9')) {
              expect(player.state.decoderMode.name, 'hardware');
            }
          }
          seek = true;
          pixelsVerified = verifyPixels;
          stage = 'end';
          // Keep the same media-time allowance for the optional slow capture
          // control. Its four-second clip takes sixteen wall-clock seconds.
          if (player.state.status != YlPlaybackStatus.completed) {
            await player.states
                .firstWhere((s) => s.status == YlPlaybackStatus.completed)
                .timeout(Duration(milliseconds: (15000 / playbackRate).ceil()));
          }
          completed = true;
          expect(player.state.failure, isNull);
          outcome = 'passed';
        } on YlPlayerException catch (error) {
          code = error.failure.code;
          category = error.failure.category.name;
          scope = error.failure.scope.name;
        } on TimeoutException {
          outcome = 'timeout';
          final failure = player?.state.failure;
          code = failure?.code;
          category = failure?.category.name;
          scope = failure?.scope.name;
        } on TestFailure catch (error) {
          code = 'test.assertion';
          debugPrintSynchronously(
            'YL_FORMAT_ASSERTION=$id/$transport/$stage: ${error.message}',
          );
        } catch (_) {
          // Fixed stage only: never dump native exceptions or source identities.
          code = 'test.assertion';
        } finally {
          engine = player?.state.engine.name ?? 'unknown';
          decoder = player?.state.decoderMode.name ?? 'unknown';
          try {
            await (player?.dispose() ?? Future<void>.value()).timeout(
              const Duration(seconds: 5),
            );
            await tester.pumpWidget(const SizedBox.shrink());
            await server?.close(force: true);
            if (!retainCaptures) {
              await directory.delete(recursive: true);
            } else {
              debugPrintSynchronously(
                'YL_FORMAT_CAPTURE_DIRECTORY=${directory.path}',
              );
              await for (final item in directory.list()) {
                if (item is File && item.path.endsWith('.png')) {
                  debugPrintSynchronously(
                    'YL_FORMAT_CAPTURE=${jsonEncode({'caseId': id, 'transport': transport, 'file': item.uri.pathSegments.last, 'pngBase64': base64Encode(await item.readAsBytes())})}',
                    wrapWidth: 100000,
                  );
                }
              }
            }
            cleaned = true;
          } catch (_) {
            aborted = true;
            outcome = 'cleanup-failed';
          }
          debugPrintSynchronously(
            'YL_FORMAT_ROW=${jsonEncode({'runId': runId, 'buildSha256': const String.fromEnvironment('YL_FORMAT_BUILD_SHA256', defaultValue: 'unrecorded'), 'caseId': id, 'transport': transport, 'platform': Platform.operatingSystem, 'playbackRate': playbackRate, 'mediaHash': row['sha256'], 'supportRequirement': row['supportRequirement'], 'outcome': outcome, 'stage': stage, 'code': code, 'category': category, 'scope': scope, 'engine': engine, 'decoder': decoder, 'firstFrame': firstFrame, 'audioTrackSelected': audioSelected, 'audioOutputVerified': false, 'pixelMarkersVerified': pixelsVerified, 'pcmMarkersVerified': false, 'pixelVerificationMethod': verifyPixels ? 'player-composition' : 'not-run', 'pcmVerificationMethod': 'not-run', 'pixelEvidence': pixelEvidence, 'audioClockUs': null, 'seekProgress': seek, 'completed': completed, 'disposed': cleaned})}',
            wrapWidth: 100000,
          );
        }
        const requireSupport = bool.fromEnvironment(
          'YL_FORMAT_REQUIRE_SUPPORT',
        );
        if (requireSupport && row['supportRequirement'] == 'diagnostic') {
          // Preserve the actual result above. This codec is outside REQ-10 and
          // cannot satisfy or lower the required-format acceptance denominator.
          expect(outcome, anyOf('passed', 'failed', 'timeout'));
        } else if (Platform.isMacOS &&
            !requireSupport &&
            id != 'ps-avc-mp3' &&
            transport != 'wrong-known-file') {
          // Pin known baseline failures, while keeping failed/timeout in JSONL.
          // This is a regression characterization, never a support claim.
          final baseline =
              jsonDecode(
                    await rootBundle.loadString('$_assets/baseline-macos.json'),
                  )
                  as Map<String, dynamic>;
          final expected =
              baseline['expectations']['$id/$transport']
                  as Map<String, dynamic>;
          expect(outcome, expected['outcome']);
          expect(stage, expected['stage']);
          expect(code, expected['code']);
          expect(category, expected['category']);
          expect(scope, expected['scope']);
          expect(firstFrame, expected['firstFrame']);
          expect(seek, expected['seekProgress']);
          expect(completed, expected['completed']);
        } else if (row['integrity'] == 'truncated') {
          expect(outcome, 'failed');
          expect(category, anyOf('source', 'container'));
          expect(
            scope,
            Platform.isAndroid && stage == 'load' ? 'command' : 'session',
          );
          expect(firstFrame, isFalse);
        } else {
          expect(
            outcome,
            'passed',
            reason: '$id/$transport failed at $stage ($code)',
          );
        }
        expect(cleaned, isTrue);
      }, timeout: const Timeout(Duration(seconds: 90)));
    }
  }
}
