import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/benchmark_trials.dart';
import 'support/compositor_probe.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'owned window compositor frame and seek acquisition',
    (tester) async {
      if (!Platform.isMacOS || !kProfileMode) {
        throw const FormatException('Profile macOS required');
      }
      final context =
          jsonDecode(const String.fromEnvironment('YL_COMPOSITOR_CONTEXT'))
              as Map<String, dynamic>;
      final directory = await Directory.systemTemp.createTemp('yl_compositor_');
      addTearDown(() => directory.delete(recursive: true));
      final library = File('${directory.path}/capture.dylib');
      await library.writeAsBytes(
        base64Decode(const String.fromEnvironment('YL_CAPTURE_LIBRARY')),
      );
      final media = File('${directory.path}/owned.mp4');
      final mediaBytes = base64Decode(
        const String.fromEnvironment('YL_CAPTURE_MEDIA'),
      );
      expect(sha256.convert(mediaBytes).toString(), context['mediaHash']);
      await media.writeAsBytes(mediaBytes);
      final probe = CompositorProbe(library.path);
      Future<void> mount(Widget widget) async {
        runApp(widget);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      await mount(const MaterialApp(home: ColoredBox(color: Colors.black)));
      probe.start();
      var captureStopped = false;
      Future<void> stopCapture() async {
        if (captureStopped) return;
        probe.stop();
        final end = probe.nowUs() + 5000000;
        while (probe.nowUs() < end) {
          if (probe.snapshot()['status'] == 'stopped') {
            captureStopped = true;
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        throw TimeoutException('Owned capture cleanup failed');
      }

      addTearDown(stopCapture);
      var status = 'starting';
      final startupDeadline = probe.nowUs() + 10000000;
      while (status == 'starting' && probe.nowUs() < startupDeadline) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        status = probe.snapshot()['status'] as String;
      }
      expect(
        status,
        'capturing',
        reason: 'Own-window capture must be available',
      );
      final trials = <Map<String, Object?>>[];
      var rows = <Map<String, dynamic>>[];
      var command = <String, Object?>{};
      await runBenchmarkTrials(
        attempts: 3,
        nowUs: probe.nowUs,
        body: (trial) async {
          rows = [];
          command = {
            'startUs': null,
            'seekStartUs': null,
            'targetUs': 5000000,
            'session': null,
          };
          void sample() {
            final result = probe.snapshot();
            command['diagnostic'] = result['diagnostic'];
            if (result['status'] != 'capturing') {
              throw const FormatException('Capture interrupted');
            }
            rows.addAll(
              (result['rows'] as List).map(
                (r) => Map<String, dynamic>.from(r as Map),
              ),
            );
            if (rows.length > 8192) {
              throw const FormatException('Capture bound exceeded');
            }
          }

          final primeStart = probe.nowUs();
          await mount(const MaterialApp(home: ColoredBox(color: Colors.black)));
          var deadline = probe.nowUs() + 5000000;
          while (!rows.any(
                (r) => r['displayUs'] >= primeStart && r['frame'] == null,
              ) &&
              probe.nowUs() < deadline) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            sample();
          }
          expect(
            rows.any((r) => r['displayUs'] >= primeStart && r['frame'] == null),
            isTrue,
          );
          final player = await trial.create(
            YlPlayerController.create(),
            release: (p) => p.dispose(),
          );
          trial.cleanup.add(
            () =>
                mount(const MaterialApp(home: ColoredBox(color: Colors.black))),
          );
          await player.setVolume(0);
          await mount(
            MaterialApp(
              home: Scaffold(
                backgroundColor: Colors.black,
                body: YlPlayerView(controller: player),
              ),
            ),
          );
          final sub = player.events.listen((event) {
            if (event is YlFirstFrameEvent) {
              trial.probe.observe(event.sessionId.value);
            }
          });
          trial.cleanup.insert(0, sub.cancel);
          trial.probe.start();
          command['startUs'] = probe.nowUs();
          final session = await player
              .load(YlFileSource(media.path))
              .timeout(const Duration(seconds: 15));
          command['session'] = session.id.value;
          trial.probe.bind(session.id.value);
          await session.play().timeout(const Duration(seconds: 5));
          deadline = probe.nowUs() + 8000000;
          while (!rows.any(
                (r) =>
                    r['displayUs'] >= (command['startUs'] as int) &&
                    r['frame'] is int &&
                    r['frame'] <= 10,
              ) &&
              probe.nowUs() < deadline) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            sample();
          }
          command['playerState'] = {
            'status': player.state.status.name,
            'positionUs': player.state.timeline.position.inMicroseconds,
            'engine': player.state.engine.name,
            'videoWidth': player.state.videoGeometry?.displaySize.width,
          };
          expect(
            rows.any(
              (r) =>
                  r['displayUs'] >= (command['startUs'] as int) &&
                  r['frame'] is int &&
                  r['frame'] <= 10,
            ),
            isTrue,
          );
          command['seekStartUs'] = probe.nowUs();
          await session
              .seekTo(const Duration(seconds: 5))
              .timeout(const Duration(seconds: 10));
          await session.play().timeout(const Duration(seconds: 5));
          deadline = probe.nowUs() + 2500000;
          while (probe.nowUs() < deadline) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            sample();
          }
          sample();
          final beforeHide = player.state.timeline.position;
          probe.visibility(0);
          try {
            await Future<void>.delayed(const Duration(seconds: 1));
          } finally {
            probe.visibility(1);
          }
          await session.play().timeout(const Duration(seconds: 5));
          final restoredUs = probe.nowUs();
          deadline = restoredUs + 5000000;
          while (!rows.any(
                (r) => r['displayUs'] >= restoredUs && r['frame'] is int,
              ) &&
              probe.nowUs() < deadline) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            sample();
          }
          command['windowRestoreVerified'] =
              rows.any(
                (r) => r['displayUs'] >= restoredUs && r['frame'] is int,
              ) &&
              player.state.timeline.position >= beforeHide;
          expect(command['windowRestoreVerified'], isTrue);
          expect(player.state.sessionId, session.id);
          expect(player.state.failure, isNull);
        },
        record: (row) {
          final skipped = row['outcome'] == 'skipped';
          trials.add({
            'attempt': row['attempt'],
            'outcome': row['outcome'],
            'cleanup': row['outcome'] == 'passed' ? 'passed' : 'unknown',
            'command': skipped ? null : command,
            'rows': skipped ? <Object?>[] : rows,
          });
        },
      );
      await stopCapture();
      debugPrint(
        'YL_COMPOSITOR_RUN=${jsonEncode({'context': context, 'trials': trials, 'captureStopped': captureStopped})}',
        wrapWidth: 1000000,
      );
      expect(trials.every((row) => row['outcome'] == 'passed'), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
