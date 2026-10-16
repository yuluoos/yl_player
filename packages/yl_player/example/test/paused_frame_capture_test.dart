import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/paused_frame_capture.dart';

void main() {
  test(
    'stale completed public seek position cannot end a fresh native phase',
    () async {
      final clocks = <int?>[null, 500000, 700000];
      var captures = 0;
      await captureNativePhase(
        done: () => true,
        capture: () async => clocks[captures++],
        minimumNativeClockUs: 650000,
      );
      expect(captures, 3);
    },
  );
  test(
    'absent native consumption remains a bounded failure with stale public state',
    () async {
      await expectLater(
        captureNativePhase(
          done: () => true,
          capture: () async {
            await Future<void>.delayed(const Duration(milliseconds: 1));
            return null;
          },
          minimumNativeClockUs: 650000,
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(isA<TimeoutException>()),
      );
    },
  );

  test('acknowledged seek waits for its actual native audio reset', () async {
    var checks = 0;
    await waitForNativePhase(
      () async => ++checks >= 3,
      pollInterval: Duration.zero,
    );
    expect(checks, 3);
  });
  test('missing native phase remains a bounded failure', () async {
    await expectLater(
      waitForNativePhase(
        () async => false,
        timeout: const Duration(milliseconds: 10),
        pollInterval: const Duration(milliseconds: 1),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });
  test(
    'missing readback keeps playback paused until the surface is ready',
    () async {
      var paused = false;
      var reads = 0;
      var resumed = false;
      final value = await capturePausedFrame(
        readyToPause: () async => true,
        pause: () async {
          paused = true;
        },
        read: () async {
          expect(paused, isTrue);
          expect(resumed, isFalse);
          return ++reads < 3 ? null : 150000;
        },
        resume: () async {
          resumed = true;
        },
        pollInterval: Duration.zero,
      );
      expect(value, 150000);
      expect(resumed, isTrue);
    },
  );

  test(
    'unavailable surface fails without resuming beyond the marker',
    () async {
      var resumed = false;
      await expectLater(
        capturePausedFrame(
          readyToPause: () async => true,
          pause: () async {},
          read: () async => null,
          resume: () async {
            resumed = true;
          },
          timeout: const Duration(milliseconds: 10),
          pollInterval: const Duration(milliseconds: 1),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(resumed, isFalse);
    },
  );
  test(
    'waits for actual consumption readiness before pausing after seek',
    () async {
      var checks = 0;
      var ready = false;
      final value = await capturePausedFrame(
        readyToPause: () async {
          ready = ++checks >= 3;
          return ready;
        },
        pause: () async {
          expect(
            ready,
            isTrue,
            reason: 'Pausing an unstarted output prevents clock readiness',
          );
        },
        read: () async => 2250000,
        resume: () async {},
        pollInterval: Duration.zero,
      );
      expect(checks, 3);
      expect(value, 2250000);
    },
  );

  test(
    'readiness timeout leaves the output unpaused and does not read',
    () async {
      var paused = false;
      await expectLater(
        capturePausedFrame(
          readyToPause: () async => false,
          pause: () async {
            paused = true;
          },
          read: () async => 0,
          resume: () async {},
          timeout: const Duration(milliseconds: 10),
          pollInterval: const Duration(milliseconds: 1),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(paused, isFalse);
    },
  );
}
