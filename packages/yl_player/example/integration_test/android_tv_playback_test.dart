import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/bound_source.dart';

const observer = MethodChannel('yl_player_example/debug/frame_observation');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const suite = String.fromEnvironment('YL_TV_CASE', defaultValue: 'all');
  // Select one cold-start case per process from the same installed test APK.
  final selection = suite == 'speed-cold'
      ? File(
          '${Directory.systemTemp.path}/yl_tv_speed_case',
        ).readAsStringSync().trim()
      : suite;
  if (suite == 'speed-cold' &&
      !{'speed-http', 'speed-file'}.contains(selection)) {
    throw ArgumentError.value(selection, 'yl_tv_speed_case');
  }
  for (final name in [
    'av1-file',
    'av1-http',
    'speed-file',
    'speed-http',
    'lifecycle',
    'continuous',
  ]) {
    if (selection == 'short' && name == 'continuous') continue;
    if (!['all', 'short', name].contains(selection) &&
        !(selection == 'speed' && name.startsWith('speed-'))) {
      continue;
    }
    testWidgets('Android TV $name', (tester) async {
      final av1 = name.startsWith('av1');
      final sustained = name == 'continuous';
      final http = name.endsWith('http');
      final asset = av1 ? 'mkv-av1-opus.mkv' : 'continuous-avc-aac.mkv';
      final data = await rootBundle.load(
        'assets/test_media/format_matrix/$asset',
      );
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final hash = sha256.convert(bytes).toString();
      final directory = await Directory.systemTemp.createTemp('yl_tv_');
      final file = File('${directory.path}/$asset');
      BoundSource? server;
      YlPlayerController? player;
      var observing = false;
      final clock = Stopwatch()..start();
      void emit(String phase, [Map<String, Object?> extra = const {}]) {
        final s = player?.state;
        final row = {
          'case': name,
          'phase': phase,
          'elapsedMs': clock.elapsedMilliseconds,
          'status': s?.status.name,
          'positionMs': s?.timeline.position.inMilliseconds,
          'engine': s?.engine.name,
          'decoder': s?.decoderIdentity,
          'mode': s?.decoderMode.name,
          'presented': player?.isCurrentFramePresented,
          'failure': s?.failure?.code,
          'rebuffers': s?.metrics.rebufferCount,
          'drops': s?.metrics.droppedVideoFrames,
          'underruns': s?.metrics.audioUnderruns,
          ...extra,
        };
        debugPrintSynchronously('YL_TV=${jsonEncode(row)}');
      }

      try {
        final YlMediaSource source;
        if (http) {
          const base = String.fromEnvironment('YL_TV_HTTP_BASE');
          if (base.isEmpty) {
            server = await BoundSource.serve(bytes, asset, name, hash);
          }
          source = YlNetworkSource(
            server?.uri ?? Uri.parse('$base/$asset'),
            intent: YlStreamIntent.onDemand,
            networkPolicy: const YlNetworkPolicy.managed(),
            request: YlHttpRequest(headers: {'x-yl-bound-run': name}),
          );
        } else {
          await file.writeAsBytes(bytes, flush: true);
          source = YlFileSource(file.path);
        }
        final active = await YlPlayerController.create();
        player = active;
        Future<void> mount() => tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: YlPlayerView(controller: active),
          ),
        );
        await mount();
        emit('load', {'sha256': hash});
        final session = await active
            .load(source)
            .timeout(const Duration(seconds: 20));
        await session.ready.timeout(const Duration(seconds: 15));
        await session.play();
        await session.firstFrame.timeout(const Duration(seconds: 18));
        emit('firstFrame');
        Future<void> waitState(bool Function(YlPlayerState s) predicate) async {
          final wait = Stopwatch()..start();
          while (!predicate(active.state)) {
            if (active.state.failure != null || wait.elapsed.inSeconds >= 12) {
              throw StateError(
                'Playback wait failed: ${active.state.status} ${active.state.failure?.code}',
              );
            }
            await tester.pump(const Duration(milliseconds: 100));
          }
        }

        if (av1) {
          for (final ms in [1200, 400, 2400]) {
            await session.pause();
            await session.seekTo(Duration(milliseconds: ms));
            await waitState(
              (s) => (s.timeline.position.inMilliseconds - ms).abs() < 300,
            );
            await session.play();
            await waitState(
              (s) => s.timeline.position.inMilliseconds >= ms + 350,
            );
            emit('seek', {'targetMs': ms});
          }
          await waitState((s) => s.status == YlPlaybackStatus.completed);
          emit('completed');
        } else {
          await observer.invokeMethod('installActive', {
            'sessionId': session.id.value,
          });
          observing = true;
          final failures = <String>[];
          int? rendered;
          Future<void> sample(
            String phase, {
            bool? tunnel,
            Map<String, Object?> extra = const {},
          }) async {
            final output = await observer.invokeMapMethod<String, dynamic>(
              'playbackOutput',
            );
            rendered = output?['rendered'] as int?;
            emit(phase, {'output': output, ...extra});
            if (tunnel != null &&
                (output?['enabled'] != tunnel ||
                    output?['requested'] != tunnel)) {
              failures.add(
                '$phase expected tunneling=$tunnel, observed $output',
              );
            }
          }

          Future<void> window(
            String phase,
            int seconds,
            double speed, {
            bool steady = false,
          }) async {
            final initial = active.state.metrics;
            final initialFrames = rendered;
            final start = active.state.timeline.position.inMilliseconds;
            final wall = Stopwatch()..start();
            await Future<void>.delayed(Duration(seconds: seconds));
            final elapsed = wall.elapsedMilliseconds;
            final advance =
                active.state.timeline.position.inMilliseconds - start;
            final ratio = advance / elapsed;
            await sample(
              phase,
              tunnel: speed == 1,
              extra: {
                'wallMs': elapsed,
                'advancedMs': advance,
                'actualSpeed': ratio,
              },
            );
            expect(active.state.failure, isNull);
            if (active.state.status != YlPlaybackStatus.playing) {
              failures.add('$phase ended in ${active.state.status.name}');
            }
            if (steady &&
                (rendered == null ||
                    initialFrames == null ||
                    rendered! <= initialFrames)) {
              failures.add('$phase rendered no new video frames');
            }
            if (steady &&
                (active.state.metrics.audioUnderruns !=
                        initial.audioUnderruns ||
                    active.state.metrics.rebufferCount !=
                        initial.rebufferCount)) {
              failures.add(
                '$phase audio underrun or rebuffer during steady playback',
              );
            }
            if ((ratio - speed).abs() > .25) {
              failures.add('$phase requested $speed, measured $ratio');
            }
          }

          Future<void> fromNormalSpeed(String phase, double rate) async {
            final underrunsBefore = active.state.metrics.audioUnderruns;
            final before = (await observer.invokeMethod<int>('clockMs'))!;
            if (rate == 3) {
              emit('$phase-command', {'deviceClockMs': before});
            }
            final start = active.state.timeline.position;
            final wall = Stopwatch()..start();
            int? firstMediaSecondMs;
            void observePosition() {
              if (active.state.timeline.position - start >=
                  const Duration(seconds: 1)) {
                firstMediaSecondMs ??= wall.elapsedMilliseconds;
              }
            }

            active.addListener(observePosition);
            try {
              await session.setPlaybackSpeed(rate);
              await window(phase, 12, rate);
              final underrunsAfter = active.state.metrics.audioUnderruns;
              if (rate == 3 &&
                  (underrunsBefore == null ||
                      underrunsAfter != underrunsBefore)) {
                failures.add(
                  '$phase audio underruns at direct switch: '
                  '$underrunsBefore -> $underrunsAfter',
                );
              }
              final events = await observer.invokeListMethod<dynamic>('read');
              final frames = events!.whereType<Map>().where(
                (e) =>
                    e['kind'] == 'frame' &&
                    e['public'] == true &&
                    e['matchesCurrentSurface'] == true &&
                    (e['timeMs'] as int) >= before,
              );
              final firstFrameMs = frames.isEmpty
                  ? null
                  : (frames.first['timeMs'] as int) - before;
              if (firstMediaSecondMs == null || firstFrameMs == null) {
                failures.add(
                  '$phase missing position or Surface frame after switching',
                );
              }
              emit('$phase-startup', {
                'underrunsBefore': underrunsBefore,
                'underrunsAfter': underrunsAfter,
                'firstMediaSecondMs': firstMediaSecondMs,
                'firstFrameMs': firstFrameMs,
              });
            } finally {
              active.removeListener(observePosition);
            }
          }

          if (sustained) {
            for (var i = 0; i < 20; i++) {
              await window('minute-${i + 1}', 60, 1);
            }
          } else {
            await window('normal', 10, 1);
            if (name != 'lifecycle') {
              for (final rate in [1.5, 2.0, 3.0]) {
                await fromNormalSpeed('fast-$rate', rate);
                await window('steady-$rate', 12, rate, steady: true);
                await session.setPlaybackSpeed(1);
                await window('restored-$rate', 10, 1);
                await session.pause();
                await waitState((s) => s.status == YlPlaybackStatus.paused);
                await sample('paused-$rate', tunnel: true);
                await session.play();
                await waitState((s) => s.status == YlPlaybackStatus.playing);
              }
              // Also change rates without rebuilding the untunneled output in between.
              for (final rate in [1.5, 2.0, 3.0]) {
                await session.setPlaybackSpeed(rate);
                await window('direct-$rate', 12, rate);
              }
              await session.setPlaybackSpeed(1);
              await window('direct-restored', 10, 1);
              // Repeat the direct jump after uninterrupted 1x playback.
              await fromNormalSpeed('repeat-3.0', 3);
              await session.setPlaybackSpeed(1);
              await window('repeat-restored', 10, 1);
            }
            // Preserve each command's outcome even if a previous phase remained buffering.
            Future<void> checkState(
              String phase,
              bool Function(YlPlayerState s) predicate,
            ) async {
              try {
                await waitState(predicate);
              } on StateError catch (error) {
                failures.add('$phase: $error');
              }
              await sample(phase);
            }

            await session.pause();
            await checkState(
              'pause',
              (s) => s.status == YlPlaybackStatus.paused,
            );
            final paused = active.state.timeline.position.inMilliseconds;
            await Future<void>.delayed(const Duration(seconds: 1));
            if ((active.state.timeline.position.inMilliseconds - paused).abs() >
                150) {
              failures.add('Position advanced while paused');
            }
            await session.seekTo(const Duration(seconds: 90));
            await checkState(
              'pausedSeek',
              (s) => (s.timeline.position.inMilliseconds - 90000).abs() < 500,
            );
            await tester.pumpWidget(const SizedBox());
            await tester.pump(const Duration(seconds: 1));
            await sample('unmounted', tunnel: false);
            final beforeRemount =
                await observer.invokeListMethod<dynamic>('read') ?? [];
            await mount();
            await session.play();
            await window('remounted', 8, 1);
            final events =
                await observer.invokeListMethod<dynamic>('read') ?? [];
            final frames = events
                .skip(beforeRemount.length)
                .whereType<Map>()
                .where(
                  (event) =>
                      event['kind'] == 'frame' &&
                      event['public'] == true &&
                      event['matchesCurrentSurface'] == true,
                );
            emit('frames', {'frames': frames.toList()});
            if (frames.isEmpty || !active.isCurrentFramePresented) {
              failures.add('No public frame observed after remount');
            }
          }
          expect(failures, isEmpty);
        }
      } finally {
        try {
          if (observing) await observer.invokeMethod('remove');
        } finally {
          try {
            await tester.pumpWidget(const SizedBox());
            await player?.dispose();
            emit('disposed', {if (server != null) 'http': server.receipt});
          } finally {
            await server?.close();
            await directory.delete(recursive: true);
          }
        }
      }
    }, timeout: Timeout(Duration(minutes: name == 'continuous' ? 23 : 4)));
  }
}
