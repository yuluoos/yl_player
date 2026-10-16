import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_android/src/live_mode_barrier.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  const low = YlLivePlaybackMode.lowLatency;
  const smooth = YlLivePlaybackMode.smoothPlayback;
  for (final replyFirst in [true, false]) {
    test('pairs exact request and revision, replyFirst=$replyFirst', () async {
      final barrier = LiveModeBarrier();
      final request = barrier.begin('s1', low, 4);
      var done = false;
      final future = request.future.then((_) => done = true);
      void reply() => barrier.reply(request.id, 's1', request.id, 5);
      void snapshot() => barrier.snapshot('s1', request.id, 5, low);
      if (replyFirst) {
        reply();
      } else {
        snapshot();
      }
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      if (replyFirst) {
        snapshot();
      } else {
        reply();
      }
      await future;
      expect(barrier.pendingCount, 0);
    });
  }
  test('historical commits survive a later opposite mode', () async {
    final b = LiveModeBarrier();
    final a = b.begin('s1', low, 4), c = b.begin('s1', smooth, 4);
    b.snapshot('s1', a.id, 5, low);
    b.snapshot('s1', c.id, 6, smooth);
    b.reply(c.id, 's1', c.id, 6);
    b.reply(a.id, 's1', a.id, 5);
    await Future.wait([a.future, c.future]);
  });
  test(
    'wrong mode, request or revision cannot acknowledge a command',
    () async {
      for (final invalid in ['mode', 'request', 'revision', 'session']) {
        final b = LiveModeBarrier();
        final a = b.begin('s1', low, 4);
        final failure = expectLater(
          a.future,
          throwsA(isA<YlPlayerException>()),
        );
        b.snapshot('s1', a.id, 5, invalid == 'mode' ? smooth : low);
        b.reply(
          a.id,
          invalid == 'session' ? 'other' : 's1',
          invalid == 'request' ? a.id + 1 : a.id,
          invalid == 'revision' ? 4 : 5,
        );
        await failure;
      }
    },
  );
  test(
    '32 pending admission and immediate cancellation; IDs never reused',
    () async {
      final b = LiveModeBarrier();
      final requests = List.generate(32, (_) => b.begin('s1', low, 4));
      final failures = requests
          .map((r) => expectLater(r.future, throwsA(isA<YlPlayerException>())))
          .toList();
      expect(
        () => b.begin('s1', low, 4),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.resourceExhausted,
          ),
        ),
      );
      b.cancelAll();
      await Future.wait(failures);
      expect(b.pendingCount, 0);
      final next = b.begin('s2', low, 9);
      expect(next.id, 33);
      b.snapshot('s1', 1, 5, low);
      b.reply(1, 's1', 1, 5);
      b.snapshot('s2', next.id, 10, low);
      b.reply(next.id, 's2', next.id, 10);
      await next.future;
    },
  );
  test(
    'command errors settle independently and missing snapshot times out',
    () async {
      final b = LiveModeBarrier(deadline: const Duration(milliseconds: 10));
      final a = b.begin('s1', low, 4), c = b.begin('s1', smooth, 4);
      final one = expectLater(a.future, throwsA(isA<StateError>()));
      final two = expectLater(c.future, throwsA(isA<YlPlayerException>()));
      b.fail(a.id, StateError('injected'));
      b.reply(c.id, 's1', c.id, 5);
      await Future.wait([one, two]);
      expect(b.pendingCount, 0);
    },
  );
}
