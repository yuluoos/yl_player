import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/apple_strict_support.dart' show stateWhere;

const _assets = 'assets/test_media/format_matrix';
const _caseIds = [
  'mp4-avc-aac',
  'mov-hevc-aac',
  'mkv-avc-aac',
  'webm-vp9-opus',
  'flv-avc-mp3',
  'ts-avc-ac3',
  'ps-mpeg2-mp3',
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
  for (final id in _caseIds) {
    for (final transport in [
      'file',
      'http',
      'renamed-file',
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
        final name = transport.startsWith('renamed-')
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
        try {
          player = await YlPlayerController.create(
            options: const YlPlayerOptions(
              audioPolicy: YlAudioPolicy.appManaged,
            ),
          );
          await tester.pumpWidget(
            MaterialApp(home: YlPlayerView(controller: player)),
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
          stage = 'first-frame';
          await session.play();
          await session.firstFrame.timeout(const Duration(seconds: 10));
          firstFrame = true;
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
          await stateWhere(
            player,
            (s) => s.timeline.position > const Duration(milliseconds: 400),
          );
          expect(player.state.videoGeometry, isNotNull);
          audioSelected = player.state.audioTracks.any((t) => t.isSelected);
          expect(audioSelected, isTrue);
          if (id.startsWith('webm-vp9')) {
            expect(player.state.engine.name, 'managedFallback');
            expect(player.state.decoderMode.name, 'hardware');
          }
          if (id == 'flv-avc-mp3' ||
              id == 'ts-avc-ac3' ||
              id == 'avi-avc-mp3') {
            expect(player.state.timeline.isLive, isFalse);
            expect(player.state.timeline.isSeekable, isTrue);
            expect(player.state.timeline.duration, isNotNull);
          }
          stage = 'seek';
          final targets = [
            2000,
            if (id == 'mov-hevc-aac' ||
                id == 'mkv-hevc-main10-aac' ||
                id == 'flv-avc-mp3' ||
                id == 'mkv-avc-flac' ||
                id == 'mkv-avc-vorbis' ||
                id.startsWith('webm-vp9') ||
                id.startsWith('mkv-avc-opus') ||
                id == 'ts-avc-ac3' ||
                id == 'avi-avc-mp3')
              1250,
            if (id.startsWith('mkv-avc-opus') ||
                id == 'mkv-avc-vorbis' ||
                id.startsWith('webm-vp9'))
              0,
          ];
          for (final targetMs in targets) {
            await session.pause();
            await session.seekTo(Duration(milliseconds: targetMs));
            await stateWhere(
              player,
              (s) =>
                  (s.timeline.position.inMilliseconds - targetMs).abs() <= 300,
            );
            await session.play();
            await stateWhere(
              player,
              (s) =>
                  s.timeline.position > Duration(milliseconds: targetMs + 350),
            );
            expect(player.state.failure, isNull);
            if (id.startsWith('webm-vp9')) {
              expect(player.state.decoderMode.name, 'hardware');
            }
          }
          seek = true;
          stage = 'end';
          await stateWhere(
            player,
            (s) => s.status == YlPlaybackStatus.completed,
          );
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
            await directory.delete(recursive: true);
            cleaned = true;
          } catch (_) {
            aborted = true;
            outcome = 'cleanup-failed';
          }
          debugPrint(
            'YL_FORMAT_ROW=${jsonEncode({'caseId': id, 'transport': transport, 'platform': Platform.operatingSystem, 'mediaHash': row['sha256'], 'outcome': outcome, 'stage': stage, 'code': code, 'category': category, 'scope': scope, 'engine': engine, 'decoder': decoder, 'firstFrame': firstFrame, 'audioTrackSelected': audioSelected, 'audioOutputVerified': false, 'pixelMarkersVerified': false, 'audioClockUs': null, 'seekProgress': seek, 'completed': completed, 'disposed': cleaned})}',
            wrapWidth: 100000,
          );
        }
        const requireSupport = bool.fromEnvironment(
          'YL_FORMAT_REQUIRE_SUPPORT',
        );
        if (Platform.isMacOS && !requireSupport) {
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
          expect(scope, 'session');
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
