import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/paused_frame_capture.dart';

void main() {
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
