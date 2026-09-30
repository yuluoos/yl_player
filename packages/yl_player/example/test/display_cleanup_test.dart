import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/display_cleanup.dart';

void main() {
  test('confirmed creation and all cleanup steps complete in order', () async {
    final cleanup = DisplayTrialCleanup();
    expect(
      await cleanup.create(
        Future.value(7),
        timeout: const Duration(seconds: 1),
        release: (_) async {},
      ),
      7,
    );
    final calls = <int>[];
    expect(
      await cleanup.run([
        () async => calls.add(0),
        () async => calls.add(1),
        () async => calls.add(2),
        () async => calls.add(3),
      ]),
      isTrue,
    );
    expect(calls, [0, 1, 2, 3]);
  });

  for (var failedStep = 0; failedStep < 4; failedStep++) {
    test('step $failedStep failure never skips independent cleanup', () async {
      final calls = <int>[];
      final cleaned = await DisplayTrialCleanup().run(
        List.generate(4, (step) {
          return () {
            calls.add(step);
            if (step == failedStep) throw StateError('cleanup failed');
            return Future<void>.value();
          };
        }),
      );
      expect(cleaned, isFalse);
      expect(calls, [0, 1, 2, 3]);
    });
  }

  test('hung disposal is bounded and later cleanup still executes', () async {
    final disposal = Completer<void>();
    final calls = <String>[];
    expect(
      await DisplayTrialCleanup().run([
        () => disposal.future,
        () async => calls.add('unmount'),
        () async => calls.add('inspect'),
        () async => calls.add('delete'),
      ], timeout: const Duration(milliseconds: 10)),
      isFalse,
    );
    expect(calls, ['unmount', 'inspect', 'delete']);
    // A late native failure must not escape after the timeout was handled.
    disposal.completeError(StateError('late disposal failure'));
    await Future<void>.delayed(Duration.zero);
  });

  test(
    'creation timeout cannot claim cleanup while late release is pending',
    () async {
      final cleanup = DisplayTrialCleanup();
      final creation = Completer<int>();
      final releaseStarted = Completer<void>();
      final releaseDone = Completer<void>();
      var releases = 0;
      await expectLater(
        cleanup.create(
          creation.future,
          timeout: const Duration(milliseconds: 10),
          release: (_) {
            releases++;
            releaseStarted.complete();
            return releaseDone.future;
          },
        ),
        throwsA(isA<TimeoutException>()),
      );
      final calls = <String>[];
      expect(
        await cleanup.run([
          () async => calls.add('unmount'),
          () async => calls.add('inspect'),
          () async => calls.add('delete'),
        ]),
        isFalse,
      );
      expect(calls, ['unmount', 'inspect', 'delete']);
      creation.complete(7);
      await releaseStarted.future;
      expect(await cleanup.run([]), isFalse);
      releaseDone.complete();
      await Future<void>.delayed(Duration.zero);
      expect(releases, 1);
      // A late completion never retroactively upgrades the recorded trial.
      expect(await cleanup.run([]), isFalse);
    },
  );
}
