import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_cast/src/multicast.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.ylplayer.cast/multicast');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> calls;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('overlapping scan and session retain one native reference', () async {
    final lock = YlCastMulticastLock();
    await lock.acquire();
    await lock.acquire();
    await lock.release();
    expect(calls, ['acquire']);
    await lock.release();
    await lock.release();
    expect(calls, ['acquire', 'release']);
    await lock.dispose();
    expect(calls, ['acquire', 'release']);
  });

  test(
    'independent owners each retain and release a native reference',
    () async {
      final scan = YlCastMulticastLock();
      final session = YlCastMulticastLock();
      await scan.acquire();
      await session.acquire();
      await scan.dispose();
      await session.dispose();
      expect(calls, ['acquire', 'acquire', 'release', 'release']);
    },
  );

  test(
    'dispose releases all local references once and closes acquisition',
    () async {
      final lock = YlCastMulticastLock();
      await lock.acquire();
      await lock.acquire();
      await Future.wait([lock.dispose(), lock.dispose(), lock.release()]);
      expect(calls, ['acquire', 'release']);
      await expectLater(lock.acquire(), throwsStateError);
    },
  );

  test('release and dispose wait for an outstanding acquire', () async {
    final acquired = Completer<void>();
    final started = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'acquire') {
        started.complete();
        await acquired.future;
      }
      return null;
    });
    final lock = YlCastMulticastLock();
    final pendingAcquire = lock.acquire();
    await started.future;
    final pendingRelease = lock.release();
    final pendingDispose = lock.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['acquire']);
    acquired.complete();
    await Future.wait([pendingAcquire, pendingRelease, pendingDispose]);
    expect(calls, ['acquire', 'release']);
  });

  test(
    'failed acquire surfaces permission errors and can be retried',
    () async {
      var attempts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'acquire' && attempts++ == 0) {
          throw PlatformException(code: 'cast.multicast_permission');
        }
        return null;
      });
      final lock = YlCastMulticastLock();
      await expectLater(
        lock.acquire(),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'cast.multicast_permission',
          ),
        ),
      );
      await lock.acquire();
      await lock.release();
      expect(calls, ['acquire', 'acquire', 'release']);
      await lock.dispose();
    },
  );

  test(
    'failed release retains ownership so disposal retries cleanup',
    () async {
      var releases = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'release' && releases++ == 0) {
          throw PlatformException(code: 'cast.multicast_failed');
        }
        return null;
      });
      final lock = YlCastMulticastLock();
      await lock.acquire();
      await expectLater(lock.release(), throwsA(isA<PlatformException>()));
      await lock.dispose();
      expect(calls, ['acquire', 'release', 'release']);
    },
  );

  test('failed dispose can retry without reopening acquisition', () async {
    var releases = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'release' && releases++ == 0) {
        throw PlatformException(code: 'cast.multicast_failed');
      }
      return null;
    });
    final lock = YlCastMulticastLock();
    await lock.acquire();
    await expectLater(lock.dispose(), throwsA(isA<PlatformException>()));
    await expectLater(lock.acquire(), throwsStateError);
    await lock.dispose();
    await lock.dispose();
    expect(calls, ['acquire', 'release', 'release']);
  });

  test('non Android platforms never invoke a plugin channel', () async {
    for (final platform in TargetPlatform.values) {
      if (platform == TargetPlatform.android) continue;
      debugDefaultTargetPlatformOverride = platform;
      final lock = YlCastMulticastLock();
      await lock.acquire();
      await lock.acquire();
      await lock.release();
      await lock.dispose();
    }
    expect(calls, isEmpty);
  });
}
