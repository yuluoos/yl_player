// Release host verification after an issued profile is packaged and signed.
// The host must use YlPlayerApplePlugin's public registration (no trial admission).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yl_player/yl_player.dart';

void require(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

Future<void> stateWhere(YlPlayerController player, bool Function(YlPlayerState) match) async {
  if (match(player.state)) return;
  await player.states.firstWhere((state) {
    if (state.failure != null) throw StateError('playback failure: ${state.failure}');
    return match(state);
  }).timeout(const Duration(seconds: 15));
}

Future<void> runPublicVerification() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('yl_player_example/display_readback');
  final data = await rootBundle.load('assets/test_media/format_matrix/mkv-av1-opus.mkv');
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final directory = await Directory.systemTemp.createTemp('yl_av1_public_');
  final file = File('${directory.path}/clip.mkv');
  await file.writeAsBytes(bytes);
  try {
    for (final transport in ['file', 'http']) {
      HttpServer? server;
      final requests = <Map<String, Object?>>[];
      if (transport == 'http') {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          final response = request.response;
          response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          response.headers.contentType = ContentType.binary;
          final range = request.headers.value(HttpHeaders.rangeHeader);
          var start = 0, end = bytes.length - 1;
          if (range != null) {
            final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range)!;
            start = int.parse(match[1]!);
            if (match[2]!.isNotEmpty) end = int.parse(match[2]!).clamp(0, end);
            if (start > end) {
              response.statusCode = 416;
              await response.close();
              return;
            }
            response.statusCode = 206;
            response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${bytes.length}');
          }
          requests.add({'method': request.method, 'range': range, 'status': response.statusCode});
          response.contentLength = end - start + 1;
          if (request.method != 'HEAD') response.add(bytes.sublist(start, end + 1));
          await response.close();
        });
      }
      final player = await YlPlayerController.create(options: const YlPlayerOptions(audioPolicy: YlAudioPolicy.appManaged));
      final markers = <Map<String, Object?>>[];
      final systemSamples = <Map<String, Object?>>[];
      Future<void> captureSystem(String phase) async {
        final metrics = await channel.invokeMapMethod<String, dynamic>('performance');
        require(metrics?['status'] == 'observed' && (metrics?['totalFrames'] ?? 0) > 0 &&
          metrics?['droppedFrames'] == 0 && metrics?['corruptedFrames'] == 0 &&
          metrics?['windowOcclusionVisible'] == true, 'native system output failed: $transport/$phase $metrics');
        systemSamples.add({'phase': phase, ...metrics!});
      }
      var observedDrops = 0;
      final dropObserver = player.states.listen((state) {
        final drops = state.metrics.droppedVideoFrames ?? 0;
        if (drops > observedDrops) {
          observedDrops = drops;
          stdout.writeln('PUBLIC_DROP_STATE ${jsonEncode({'transport': transport,
            'positionUs': state.timeline.position.inMicroseconds, 'status': state.status.name,
            'drops': drops, 'revision': state.revision})}');
          unawaited(channel.invokeMethod<void>('captureDiagnostics'));
        }
      });
      try {
        runApp(MaterialApp(home: Center(child: SizedBox(width: 320, height: 180,
          child: YlPlayerView(controller: player)))));
        await WidgetsBinding.instance.endOfFrame;
        final source = server == null ? YlFileSource(file.path) : YlNetworkSource(
          Uri.parse('http://127.0.0.1:${server.port}/clip.mkv'), intent: YlStreamIntent.onDemand);
        stdout.writeln('PUBLIC_STEP $transport load');
        final session = await player.load(source);
        await session.ready.timeout(const Duration(seconds: 15));
        await session.firstFrame.timeout(const Duration(seconds: 10));
        require(player.state.decoderMode == YlDecoderMode.software, 'AV1 did not use qualified software decoder');
        require(player.state.audioTracks.any((track) => track.isSelected), 'missing selected audio track');
        Future<void> marker(int second, String phase) async {
          final expected = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 255]][second];
          final wait = Stopwatch()..start();
          Object? lastReadback;
          while (true) {
            require(player.state.status == YlPlaybackStatus.paused, 'readback requires paused playback');
            final image = await channel.invokeMapMethod<String, dynamic>('snapshot');
            lastReadback = image;
            if (image?['status'] == 'observed') {
              final pixels = (image!['pixels'] as List).cast<int>();
              final rgb = pixels.sublist(12, 15);
              if (List.generate(3, (c) => (rgb[c] - expected[c]).abs() <= 40).every((x) => x)) {
                markers.add({'phase': phase, 'marker': second, 'rgb': rgb,
                  'positionUs': player.state.timeline.position.inMicroseconds});
                await captureSystem(phase == 'play' ? 'play-$second' : phase);
                return;
              }
            }
            require(wait.elapsed < const Duration(seconds: 3), 'native displayed marker mismatch: $phase/$second position=${player.state.timeline.position.inMicroseconds} revision=${player.state.revision} readback=$lastReadback');
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
        }
        stdout.writeln('PUBLIC_STEP $transport play');
        await session.play();
        for (var second = 0; second < 4; second++) {
          await stateWhere(player, (s) => s.timeline.position.inMilliseconds >= second * 1000 + 250);
          await session.pause();
          await stateWhere(player, (s) => s.status == YlPlaybackStatus.paused);
          await marker(second, 'play');
          await session.play();
        }
        for (final target in [2000, 1250, 0]) {
          stdout.writeln('PUBLIC_STEP $transport pause-seek-$target');
          await session.pause();
          await captureSystem('before-seek-$target');
          await session.seekTo(Duration(milliseconds: target));
          stdout.writeln('PUBLIC_SEEK_RETURN $transport target=$target position=${player.state.timeline.position.inMilliseconds} revision=${player.state.revision}');
          await session.play();
          await stateWhere(player, (s) => s.timeline.position.inMilliseconds >= target + 250 &&
            s.timeline.position.inMilliseconds < target + 750);
          stdout.writeln('PUBLIC_SEEK_WAIT $transport target=$target position=${player.state.timeline.position.inMilliseconds} revision=${player.state.revision}');
          await session.pause();
          await stateWhere(player, (s) => s.status == YlPlaybackStatus.paused);
          await marker(target ~/ 1000, 'seek-$target');
          await session.play();
          await stateWhere(player, (s) => s.timeline.position.inMilliseconds >= target + 350);
        }
        stdout.writeln('PUBLIC_STEP $transport await-completed');
        await stateWhere(player, (s) => s.status == YlPlaybackStatus.completed);
        require(player.state.failure == null, 'terminal failure');
        require(player.state.metrics.droppedVideoFrames == 0, 'scheduler dropped a frame');
        await captureSystem('completed');
        if (server != null) require(requests.any((r) => r['status'] == 206), 'HTTP range was not exercised');
        stdout.writeln('PUBLIC_PLAYBACK ${jsonEncode({'transport': transport, 'decoder': player.state.decoderMode.name,
          'completed': true, 'markers': markers, 'requests': requests, 'systemSamples': systemSamples,
          'pixelVerificationMethod': 'native-renderer-displayed-buffer', 'readbackWhilePaused': true, 'acousticOutputVerified': false})}');
      } finally {
        await dropObserver.cancel();
        final dispose = Stopwatch()..start();
        await player.dispose().timeout(const Duration(seconds: 3));
        stdout.writeln('PUBLIC_DISPOSE ${jsonEncode({'transport': transport, 'elapsedUs': dispose.elapsedMicroseconds})}');
        runApp(const SizedBox.shrink());
        await WidgetsBinding.instance.endOfFrame;
        await server?.close(force: true);
      }
    }
  } finally {
    await directory.delete(recursive: true);
  }
}

Future<void> main() async {
  var status = 1;
  try {
    await runPublicVerification();
    status = 0;
  } catch (error) {
    stdout.writeln('PUBLIC_ERROR $error');
  } finally {
    stdout.writeln('PUBLIC_FINISH $status');
    await stdout.flush();
    exit(status);
  }
}
