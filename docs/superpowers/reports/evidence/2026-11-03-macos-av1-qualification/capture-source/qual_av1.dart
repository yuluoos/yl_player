import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yl_player/yl_player.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final p = await YlPlayerController.create();
  runApp(MaterialApp(home: Center(child: SizedBox(width: 320, height: 180, child: YlPlayerView(controller: p)))));
  await WidgetsBinding.instance.endOfFrame;
  final dir = await Directory.systemTemp.createTemp('yl_av1_qualification_');
  Timer? report;
  StreamSubscription<YlPlayerState>? monitor;
  var status = 1;
  try {
    final bytes = await rootBundle.load('assets/test_media/format_matrix/qual-av1.mkv');
    final path = File('${dir.path}/long.mkv');
    await path.writeAsBytes(bytes.buffer.asUint8List(bytes.offsetInBytes,bytes.lengthInBytes));
    final session = await p.load(YlFileSource(path.path));
    await session.ready.timeout(const Duration(seconds: 15));
    await session.firstFrame.timeout(const Duration(seconds: 10));
    await WidgetsBinding.instance.endOfFrame;
    final done = Completer<void>();
    monitor = p.states.listen((s) {
      if (done.isCompleted) return;
      if (s.failure != null || (s.metrics.droppedVideoFrames ?? 0) > 0) {
        done.completeError(StateError('failure=${s.failure}, drops=${s.metrics.droppedVideoFrames}'));
      } else if (s.status == YlPlaybackStatus.completed) {
        done.complete();
      }
    });
    const readback = MethodChannel('yl_player_example/display_readback');
    late int initialOcclusions;
    final startup = Stopwatch()..start();
    while (true) {
      final m = await readback.invokeMapMethod<String, dynamic>('performance');
      if (m?['windowOcclusionVisible'] == true && m?['surfaceHasBounds'] == true) {
        initialOcclusions = m!['windowOcclusions'] as int;
        stdout.writeln('QUAL_PREFLIGHT ${jsonEncode({'waitUs':startup.elapsedMicroseconds,'layer':m,'positionUs':p.state.timeline.position.inMicroseconds,'decoder':p.state.decoderMode.name,'firstFrameCompleted':true})}');
        break;
      }
      if (startup.elapsed > const Duration(seconds: 10)) throw StateError('native view unavailable before play: $m');
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    final clock = Stopwatch()..start();
    await session.play();
    await session.firstFrame.timeout(const Duration(seconds: 10));
    final watch = done.future.timeout(const Duration(minutes: 22));
    Future<void> systemMetrics({bool finalSample = false}) async {
      final m = await readback.invokeMapMethod<String,dynamic>('performance');
      if (m == null) throw StateError('missing system metrics');
      stdout.writeln('QUAL_SYSTEM ${jsonEncode(m)}');
      if (m['windowOcclusions'] != initialOcclusions || m['windowOcclusionVisible'] != true || (m['droppedFrames'] ?? 0) > 0 || (m['corruptedFrames'] ?? 0) > 0 ||
          (finalSample && (m['totalFrames'] ?? 0) <= 0)) {
        final error = StateError('system presentation failed $m');
        if (!done.isCompleted) done.completeError(error); else throw error;
      }
    }
    void tick() {
      final s = p.state;
      stdout.writeln('QUAL_DART ${jsonEncode({'us': clock.elapsedMicroseconds,'position':s.timeline.position.inMicroseconds,'status':s.status.name,'decoder':s.decoderMode.name,'drops':s.metrics.droppedVideoFrames})}');
    }
    report = Timer.periodic(const Duration(seconds: 2), (_) => tick());
    final systemTimer = Timer.periodic(const Duration(seconds: 5), (_) => systemMetrics());
    try { await watch; } finally { systemTimer.cancel(); }
    await systemMetrics(finalSample: true);
    tick();
    if (clock.elapsed < const Duration(minutes: 20) || p.state.decoderMode != YlDecoderMode.software ||
        p.state.metrics.droppedVideoFrames != 0) throw StateError('invalid terminal evidence');
    status = 0;
  } catch (e) {
    stdout.writeln('QUAL_ERROR $e');
    await const MethodChannel('yl_player_example/display_readback').invokeMethod<void>('captureDiagnostics');
  } finally {
    report?.cancel(); await monitor?.cancel(); await p.dispose(); await dir.delete(recursive:true);
    await const MethodChannel('yl_player_example/display_readback').invokeMethod<void>('captureFinish');
    stdout.writeln('QUAL_FINISH $status'); await stdout.flush(); exit(status);
  }
}
