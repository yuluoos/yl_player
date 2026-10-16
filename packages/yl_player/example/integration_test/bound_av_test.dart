import 'dart:io';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/paused_frame_capture.dart';
import 'support/bound_source.dart';
import 'support/bound_cleanup.dart';

/// Built once and launched with a host-frozen plan. Only public APIs drive playback.
/// The opt-in native bridge observes this same session and verifies installed bytes.
/// Apple samples the attached native view; Android samples Flutter composition.
/// Neither observation certifies physical screen/speaker synchronization.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isMacOS || Platform.isIOS) {
    // Native views need ordinary live widget/layout updates between observations.
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  }
  const bridge = MethodChannel('yl_player_example/debug/bound_av');
  String? failure;
  binding.allTestsPassed.future.then((passed) async {
    await bridge.invokeMethod('finish', {'passed': passed, 'failure': failure});
  });
  testWidgets('public Flutter same-build same-session AV', (tester) async {
    final plan = Map<String, dynamic>.from(
      await bridge.invokeMapMethod('plan') ?? {},
    );
    Future<void> mount(Widget widget) async {
      if (Platform.isMacOS || Platform.isIOS) {
        // Use the application's normal live root/layout path. A test pump waits
        // for a specific vsync and can remain pending across native-view changes.
        runApp(widget);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      } else {
        await tester.pumpWidget(widget);
      }
    }

    try {
      for (final raw in plan['planned'] as List) {
        final item = Map<String, dynamic>.from(raw as Map);
        debugPrint('P03_PUBLIC begin ${item['caseId']}');
        final data = await rootBundle.load(
          'assets/test_media/format_matrix/${item['file']}',
        );
        final bytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        expect(sha256.convert(bytes).toString(), item['mediaHash']);
        final directory = await Directory.systemTemp.createTemp(
          'yl_public_av_',
        );
        final file = await File(
          '${directory.path}/${item['file']}',
        ).writeAsBytes(bytes, flush: true);
        final server = item['transport'] == 'http'
            ? await BoundSource.serve(
                bytes,
                item['file'] as String,
                plan['runId'] as String,
                item['mediaHash'] as String,
              )
            : null;
        final source = server == null
            ? YlFileSource(file.path)
            : YlNetworkSource(
                server.uri,
                intent: YlStreamIntent.onDemand,
                networkPolicy: const YlNetworkPolicy.managed(),
                request: YlHttpRequest(
                  headers: {'x-yl-bound-run': plan['runId'] as String},
                ),
              );
        YlPlayerController? player;
        var disposed = false;
        var caseFailed = false;
        final lifecycle = <String, bool>{
          'created': false,
          'ready': false,
          'firstFrame': false,
          'completed': false,
          'disposed': false,
        };
        final key = GlobalKey();
        String? sessionId;
        try {
          await bridge.invokeMethod('begin', {
            'caseId': item['caseId'],
            'path': file.path,
            'locator': server?.uri.toString() ?? file.path,
          });
          player = await YlPlayerController.create(
            options: const YlPlayerOptions(
              audioPolicy: YlAudioPolicy.appManaged,
            ),
          );
          lifecycle['created'] = true;
          await mount(
            MaterialApp(
              home: Center(
                child: RepaintBoundary(
                  key: key,
                  child: SizedBox(
                    width: 320,
                    height: 180,
                    child: YlPlayerView(controller: player),
                  ),
                ),
              ),
            ),
          );
          final session = await player
              .load(source)
              .timeout(const Duration(seconds: 15));
          sessionId = session.id.value;
          await session.ready.timeout(const Duration(seconds: 12));
          lifecycle['ready'] = true;
          debugPrint('P03_PUBLIC ready $sessionId');
          await bridge.invokeMethod('bind', {'sessionId': sessionId});
          final continuousSourcePull =
              (Platform.isMacOS || Platform.isIOS) &&
              await bridge.invokeMethod<String>('observationKind', {
                    'sessionId': sessionId,
                  }) ==
                  'avplayerSourcePull';
          Future<void> captureUntil(
            bool Function() done, {
            int minimumNativeClockUs = 0,
          }) async {
            final timer = Stopwatch()..start();
            int? observedNativeClock;
            final apple = Platform.isMacOS || Platform.isIOS;
            await captureNativePhase(
              done: done,
              minimumNativeClockUs: minimumNativeClockUs,
              capture: () async {
                if (apple && timer.elapsed >= const Duration(seconds: 12)) {
                  final details = await bridge.invokeMethod('diagnostics', {
                    'sessionId': sessionId,
                  });
                  debugPrint(
                    'P03_PUBLIC timeout native=$details public=${player!.state.status} '
                    'position=${player.state.timeline.position} observed=$observedNativeClock',
                  );
                }
                expect(timer.elapsed, lessThan(const Duration(seconds: 12)));
                if (apple) {
                  // Apple's displayedPixelBuffer requires a zero render rate.
                  // Advance real playback, then pause through the public API for
                  // a snapshot paired with the renderer's consumed position.
                  await Future<void>.delayed(const Duration(milliseconds: 150));
                } else {
                  await tester.pump(const Duration(milliseconds: 35));
                }
                if (Platform.isMacOS || Platform.isIOS) {
                  final completed =
                      player!.state.status == YlPlaybackStatus.completed;
                  Future<void> releaseReadback() => bridge.invokeMethod<void>(
                    'endReadback',
                    {'sessionId': sessionId},
                  );
                  if (continuousSourcePull) {
                    // Source-pull evidence needs continuous audio. Only the
                    // actual display layer is frozen for readback and restored.
                    try {
                      return await bridge.invokeMethod<int>('capture', {
                        'sessionId': sessionId,
                      });
                    } finally {
                      await releaseReadback();
                    }
                  }
                  try {
                    observedNativeClock = await capturePausedFrame(
                      readyToPause: () async =>
                          await bridge.invokeMethod<bool>('consumptionReady', {
                            'sessionId': sessionId,
                          }) ==
                          true,
                      pause: () async {
                        if (!completed) {
                          await session.pause().timeout(
                            const Duration(seconds: 12),
                          );
                        }
                      },
                      read: () => bridge.invokeMethod<int>('capture', {
                        'sessionId': sessionId,
                      }),
                      resume: () async {
                        await releaseReadback();
                        if (!completed) {
                          await session.play().timeout(
                            const Duration(seconds: 12),
                          );
                        }
                      },
                    );
                  } catch (_) {
                    await bridge.invokeMethod('diagnostics', {
                      'sessionId': sessionId,
                    });
                    rethrow;
                  } finally {
                    await releaseReadback();
                  }
                  return observedNativeClock;
                }
                final token = await bridge.invokeMethod<int>('clock', {
                  'sessionId': sessionId,
                });
                final boundary =
                    key.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary;
                final image = await boundary.toImage(pixelRatio: 1);
                try {
                  final rgba = (await image.toByteData(
                    format: ui.ImageByteFormat.rawRgba,
                  ))!;
                  final offset =
                      ((image.height ~/ 2) * image.width + image.width ~/ 2) *
                      4;
                  observedNativeClock = await bridge.invokeMethod<int>(
                    'pixel',
                    {
                      'sessionId': sessionId,
                      'token': token,
                      'rgb': [
                        for (var c = 0; c < 3; c++) rgba.getUint8(offset + c),
                      ],
                    },
                  );
                } finally {
                  image.dispose();
                }
                return observedNativeClock;
              },
            );
          }

          await session.play().timeout(const Duration(seconds: 12));
          await session.firstFrame.timeout(const Duration(seconds: 10));
          lifecycle['firstFrame'] = true;
          await captureUntil(
            () => player!.state.status == YlPlaybackStatus.completed,
          );
          lifecycle['completed'] = true;
          debugPrint('P03_PUBLIC completed $sessionId');
          await bridge.invokeMethod('retain', {
            'sessionId': sessionId,
            'phase': 'play',
          });
          for (final target in [1250, 2250, 0]) {
            await session.pause().timeout(const Duration(seconds: 12));
            await bridge.invokeMethod('seekPhase', {
              'sessionId': sessionId,
              'targetMs': target,
            });
            debugPrint('P03_PUBLIC seek $sessionId $target');
            await session
                .seekTo(Duration(milliseconds: target))
                .timeout(const Duration(seconds: 12));
            debugPrint('P03_PUBLIC seek accepted $sessionId $target');
            if (Platform.isMacOS || Platform.isIOS) {
              await waitForNativePhase(
                () async =>
                    await bridge.invokeMethod<bool>('awaitPhase', {
                      'sessionId': sessionId,
                    }) ==
                    true,
              );
            } else {
              await bridge.invokeMethod('awaitPhase', {'sessionId': sessionId});
            }
            await session.play().timeout(const Duration(seconds: 12));
            await captureUntil(
              () =>
                  player!.state.timeline.position.inMilliseconds >=
                  target + 650,
              minimumNativeClockUs: (target + 650) * 1000,
            );
            // End the continuous source-pull phase before retaining its PCM.
            if (continuousSourcePull) {
              await session.pause().timeout(const Duration(seconds: 12));
            }
            await bridge.invokeMethod('retain', {
              'sessionId': sessionId,
              'phase': 'seek-$target',
            });
          }
          debugPrint('P03_PUBLIC disposing $sessionId');
          await player.dispose().timeout(const Duration(seconds: 10));
          disposed = true;
          lifecycle['disposed'] = true;
          if (Platform.isMacOS || Platform.isIOS) {
            await waitForNativePhase(
              () async =>
                  await bridge.invokeMethod<bool>('releaseReady', {
                    'sessionId': sessionId,
                  }) ==
                  true,
            );
          }
          await bridge.invokeMethod('finishCase', {
            'sessionId': sessionId,
            'lifecycle': lifecycle,
            'networkReceipt': server?.receipt,
          });
        } catch (_) {
          caseFailed = true;
          if ((Platform.isMacOS || Platform.isIOS) && sessionId != null) {
            try {
              await bridge.invokeMethod('diagnostics', {
                'sessionId': sessionId,
              });
            } catch (_) {
              /* Keep the original playback/cleanup failure. */
            }
          }
          rethrow;
        } finally {
          await releaseBoundResources([
            () async {
              if (!disposed) {
                await player?.dispose().timeout(const Duration(seconds: 10));
              }
            },
            () => mount(const SizedBox.shrink()),
            () async => server?.close(),
            () async {
              await directory.delete(recursive: true);
            },
          ], preserveFailure: caseFailed);
        }
      }
      // Prove a late framework failure cannot be hidden by already accepted raw rows.
      expect(plan['negativeFramework'], isNot(true));
    } catch (error) {
      failure = error.toString();
      rethrow;
    }
  });
}
