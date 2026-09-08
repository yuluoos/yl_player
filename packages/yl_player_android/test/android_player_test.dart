import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_android/src/pigeon/yl_player_android.g.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'support/android_fakes.dart';

Matcher failsWith(String code) => throwsA(
  isA<YlPlayerException>().having((e) => e.failure.code, 'code', code),
);
void main() {
  test('completion-window deltas use the latest authoritative state', () async {
    final t = FakeTransport();
    final p = await createFake(t);
    addTearDown(p.dispose);
    var injected = false, completed = false;
    final revisions = <int>[];
    final subscription = p.states.listen((state) {
      revisions.add(state.revision);
      if (injected) return;
      injected = true;
      expect(completed, isFalse);
      t.callbacks!.onState(wireState(session: 's1', revision: 5, sequence: 11));
      t.callbacks!.onStateDelta(
        wireDelta(previous: 5, revision: 6, sequence: 12),
      );
      t.callbacks!.onStateDelta(
        wireDelta(previous: 6, revision: 7, sequence: 13),
      );
    });
    addTearDown(subscription.cancel);
    final loading = p.load(source).then((result) {
      completed = true;
      return result;
    });
    await flush();
    t.callbacks!.onState(wireState(session: 's1', revision: 4, sequence: 10));
    t.loads.single.complete(
      AndroidLoadReply(loadRequestId: 'load-1', sessionId: 's1'),
    );
    await loading;
    expect(p.state.revision, 7);
    expect(p.state.timeline.position.inMilliseconds, 50);
    expect(revisions, [4, 5, 6, 7]);
  });

  for (final asEvent in [false, true]) {
    for (final duringAssessment in [false, true]) {
      test(
        'former session failure notifies A without cancelling B: event=$asEvent assessment=$duringAssessment',
        () async {
          final t = FakeTransport();
          final p = await createFake(t);
          addTearDown(p.dispose);
          await commit(t, p);
          final states = <YlPlayerState>[], events = <YlPlayerEvent>[];
          final stateSubscription = p.states.listen(states.add),
              eventSubscription = p.events.listen(events.add);
          addTearDown(stateSubscription.cancel);
          addTearDown(eventSubscription.cancel);
          final assessment = Completer<AndroidAssessmentReply>();
          if (duringAssessment) t.assessment = () => assessment.future;
          Object? failure;
          final loading = p
              .load(source)
              .then<YlPlatformLoadResult?>(
                (result) => result,
                onError: (Object error) {
                  failure = error;
                  return null;
                },
              );
          await flush();
          if (!duringAssessment) {
            t.callbacks!.onState(
              wireState(session: 's2', revision: 6, sequence: 12),
            );
          }
          if (asEvent) {
            t.callbacks!.onPlaybackFailed(
              AndroidPlaybackFailedMessage(
                sessionId: 's1',
                revision: 5,
                sequence: 11,
                occurredAtMs: 1,
                failure: wireFailure(),
              ),
            );
          } else {
            t.callbacks!.onState(
              wireState(
                session: 's1',
                revision: 5,
                sequence: 11,
                status: AndroidPlaybackStatus.failed,
              )..failure = wireFailure(),
            );
          }
          await flush();
          if (asEvent) {
            expect(
              events.whereType<YlPlaybackFailedEvent>().single.sessionId.value,
              's1',
            );
          } else {
            expect(states.single.sessionId!.value, 's1');
            expect(states.single.failure!.code, YlFailureCodes.networkFailed);
          }
          expect(failure, isNull);
          if (duringAssessment) {
            assessment.complete(
              AndroidAssessmentReply(
                outcome: AndroidAssessmentOutcome.compatible,
                satisfiedRequirements: [],
                limitations: [],
              ),
            );
            await flush();
            t.callbacks!.onState(
              wireState(session: 's2', revision: 6, sequence: 12),
            );
          }
          t.loads.last.complete(
            AndroidLoadReply(loadRequestId: 'load-2', sessionId: 's2'),
          );
          expect((await loading)!.sessionId.value, 's2');
          expect(p.state.sessionId!.value, 's2');
        },
      );
    }
    test(
      'player-scoped retained-session failure still terminates B: event=$asEvent',
      () async {
        final t = FakeTransport();
        final p = await createFake(t);
        addTearDown(p.dispose);
        await commit(t, p);
        t.assessment = () => Completer<AndroidAssessmentReply>().future;
        final loading = p.load(source);
        final failure = expectLater(
          loading,
          failsWith(YlFailureCodes.networkFailed),
        );
        await flush();
        if (asEvent) {
          t.callbacks!.onPlaybackFailed(
            AndroidPlaybackFailedMessage(
              sessionId: 's1',
              revision: 5,
              sequence: 11,
              occurredAtMs: 1,
              failure: wireFailure(scope: AndroidFailureScope.player),
            ),
          );
        } else {
          t.callbacks!.onState(
            wireState(
              session: 's1',
              revision: 5,
              sequence: 11,
              status: AndroidPlaybackStatus.failed,
            )..failure = wireFailure(scope: AndroidFailureScope.player),
          );
        }
        await failure;
        expect(p.state.failure!.scope, YlFailureScope.player);
      },
    );
  }

  test(
    'state-first Load preserves onState then first-frame then delta before reply',
    () async {
      final t = FakeTransport();
      final p = await createFake(t);
      final events = <YlPlayerEvent>[];
      final sub = p.events.listen(events.add);
      final loading = p.load(source);
      await flush();
      t.callbacks!.onState(wireState(session: 's1', revision: 4, sequence: 10));
      t.callbacks!.onFirstFrame(wireFrame(sequence: 11));
      t.callbacks!.onStateDelta(wireDelta(sequence: 12));
      t.loads.single.complete(
        AndroidLoadReply(loadRequestId: 'load-1', sessionId: 's1'),
      );
      await loading;
      await flush();
      expect(p.state.revision, 5);
      expect(p.state.timeline.position.inMilliseconds, 50);
      expect(events.whereType<YlFirstFrameEvent>(), hasLength(1));
      await sub.cancel();
      await p.dispose();
    },
  );
  test(
    'failed candidate state cancels barrier immediately before reply while retaining former state',
    () async {
      final t = FakeTransport();
      final p = await createFake(t);
      await commit(t, p);
      var completed = false;
      final loading = p
          .load(source)
          .then(
            (_) {
              completed = true;
            },
            onError: (Object e) {
              expect(
                e,
                isA<YlPlayerException>().having(
                  (v) => v.failure.code,
                  'code',
                  YlFailureCodes.networkFailed,
                ),
              );
              completed = true;
            },
          );
      await flush();
      t.callbacks!.onState(
        wireState(
          session: 's2',
          revision: 5,
          sequence: 11,
          status: AndroidPlaybackStatus.failed,
        )..failure = wireFailure(),
      );
      await flush();
      expect(completed, isTrue);
      expect(p.state.sessionId!.value, 's1');
      t.loads.last.complete(
        AndroidLoadReply(loadRequestId: 'load-2', sessionId: 's2'),
      );
      await loading;
      await flush();
      await p.dispose();
    },
  );
  test(
    'state-first READY evidence survives later BUFFERING before reply',
    () async {
      final t = FakeTransport();
      final p = await createFake(t);
      final loading = p.load(source);
      await flush();
      t.callbacks!.onState(
        wireState(
          session: 's1',
          revision: 1,
          sequence: 1,
          status: AndroidPlaybackStatus.ready,
        ),
      );
      t.callbacks!.onState(
        wireState(
          session: 's1',
          revision: 2,
          sequence: 2,
          status: AndroidPlaybackStatus.buffering,
        ),
      );
      t.loads.single.complete(
        AndroidLoadReply(loadRequestId: 'load-1', sessionId: 's1'),
      );
      await loading;
      expect(p.state.status, YlPlaybackStatus.buffering);
      await p.dispose();
    },
  );
  testWidgets('unknown stale A state cannot start newer B pair deadline', (
    tester,
  ) async {
    final t = FakeTransport();
    final p = await createFake(t);
    final old = p.load(source);
    final cancelled = expectLater(old, failsWith(YlFailureCodes.loadCancelled));
    await tester.pump();
    final next = p.load(source);
    await cancelled;
    await tester.pump();
    t.callbacks!.onState(wireState(session: 's1', revision: 1, sequence: 1));
    await tester.pump(const Duration(seconds: 6));
    expect(t.calls, isNot(contains('dispose')));
    t.callbacks!.onState(wireState(session: 's2', revision: 2, sequence: 2));
    t.loads[1].complete(
      AndroidLoadReply(loadRequestId: 'load-2', sessionId: 's2'),
    );
    await tester.pump();
    // Elapse the owned publication timer after reply microtasks have run.
    await tester.pump(Duration.zero);
    expect((await next).sessionId.value, 's2');
    t.loads[0].complete(
      AndroidLoadReply(loadRequestId: 'load-1', sessionId: 's1'),
    );
    await tester.pump();
    await p.dispose();
  });
  test(
    'unknown stale A failed state and event cannot cancel newer B',
    () async {
      final t = FakeTransport();
      final p = await createFake(t);
      final old = p.load(source);
      final cancelled = expectLater(
        old,
        failsWith(YlFailureCodes.loadCancelled),
      );
      await flush();
      var failed = false;
      final next = p
          .load(source)
          .then<YlPlatformLoadResult?>(
            (v) => v,
            onError: (Object _) {
              failed = true;
              return null;
            },
          );
      await cancelled;
      await flush();
      t.callbacks!.onState(
        wireState(
          session: 's1',
          revision: 1,
          sequence: 1,
          status: AndroidPlaybackStatus.failed,
        )..failure = wireFailure(),
      );
      t.callbacks!.onPlaybackFailed(
        AndroidPlaybackFailedMessage(
          sessionId: 's1',
          revision: 1,
          sequence: 2,
          occurredAtMs: 1,
          failure: wireFailure(),
        ),
      );
      await flush();
      expect(failed, isFalse);
      t.callbacks!.onState(wireState(session: 's2', revision: 2, sequence: 3));
      t.loads[1].complete(
        AndroidLoadReply(loadRequestId: 'load-2', sessionId: 's2'),
      );
      expect((await next)!.sessionId.value, 's2');
      t.loads[0].complete(
        AndroidLoadReply(loadRequestId: 'load-1', sessionId: 's1'),
      );
      await flush();
      await p.dispose();
    },
  );
  test(
    'late errors from cancelled assessment and Load do not terminate the newer session',
    () async {
      for (final inAssessment in [true, false]) {
        final t = FakeTransport();
        final p = await createFake(t);
        final oldAssessment = Completer<AndroidAssessmentReply>();
        if (inAssessment) t.assessment = () => oldAssessment.future;
        final old = p.load(source);
        final cancelled = expectLater(
          old,
          failsWith(YlFailureCodes.loadCancelled),
        );
        await flush();
        t.assessment = null;
        final next = p.load(source);
        await cancelled;
        await flush();
        t.loads.last.complete(
          AndroidLoadReply(loadRequestId: 'load-2', sessionId: 's2'),
        );
        t.callbacks!.onState(
          wireState(session: 's2', revision: 2, sequence: 2),
        );
        final result = await next;
        if (inAssessment) {
          oldAssessment.completeError(StateError('late secret'));
        } else {
          t.loads.first.completeError(StateError('late secret'));
        }
        await flush();
        expect(p.state.failure, isNull);
        await p.play(result.sessionId);
        await p.dispose();
      }
    },
  );
  test(
    'stale buffered full state failure cannot cancel matching Load',
    () async {
      final t = FakeTransport();
      final p = await createFake(t);
      var failed = false;
      final loading = p
          .load(source)
          .then<YlPlatformLoadResult?>(
            (v) => v,
            onError: (Object _) {
              failed = true;
              return null;
            },
          );
      await flush();
      t.callbacks!.onState(wireState(session: 's1', revision: 8, sequence: 20));
      t.callbacks!.onState(
        wireState(
          session: 's1',
          revision: 7,
          sequence: 21,
          status: AndroidPlaybackStatus.failed,
        )..failure = wireFailure(),
      );
      await flush();
      expect(failed, isFalse);
      t.loads.single.complete(
        AndroidLoadReply(loadRequestId: 'load-1', sessionId: 's1'),
      );
      await loading;
      expect(p.state.revision, 8);
      await p.dispose();
    },
  );
  test(
    'stale duplicate delta payload cannot count as structurally invalid',
    () async {
      final t = FakeTransport();
      final p = await createFake(t);
      await commit(t, p);
      for (var i = 0; i < 3; i++) {
        t.callbacks!.onStateDelta(wireDelta(sequence: 9)..positionMs = -1);
      }
      await flush();
      expect(p.state.failure, isNull);
      await p.dispose();
    },
  );
  test('mismatched echoed request cannot pair or revive a Load', () async {
    final t = FakeTransport();
    final p = await createFake(t);
    final loading = p.load(source);
    final failure = expectLater(
      loading,
      failsWith(YlFailureCodes.protocolMismatch),
    );
    await flush();
    expect(t.requests.single.loadRequestId, 'load-1');
    t.callbacks!.onState(wireState(session: 's1', revision: 1, sequence: 1));
    t.loads.single.complete(
      AndroidLoadReply(loadRequestId: 'load-2', sessionId: 's1'),
    );
    await failure;
    expect(p.state.failure!.scope, YlFailureScope.player);
    await p.dispose();
  });
  test(
    'known-session retry and engine events map independently from state watermark',
    () async {
      final t = FakeTransport();
      final p = await createFake(t);
      await commit(t, p);
      final events = <YlPlayerEvent>[];
      final sub = p.events.listen(events.add);
      t.callbacks!.onState(wireState(session: 's1', revision: 8, sequence: 20));
      t.callbacks!.onRetryScheduled(
        AndroidRetryScheduledMessage(
          sessionId: 's1',
          revision: 5,
          sequence: 12,
          occurredAtMs: 123,
          retryIndex: 2,
          delayMs: 400,
          failure: wireFailure(),
        ),
      );
      t.callbacks!.onEngineChanged(
        AndroidEngineChangedMessage(
          sessionId: 's1',
          revision: 6,
          sequence: 13,
          occurredAtMs: 124,
          previousEngine: AndroidEngine.unknown,
          engine: AndroidEngine.media3,
        ),
      );
      await flush();
      final retry = events[0] as YlRetryScheduledEvent,
          engine = events[1] as YlPlaybackEngineChangedEvent;
      expect(retry.delay, const Duration(milliseconds: 400));
      expect(retry.retryIndex, 2);
      expect(retry.occurredAt, const Duration(milliseconds: 123));
      expect(engine.previousEngine, YlPlaybackEngine.unknown);
      expect(engine.engine, YlPlaybackEngine.media3);
      await sub.cancel();
      await p.dispose();
    },
  );
  for (final atMaximum in [false, true]) {
    test(
      'terminal transport reaches revision-filtering consumers before hung native cleanup; max=$atMaximum',
      () async {
        final t = FakeTransport();
        final p = await createFake(t);
        final loading = p.load(source);
        await flush();
        final revision = atMaximum ? 0x7fffffffffffffff : 4;
        t.callbacks!.onState(
          wireState(session: 's1', revision: revision, sequence: 10),
        );
        t.loads.single.complete(
          AndroidLoadReply(loadRequestId: 'load-1', sessionId: 's1'),
        );
        await flush();
        final loaded = await loading;
        var accepted = false, done = false;
        // Mirrors YlPlayerController._acceptState's public SPI revision filter.
        final states = p.states.listen(
          (next) {
            if (next.revision > revision) {
              accepted = next.failure?.scope == YlFailureScope.player;
            }
          },
          onDone: () {
            done = true;
          },
        );
        final release = Completer<void>();
        t.disposing = () => release.future;
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await p.dispose();
          await states.cancel();
        });
        t.playing = () =>
            Future.error(PlatformException(code: 'channel-error'));
        final error = expectLater(
          p.play(loaded.sessionId),
          failsWith(YlFailureCodes.platformUnavailable),
        );
        await flush();
        await error;
        expect(atMaximum ? done : accepted, isTrue);
        validateYlPlayerState(p.state);
        expect(p.state.revision, atMaximum ? revision : revision + 1);
        release.complete();
        await flush();
        await p.dispose();
        await states.cancel();
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );
  }
  test(
    'creation owns native identity before validation; attaches after callback setup',
    () async {
      final t = FakeTransport();
      t.attaching = () async {
        expect(t.callbacks, isNotNull);
      };
      final p = await createFake(t);
      expect(
        p.implementation,
        const YlPlatformImplementationInfo(
          name: 'yl_player_android',
          version: '0.2.0-dev.1',
          spiMajor: 2,
        ),
      );
      expect(p.textureId.value, 42);
      await p.dispose();
      expect(t.callbacks, isNull);
      for (final reply in [
        wireCreate()..schemaMajor = 1,
        wireCreate()..spiMajor = 1,
        wireCreate()..textureId = -1,
        wireCreate()..initialState.revision = -1,
        wireCreate()..capabilities.maxWidth = -1,
      ]) {
        final bad = FakeTransport();
        await expectLater(
          createFake(bad, reply: reply),
          failsWith(YlFailureCodes.protocolMismatch),
        );
        expect(bad.calls, ['dispose']);
        expect(bad.callbacks, isNull);
      }
    },
  );
  test(
    'callback setup and attach failures clean native ownership and preserve safe error',
    () async {
      final setupFailure = FakeTransport();
      await expectLater(
        createFake(
          setupFailure,
          setup: (api) {
            if (api != null) throw StateError('secret');
          },
        ),
        failsWith(YlFailureCodes.platformFailure),
      );
      expect(setupFailure.calls, ['dispose']);
      expect(setupFailure.callbacks, isNull);
      final attachFailure = FakeTransport()
        ..attaching = () => Future.error(
          PlatformException(code: 'channel-error', message: 'secret'),
        );
      await expectLater(
        createFake(attachFailure),
        failsWith(YlFailureCodes.platformUnavailable),
      );
      expect(attachFailure.calls, ['attach', 'dispose']);
      expect(attachFailure.callbacks, isNull);
    },
  );
  for (final stateFirst in [false, true]) {
    test(
      'Load pairs both halves before immediate Play; stateFirst=$stateFirst',
      () async {
        final t = FakeTransport();
        final p = await createFake(t);
        var complete = false;
        final loading = p.load(source).then((v) {
          complete = true;
          return v;
        });
        await flush();
        if (stateFirst) {
          t.callbacks!.onState(
            wireState(session: 's1', revision: 1, sequence: 1),
          );
        } else {
          t.loads.single.complete(
            AndroidLoadReply(loadRequestId: 'load-1', sessionId: 's1'),
          );
        }
        await flush();
        expect(complete, isFalse);
        if (stateFirst) {
          t.loads.single.complete(
            AndroidLoadReply(loadRequestId: 'load-1', sessionId: 's1'),
          );
        } else {
          t.callbacks!.onState(
            wireState(session: 's1', revision: 1, sequence: 1),
          );
        }
        final result = await loading;
        expect(p.state.sessionId, result.sessionId);
        expect(p.state.status, YlPlaybackStatus.loading);
        await p.play(result.sessionId);
        expect(t.calls.last, 'play:s1');
        await p.dispose();
      },
    );
    testWidgets(
      'five-second pair deadline starts at either half; stateFirst=$stateFirst',
      (tester) async {
        final t = FakeTransport();
        final p = await createFake(t);
        final loading = p.load(source);
        final failure = expectLater(
          loading,
          failsWith(YlFailureCodes.protocolMismatch),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 20));
        expect(t.calls, isNot(contains('dispose')));
        if (stateFirst) {
          t.callbacks!.onState(
            wireState(session: 's1', revision: 1, sequence: 1),
          );
        } else {
          t.loads.single.complete(
            AndroidLoadReply(loadRequestId: 'load-1', sessionId: 's1'),
          );
        }
        await tester.pump();
        await tester.pump(const Duration(seconds: 5));
        await failure;
        expect(p.state.failure!.code, YlFailureCodes.protocolMismatch);
        expect(t.calls.where((v) => v == 'dispose'), hasLength(1));
        t.loads.single.isCompleted
            ? null
            : t.loads.single.completeError(StateError('late native secret'));
        await tester.pump();
        await p.dispose();
      },
    );
  }
  test(
    'state/delta ordering ignores stale callbacks and milestones survive newer state revisions',
    () async {
      final t = FakeTransport();
      final p = await createFake(t);
      await commit(t, p);
      final api = t.callbacks!;
      final events = <YlPlayerEvent>[];
      final sub = p.events.listen(events.add);
      api.onStateDelta(wireDelta());
      expect(p.state.revision, 5);
      expect(p.state.timeline.position.inMilliseconds, 50);
      api.onStateDelta(wireDelta()..positionMs = 999);
      expect(p.state.timeline.position.inMilliseconds, 50);
      api.onStateDelta(wireDelta(session: 's0', revision: 6, sequence: 12));
      api.onStateDelta(wireDelta(previous: 3, revision: 6, sequence: 13));
      expect(p.state.revision, 5);
      api.onState(wireState(session: 's1', revision: 8, sequence: 20));
      api.onState(wireState(session: 's1', revision: 7, sequence: 21));
      expect(p.state.revision, 8);
      api.onFirstFrame(wireFrame());
      api.onFirstFrame(wireFrame());
      final failure = AndroidPlaybackFailedMessage(
        sessionId: 's1',
        revision: 6,
        sequence: 14,
        occurredAtMs: 100,
        failure: wireFailure(),
      );
      api.onPlaybackFailed(failure);
      api.onPlaybackFailed(failure);
      await flush();
      expect(events.whereType<YlFirstFrameEvent>(), hasLength(1));
      expect(events.whereType<YlPlaybackFailedEvent>(), hasLength(1));
      expect(p.state.failure, isNull);
      await sub.cancel();
      await p.dispose();
    },
  );
  test(
    'loading BUFFERING stays loading until READY evidence; injected callbacks are isolated',
    () async {
      final t = FakeTransport(), other = FakeTransport();
      final p = await createFake(t),
          p2 = await createFake(other, reply: wireCreate(suffix: 'instance-2'));
      await commit(t, p);
      final api = t.callbacks!;
      api.onState(
        wireState(
          session: 's1',
          revision: 5,
          sequence: 11,
          status: AndroidPlaybackStatus.buffering,
        ),
      );
      expect(p.state.status, YlPlaybackStatus.loading);
      expect(p2.state.status, YlPlaybackStatus.idle);
      api.onState(
        wireState(
          session: 's1',
          revision: 6,
          sequence: 12,
          status: AndroidPlaybackStatus.ready,
        ),
      );
      expect(p.state.status, YlPlaybackStatus.ready);
      api.onState(
        wireState(
          session: 's1',
          revision: 7,
          sequence: 13,
          status: AndroidPlaybackStatus.buffering,
        ),
      );
      expect(p.state.status, YlPlaybackStatus.buffering);
      await p.dispose();
      await p2.dispose();
    },
  );
  test(
    'only repeated malformed callbacks terminate; stale traffic never increments failures',
    () async {
      final t = FakeTransport();
      final p = await createFake(t);
      await commit(t, p);
      final api = t.callbacks!;
      for (var i = 0; i < 10; i++) {
        api.onState(wireState(session: 's1', revision: 3, sequence: 11));
      }
      api.onState(wireState(session: 's1', revision: -1, sequence: 11));
      expect(p.state.failure, isNull);
      api.onStateDelta(wireDelta()..sequence = -1);
      expect(p.state.failure, isNull);
      api.onState(
        wireState(session: 's1', revision: 5, sequence: 12)
          ..timeline.positionMs = -1,
      );
      await flush();
      expect(p.state.failure!.code, YlFailureCodes.protocolMismatch);
      expect(t.callbacks, isNull);
      await p.dispose();
    },
  );
  test(
    'new Load cancels assessment and old pair continuations without reopening',
    () async {
      final t = FakeTransport();
      final p = await createFake(t);
      final assessment = Completer<AndroidAssessmentReply>();
      t.assessment = () => assessment.future;
      final old = p.load(source);
      final oldError = expectLater(
        old,
        failsWith(YlFailureCodes.loadCancelled),
      );
      t.assessment = null;
      final next = p.load(source);
      await oldError;
      await flush();
      assessment.complete(
        AndroidAssessmentReply(
          outcome: AndroidAssessmentOutcome.compatible,
          satisfiedRequirements: [],
          limitations: [],
        ),
      );
      await flush();
      expect(t.loads, hasLength(1));
      t.loads.single.complete(
        AndroidLoadReply(loadRequestId: 'load-2', sessionId: 's2'),
      );
      t.callbacks!.onState(wireState(session: 's2', revision: 1, sequence: 1));
      expect((await next).sessionId.value, 's2');
      await p.dispose();
    },
  );
  test(
    'new Load retires buffered state from superseded Load and ignores its late reply',
    () async {
      final t = FakeTransport();
      final p = await createFake(t);
      final old = p.load(source);
      final oldError = expectLater(
        old,
        failsWith(YlFailureCodes.loadCancelled),
      );
      await flush();
      t.callbacks!.onState(wireState(session: 's1', revision: 1, sequence: 1));
      final next = p.load(source);
      await oldError;
      await flush();
      t.loads[1].complete(
        AndroidLoadReply(loadRequestId: 'load-2', sessionId: 's2'),
      );
      t.callbacks!.onState(wireState(session: 's2', revision: 2, sequence: 2));
      await next;
      t.loads[0].complete(
        AndroidLoadReply(loadRequestId: 'load-1', sessionId: 's1'),
      );
      await flush();
      t.callbacks!.onState(wireState(session: 's1', revision: 3, sequence: 3));
      expect(p.state.sessionId!.value, 's2');
      await p.dispose();
    },
  );
  test(
    'accepted Stop fences captured session before idle and cannot invalidate newer Load',
    () async {
      final t = FakeTransport();
      final p = await createFake(t);
      final current = await commit(t, p);
      final stopping = Completer<void>();
      t.stopping = () => stopping.future;
      final stop = p.stop();
      final next = await commit(t, p, session: 's2', revision: 5, sequence: 11);
      stopping.complete();
      await stop;
      await expectLater(
        p.play(current.sessionId),
        failsWith(YlFailureCodes.sessionStale),
      );
      await p.play(next.sessionId);
      final events = <YlPlayerEvent>[];
      final sub = p.events.listen(events.add);
      t.stopping = null;
      await p.stop();
      await expectLater(
        p.play(next.sessionId),
        failsWith(YlFailureCodes.sessionStale),
      );
      t.callbacks!.onFirstFrame(
        wireFrame(session: 's2', revision: 5, sequence: 12),
      );
      await flush();
      expect(events, isEmpty);
      t.callbacks!.onState(wireState(revision: 6, sequence: 13));
      expect(p.state.status, YlPlaybackStatus.idle);
      await sub.cancel();
      await p.dispose();
    },
  );
  test(
    'rejected Stop preserves usable session and cancels a pending Load',
    () async {
      final t = FakeTransport();
      final p = await createFake(t);
      final current = await commit(t, p);
      final pending = p.load(source);
      final cancelled = expectLater(
        pending,
        failsWith(YlFailureCodes.loadCancelled),
      );
      t.stopping = () => Future.error(
        PlatformException(
          code: 'native',
          details: wireFailure(scope: AndroidFailureScope.command),
        ),
      );
      await expectLater(p.stop(), failsWith(YlFailureCodes.networkFailed));
      await cancelled;
      await p.play(current.sessionId);
      await p.dispose();
    },
  );
  test(
    'terminal transport failure settles all commands and ignores late failures',
    () async {
      final t = FakeTransport();
      final p = await createFake(t);
      final current = await commit(t, p);
      final hanging = Completer<void>();
      t.playing = () => hanging.future;
      final command = p.play(current.sessionId);
      final commandError = expectLater(
        command,
        failsWith(YlFailureCodes.platformUnavailable),
      );
      final load = p.load(source);
      final loadError = expectLater(
        load,
        failsWith(YlFailureCodes.platformUnavailable),
      );
      await flush();
      t.loads.last.completeError(
        PlatformException(code: 'channel-error', message: 'secret'),
      );
      await commandError;
      await loadError;
      expect(p.state.failure!.scope, YlFailureScope.player);
      hanging.completeError(StateError('late secret'));
      await flush();
      await p.dispose();
    },
  );
  testWidgets(
    'hung failed-create cleanup is bounded and preserves original failure',
    (tester) async {
      final t = FakeTransport()..disposing = () => Completer<void>().future;
      final failing = expectLater(
        createFake(t, reply: wireCreate()..textureId = -1),
        failsWith(YlFailureCodes.protocolMismatch),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await failing;
      expect(t.callbacks, isNull);
    },
  );
  test(
    'dispose shares Future, cancels commands, unregisters before paused observers drain',
    () async {
      final t = FakeTransport();
      final p = await createFake(t);
      final current = await commit(t, p);
      final states = p.states.listen((_) {})..pause(),
          events = p.events.listen((_) {})..pause();
      final hanging = Completer<void>();
      t.playing = () => hanging.future;
      final commandError = expectLater(
        p.play(current.sessionId),
        failsWith(YlFailureCodes.playerDisposed),
      );
      final a = p.dispose(), b = p.dispose();
      expect(identical(a, b), isTrue);
      await a;
      await commandError;
      expect(t.callbacks, isNull);
      expect(t.calls.where((v) => v == 'dispose'), hasLength(1));
      expect(p.textureId.value, isNull);
      hanging.completeError(StateError('late secret'));
      await flush();
      await states.cancel();
      await events.cancel();
    },
  );
}
