// Standalone public player for the live Core Audio route collector.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yl_player/yl_player.dart';

import 'support/range_media_server.dart';

void report(String kind, Map<String, Object?> data) {
  stdout.writeln('ROUTE_EVENT ${jsonEncode({'kind': kind, ...data})}');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final directory = await Directory.systemTemp.createTemp('yl_output_route_');
  final player = await YlPlayerController.create(
    options: const YlPlayerOptions(audioPolicy: YlAudioPolicy.appManaged),
  );
  var code = 1;
  RangeMediaServer? server;
  Timer? timer;
  StreamSubscription<void>? commands;
  try {
    final av1 = Platform.environment['YL_ROUTE_AV1'] == '1';
    final asset = av1
        ? 'assets/test_media/format_matrix/qual-av1.mkv'
        : 'assets/test_media/long_60fps_h264_aac.mkv';
    final file = File('${directory.path}/route.mkv');
    if (Platform.environment['YL_ROUTE_TRANSPORT'] == 'http') {
      server = await RangeMediaServer.start(asset: asset);
    } else {
      final bytes = await rootBundle.load(asset);
      await file.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    }
    await player.setVolume(0.15);
    runApp(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 320,
            height: 180,
            child: YlPlayerView(controller: player),
          ),
        ),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    final end = Completer<void>();
    var loadCount = 0;
    Future<void> playFrom(Duration position) async {
      timer?.cancel();
      final origin = server;
      final uri = origin?.mediaUri.replace(
        path: '/route.mkv',
        query: 'load=${++loadCount}',
      );
      final session = await player.load(
        uri == null
            ? YlFileSource(file.path)
            : YlNetworkSource(uri, intent: YlStreamIntent.onDemand),
        options: YlLoadOptions(startPosition: position),
      );
      await session.ready.timeout(const Duration(seconds: 15));
      await session.play();
      await session.firstFrame.timeout(const Duration(seconds: 10));
      if (av1 && player.state.decoderMode != YlDecoderMode.software) {
        throw StateError('Expected qualified AV1 software decoding');
      }
      if (origin != null) {
        final ranges = origin.requests
            .where(
              (r) =>
                  r.uri.query == uri!.query &&
                  r.method == 'GET' &&
                  r.statusCode == HttpStatus.partialContent,
            )
            .map((r) => r.header('range'))
            .toList();
        if (ranges.isEmpty) {
          throw StateError('No HTTP range read for load $loadCount');
        }
        report('http', {
          'session': player.state.sessionId?.value,
          'load': loadCount,
          'ranges': ranges,
        });
      }
      timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        final s = player.state;
        report('state', {
          'session': s.sessionId?.value,
          'status': s.status.name,
          'positionUs': s.timeline.position.inMicroseconds,
          'decoder': s.decoderMode.name,
          'audio': s.audioTracks
              .where((t) => t.isSelected)
              .map((t) => t.id)
              .toList(),
          'failure': s.failure?.code,
        });
        if (!end.isCompleted && s.status == YlPlaybackStatus.completed) {
          end.complete();
        }
      });
    }

    await playFrom(
      av1 ? const Duration(minutes: 19, seconds: 30) : Duration.zero,
    );
    commands = stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asyncMap((line) async {
          if (line != 'reload') throw StateError(line);
          final position = player.state.timeline.position;
          report('reload', {
            'previous': player.state.sessionId?.value,
            'positionUs': position.inMicroseconds,
          });
          await playFrom(position);
        })
        .listen(
          (_) {},
          onError: (Object error) {
            if (!end.isCompleted) end.completeError(error);
          },
        );
    await end.future.timeout(const Duration(seconds: 85));
    code = 0;
  } catch (error) {
    report('error', {'detail': error.toString()});
  } finally {
    await commands?.cancel();
    timer?.cancel();
    await player.dispose().timeout(const Duration(seconds: 3));
    await server?.close();
    await directory.delete(recursive: true);
    report('finish', {'code': code});
    await stdout.flush();
  }
  exit(code);
}
