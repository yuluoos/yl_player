import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/player_controller.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'support/fake_player_platform.dart';

const s1 = YlPlaybackSessionId('s1');
const s2 = YlPlaybackSessionId('s2');
final source = YlNetworkSource(Uri.parse('https://example.test/a.mp4'));
const failure = YlPlayerException(
  YlFailure(
    category: YlFailureCategory.decoder,
    code: YlFailureCodes.decoderUnavailable,
    message: 'Unavailable.',
    retryable: false,
    scope: YlFailureScope.session,
    diagnosticId: 'test',
  ),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakePlatformPlayer backend;
  late YlPlayerController player;
  setUp(() async {
    backend = FakePlatformPlayer();
    player = await YlPlayerController.create(
      platform: FakePlayerPlatform(backend),
    );
  });
  tearDown(() async {
    await player.dispose();
  });
  test('paused app observer cannot delay public dispose completion', () async {
    final observer = player.states.listen((_) {});
    observer.pause();
    try {
      await player.dispose().timeout(const Duration(milliseconds: 100));
      expect(backend.disposeCount, 1);
    } finally {
      await observer.cancel();
      await player.dispose();
    }
  });
  for (final close in [false, true]) {
    test(
      'transport ${close ? 'close' : 'error'} settles committed loading milestones without playback failure',
      () async {
        final loading = player.load(source);
        backend.commit(s1);
        final session = await loading;
        final before = player.state;
        final states = <YlPlayerState>[];
        final events = <YlPlayerEvent>[];
        player.states.listen(states.add);
        player.events.listen(events.add);
        final ready = expectLater(
          session.ready.timeout(const Duration(milliseconds: 300)),
          throwsA(isA<YlPlayerException>()),
        );
        final frame = expectLater(
          session.firstFrame.timeout(const Duration(milliseconds: 300)),
          throwsA(isA<YlPlayerException>()),
        );
        if (close) {
          await backend.stateController.close();
        } else {
          backend.eventController.addError(
            StateError('private native details'),
          );
        }
        await Future.wait([ready, frame]);
        await player.dispose();
        expect(player.state, before);
        expect(states, isEmpty);
        expect(events, isEmpty);
        expect(player.textureId.value, isNull);
        expect(backend.disposeCount, 1);
        await expectLater(session.play(), throwsA(isA<YlPlayerException>()));
      },
    );
  }
  test(
    'commit, Ready and First Frame are separate; replacement makes old commands stale',
    () async {
      final loading = player.load(source);
      backend.commit(s1);
      final first = await loading;
      var ready = false;
      var frame = false;
      first.ready.then((_) => ready = true);
      first.firstFrame.then((_) => frame = true);
      backend.emit(status: YlPlaybackStatus.buffering);
      await Future<void>.delayed(Duration.zero);
      expect(ready, isFalse);
      backend.emit(status: YlPlaybackStatus.ready);
      await first.ready;
      expect(frame, isFalse);
      backend.emitFirstFrame(s1);
      await first.firstFrame;
      await first.play();
      expect(backend.lastCommand, ('play', s1));
      final next = player.load(source);
      backend.commit(s2);
      final second = await next;
      final count = backend.calls.length;
      await expectLater(
        first.pause(),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.sessionStale,
          ),
        ),
      );
      expect(backend.calls.length, count);
      expect(second.id, s2);
    },
  );
  test(
    'early milestones and older same-session event revision survive load reply gap',
    () async {
      final loading = player.load(source);
      backend.commit(s1, reply: false);
      backend.emit(status: YlPlaybackStatus.ready);
      final revision = backend.state.revision;
      backend.emit(status: YlPlaybackStatus.paused);
      backend.emitFirstFrame(s1, revision: revision);
      backend.loads.single.complete(const YlPlatformLoadResult(sessionId: s1));
      final session = await loading;
      await session.ready;
      await session.firstFrame;
    },
  );
  test(
    'new Load promptly cancels older unresolved caller; late result cannot replace',
    () async {
      final first = player.load(source);
      final rejection = expectLater(
        first,
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.loadCancelled,
          ),
        ),
      );
      final next = player.load(source);
      await rejection;
      backend.commit(s2, index: 1);
      final session = await next;
      backend.loads.first.complete(const YlPlatformLoadResult(sessionId: s1));
      await session.play();
      expect(player.state.sessionId, s2);
    },
  );
  test(
    'precommit failure preserves old pending Ready and command authority',
    () async {
      final loading = player.load(source);
      backend.commit(s1);
      final old = await loading;
      final next = player.load(source);
      backend.loads.last.completeError(failure);
      await expectLater(next, throwsA(same(failure)));
      await old.play();
      backend.emit(status: YlPlaybackStatus.ready);
      await old.ready;
    },
  );
  test(
    'postcommit native failure completes pending milestones once; command failure changes nothing',
    () async {
      final loading = player.load(source);
      backend.commit(s1);
      final session = await loading;
      final states = <YlPlayerState>[];
      final events = <YlPlayerEvent>[];
      player.states.listen(states.add);
      player.events.listen(events.add);
      backend.commandError = failure;
      await expectLater(session.play(), throwsA(same(failure)));
      expect(states, isEmpty);
      expect(events, isEmpty);
      final readyError = expectLater(
        session.ready,
        throwsA(isA<YlPlayerException>()),
      );
      final frameError = expectLater(
        session.firstFrame,
        throwsA(isA<YlPlayerException>()),
      );
      backend.emit(status: YlPlaybackStatus.failed, failure: failure.failure);
      backend.emitEvent(
        YlPlaybackFailedEvent(
          sessionId: s1,
          revision: backend.state.revision,
          occurredAt: Duration.zero,
          failure: failure.failure,
        ),
      );
      await readyError;
      await frameError;
      expect(states, hasLength(1));
      expect(events, hasLength(1));
    },
  );
  test('stop invalidates milestones and rejects old handle locally', () async {
    final loading = player.load(source);
    backend.commit(s1);
    final session = await loading;
    await player.stop();
    await expectLater(session.play(), throwsA(isA<YlPlayerException>()));
    await expectLater(session.ready, throwsA(isA<YlPlayerException>()));
  });
  test(
    'successful Stop invalidates commands before delayed idle delivery',
    () async {
      final loading = player.load(source);
      backend.commit(s1);
      final session = await loading;
      backend.emitIdleOnStop = false;
      await player.stop();
      final count = backend.calls.length;
      await expectLater(
        session.play(),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.sessionStale,
          ),
        ),
      );
      expect(backend.calls.length, count);
      expect(player.state.sessionId, s1);
    },
  );
  test(
    'rejected Stop preserves healthy handle and pending milestones',
    () async {
      final loading = player.load(source);
      backend.commit(s1);
      final session = await loading;
      backend.stopError = failure;
      await expectLater(player.stop(), throwsA(same(failure)));
      await session.play();
      backend.emit(status: YlPlaybackStatus.ready);
      await session.ready;
      expect(player.state.sessionId, s1);
    },
  );
  test(
    'successful Stop ignores late events before idle and late reply cannot invalidate newer session',
    () async {
      final loading = player.load(source);
      backend.commit(s1);
      await loading;
      backend.emitIdleOnStop = false;
      await player.stop();
      final events = <YlPlayerEvent>[];
      final subscription = player.events.listen(events.add);
      backend.emitFirstFrame(s1);
      expect(events, isEmpty);
      await subscription.cancel();

      final secondLoad = player.load(source);
      backend.commit(s2);
      final second = await secondLoad;
      backend.stopReply = Completer<void>();
      final stopping = player.stop();
      final newerLoad = player.load(source);
      const s3 = YlPlaybackSessionId('s3');
      backend.commit(s3);
      final newer = await newerLoad;
      backend.stopReply!.complete();
      await stopping;
      backend.emit(status: YlPlaybackStatus.ready);
      await newer.ready.timeout(const Duration(seconds: 1));
      await newer.play();
      await expectLater(second.play(), throwsA(isA<YlPlayerException>()));
    },
  );
  test('unused milestone failures produce no uncaught zone errors', () async {
    final errors = <Object>[];
    await runZonedGuarded(() async {
      final b = FakePlatformPlayer();
      final p = await YlPlayerController.create(
        platform: FakePlayerPlatform(b),
      );
      final load = p.load(source);
      b.commit(s1);
      await load;
      b.emit(status: YlPlaybackStatus.failed, failure: failure.failure);
      await Future<void>.delayed(Duration.zero);
      await p.dispose();
    }, (error, _) => errors.add(error));
    expect(errors, isEmpty);
  });
}
