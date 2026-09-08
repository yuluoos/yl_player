import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/testing.dart';

void main() {
  test(
    'reply-before-idle adapter passes with immediate stopped identity fence',
    () async {
      expect(await _run(_Fixture(delayedIdle: true)), isEmpty);
    },
  );
  test('missing idle fails even when stopped identity is fenced', () async {
    final failures = await _run(
      _Fixture(delayedIdle: true, broken: _Break.stop),
    );
    expect(failures.map((f) => f.caseName), contains('stop'));
  });
  test(
    'delayed idle cannot mask missing immediate stopped identity fence',
    () async {
      final failures = await _run(
        _Fixture(delayedIdle: true, broken: _Break.stopFence),
      );
      expect(failures.map((f) => f.caseName), contains('stop'));
    },
  );
  test('conformant buffering adapter passes all observable cases', () async {
    final fixture = _Fixture();
    final failures = await _run(fixture);
    expect(failures, isEmpty);
    expect(fixture.players.length, greaterThanOrEqualTo(15));
    expect(fixture.players.every((p) => p.disposed), isTrue);
    expect(
      () => failures.add(const YlConformanceFailure('x', _failure)),
      throwsUnsupportedError,
    );
  });

  test(
    'non-seekable live source uses a valid first-frame progress command',
    () async {
      final failures = await _run(
        _Fixture(timeline: const YlTimeline(isLive: true, isSeekable: false)),
      );
      expect(failures, isEmpty);
    },
  );
  test(
    'DVR first-frame progress stays inside a window starting after zero',
    () async {
      final failures = await _run(
        _Fixture(
          timeline: const YlTimeline(
            isLive: true,
            isSeekable: true,
            position: Duration(seconds: 150),
            dvrWindow: YlDvrWindow(
              start: Duration(seconds: 100),
              end: Duration(seconds: 200),
            ),
          ),
        ),
      );
      expect(failures, isEmpty);
    },
  );
  test(
    'network source with ordinary short header values is conformant',
    () async {
      final failures = await _run(
        _Fixture(
          source: YlNetworkSource(
            Uri.parse('https://media.example/movie.mp4'),
            request: YlHttpRequest(
              headers: {'X-Version': '2', 'X-Mode': 'idle'},
            ),
          ),
        ),
      );
      expect(failures, isEmpty);
    },
  );
  test(
    'bare distinctive credential value fails public string conformance',
    () async {
      const credential = 'canary7e21f349acdeCredential';
      final failures = await _run(
        _Fixture(
          source: YlNetworkSource(
            Uri.parse('https://media.example/movie.mp4'),
            request: YlHttpRequest(credentials: {'X-Session': credential}),
          ),
          publicFailureMessage: credential,
        ),
      );
      expect(failures.map((f) => f.caseName), contains('safe-public-strings'));
    },
  );
  test('bare distinctive ordinary header value remains detectable', () async {
    const marker = 'canaryOrdinaryHeader219ca731';
    final failures = await _run(
      _Fixture(
        source: YlNetworkSource(
          Uri.parse('https://media.example/movie.mp4'),
          request: YlHttpRequest(headers: {'X-Custom': marker}),
        ),
        publicFailureMessage: marker,
      ),
    );
    expect(failures.map((f) => f.caseName), contains('safe-public-strings'));
  });

  for (final entry in <_Break, String>{
    _Break.stale: 'stale-session',
    _Break.revision: 'revision-order',
    _Break.barrier: 'immediate-play',
    _Break.identity: 'load-identity',
    _Break.cancellation: 'newer-load-cancellation',
    _Break.stop: 'stop',
    _Break.stopHeld: 'stop-held-load',
    _Break.disposeHeld: 'dispose-held-load',
    _Break.firstFrame: 'first-frame-correlation',
    _Break.terminal: 'terminal-failure',
    _Break.rejectEverything: 'policy-0',
    _Break.rejectStrict: 'policy-0',
    _Break.ready: 'revision-order',
    _Break.acceptUnsupported: 'policy-1',
    _Break.unsafe: 'safe-public-strings',
    _Break.unsafeMessage: 'safe-public-strings',
    _Break.major: 'lifecycle',
    _Break.doubleDispose: 'double-disposal',
  }.entries) {
    test('runner detects ${entry.key.name}', () async {
      final failures = await _run(_Fixture(broken: entry.key));
      expect(failures.map((f) => f.caseName), contains(entry.value));
      expect(
        failures.every((f) => !f.toString().contains('private-secret')),
        isTrue,
      );
    });
  }

  test(
    'honest strict-policy rejection with supported defaults is conformant',
    () async {
      expect(
        await _run(_Fixture(defaultSuccess: true, broken: _Break.rejectStrict)),
        isEmpty,
      );
    },
  );
  test('policy fixtures cannot omit known supported evidence', () async {
    final failures = await _run(_Fixture(onlyUnsupported: true));
    expect(failures.map((f) => f.caseName), contains('policy-fixtures'));
  });
  test('invalid deadlines fail before creating a player', () async {
    final fixture = _Fixture();
    for (final timeout in [Duration.zero, const Duration(microseconds: -1)]) {
      await expectLater(
        YlPlatformConformance(fixture, caseTimeout: timeout).run(),
        throwsArgumentError,
      );
      await expectLater(
        YlPlatformConformance(fixture, cleanupTimeout: timeout).run(),
        throwsArgumentError,
      );
    }
    expect(fixture.players, isEmpty);
  });
  test('public case values have structural equality and safe strings', () {
    const policy = YlConformancePolicyCase(
      source: YlFileSource('/private-secret'),
      options: YlLoadOptions(),
      expected: YlConformancePolicyOutcome.success,
    );
    const equal = YlConformancePolicyCase(
      source: YlFileSource('/private-secret'),
      options: YlLoadOptions(),
      expected: YlConformancePolicyOutcome.success,
    );
    expect(policy, equal);
    expect(policy.hashCode, equal.hashCode);
    expect(policy.toString(), isNot(contains('private-secret')));
    const failure = YlConformanceFailure('private-secret', _failure);
    const sameFailure = YlConformanceFailure('private-secret', _failure);
    expect(failure, sameFailure);
    expect(failure.hashCode, sameFailure.hashCode);
    expect(failure.toString(), isNot(contains('private-secret')));
  });
  test(
    'a hung create times out and its late player is released and disposed',
    () async {
      final late = Completer<YlPlatformPlayer>();
      final fixture = _Fixture(firstCreate: late.future);
      final failures = await _run(fixture);
      expect(failures.map((f) => f.caseName), contains('lifecycle'));
      expect(fixture.players.length, greaterThan(1));
      final player = _FakePlayer();
      late.complete(player);
      await player.didDispose.future.timeout(const Duration(seconds: 1));
      expect(player.releases, greaterThan(0));
    },
  );
  test(
    'late create, command and cleanup errors are consumed while later cases run',
    () async {
      final uncaught = <Object>[];
      final completed = Completer<void>();
      runZonedGuarded(() async {
        try {
          final lateCreate = Completer<YlPlatformPlayer>();
          final fixture = _Fixture(firstCreate: lateCreate.future);
          expect(await _run(fixture), isNotEmpty);
          lateCreate.completeError(StateError('private-secret'));
          final lateCommand = Completer<void>();
          final commands = _Fixture(firstVolume: lateCommand.future);
          final failures = await _run(commands);
          expect(failures.map((f) => f.caseName), contains('lifecycle'));
          expect(commands.players.last.disposed, isTrue);
          lateCommand.completeError(StateError('private-secret'));
          final lateRelease = Completer<void>();
          final lateDispose = Completer<void>();
          final cleanup = _Fixture(
            firstRelease: lateRelease.future,
            firstDispose: lateDispose.future,
          );
          final cleanupFailures = await _run(cleanup);
          expect(
            cleanupFailures.map((f) => f.caseName),
            contains('lifecycle.cleanup'),
          );
          expect(cleanup.players.first.disposeCalls, greaterThan(0));
          expect(cleanup.players.last.disposed, isTrue);
          lateRelease.completeError(StateError('private-secret'));
          lateDispose.completeError(StateError('private-secret'));
          await Future<void>.delayed(Duration.zero);
          completed.complete();
        } on Object catch (error, stack) {
          completed.completeError(error, stack);
        }
      }, (error, stack) => uncaught.add(error));
      await completed.future;
      expect(uncaught, isEmpty);
    },
  );
  test(
    'release and disposal failures cannot skip disposal or later cases',
    () async {
      final fixture = _Fixture(firstCleanupHangs: true);
      final failures = await _run(fixture);
      expect(failures.map((f) => f.caseName), contains('lifecycle.cleanup'));
      expect(fixture.players.first.disposeCalls, greaterThan(0));
      expect(fixture.players.last.disposed, isTrue);
    },
  );
  test(
    'a never completing disposal is bounded and later cases execute',
    () async {
      final fixture = _Fixture(firstDisposeHangs: true);
      final failures = await _run(fixture);
      expect(failures.map((f) => f.caseName), contains('lifecycle.cleanup'));
      expect(fixture.players.last.disposed, isTrue);
    },
  );
}

Future<List<YlConformanceFailure>> _run(_Fixture fixture) =>
    YlPlatformConformance(
      fixture,
      caseTimeout: const Duration(milliseconds: 80),
      cleanupTimeout: const Duration(milliseconds: 30),
    ).run();

const _failure = YlFailure(
  category: YlFailureCategory.decoder,
  code: YlFailureCodes.decoderUnavailable,
  message: 'Failed safely.',
  retryable: false,
  scope: YlFailureScope.session,
  diagnosticId: 'fake-failure',
);
const _strict = YlLoadOptions(
  decoderPolicyOverride: YlDecoderPolicy.hardwareRequired,
);
const _unsupported = YlLoadOptions(
  bufferStrategy: YlBufferStrategy.bounded(
    minDuration: Duration.zero,
    maxDuration: Duration(seconds: 1),
    maxManagedBytes: 100,
  ),
);

enum _Break {
  stale,
  revision,
  barrier,
  identity,
  cancellation,
  stop,
  stopFence,
  stopHeld,
  disposeHeld,
  firstFrame,
  terminal,
  rejectEverything,
  rejectStrict,
  ready,
  acceptUnsupported,
  unsafe,
  unsafeMessage,
  major,
  doubleDispose,
}

class _Fixture implements YlPlatformConformanceFixture {
  _Fixture({
    this.broken,
    this.delayedIdle = false,
    this.firstCreate,
    this.firstVolume,
    this.firstRelease,
    this.firstDispose,
    this.firstCleanupHangs = false,
    this.firstDisposeHangs = false,
    this.onlyUnsupported = false,
    this.defaultSuccess = false,
    this.source = const YlFileSource('/private-secret/movie.mp4'),
    this.timeline = const YlTimeline(
      isSeekable: true,
      duration: Duration(seconds: 10),
    ),
    this.publicFailureMessage,
  });
  final _Break? broken;
  final bool delayedIdle;
  final Future<YlPlatformPlayer>? firstCreate;
  final Future<void>? firstVolume;
  final Future<void>? firstRelease;
  final Future<void>? firstDispose;
  final bool firstCleanupHangs;
  final bool firstDisposeHangs;
  final bool onlyUnsupported;
  final bool defaultSuccess;
  final players = <_FakePlayer>[];
  var creates = 0;
  @override
  final YlMediaSource source;
  final YlTimeline timeline;
  final String? publicFailureMessage;
  @override
  List<YlConformancePolicyCase> get policyCases => [
    if (!onlyUnsupported)
      YlConformancePolicyCase(
        source: source,
        options: defaultSuccess ? const YlLoadOptions() : _strict,
        expected: YlConformancePolicyOutcome.success,
      ),
    YlConformancePolicyCase(
      source: source,
      options: _unsupported,
      expected: YlConformancePolicyOutcome.unsupported,
    ),
  ];
  @override
  Future<YlPlatformPlayer> createPlayer() {
    final first = creates++ == 0;
    if (first && firstCreate != null) return firstCreate!;
    final player = _FakePlayer(
      broken: broken,
      delayedIdle: delayedIdle,
      timeline: timeline,
      publicFailureMessage: publicFailureMessage,
      volumeFuture: first ? firstVolume : null,
      releaseFuture: first ? firstRelease : null,
      disposeFuture: first ? firstDispose : null,
      cleanupHangs: first && firstCleanupHangs,
      disposeHangs: first && firstDisposeHangs,
    );
    players.add(player);
    return Future.value(player);
  }

  @override
  Future<void> holdNextLoad(YlPlatformPlayer player) async {
    (player as _FakePlayer).hold = true;
  }

  @override
  Future<void> releaseHeldLoad(YlPlatformPlayer player) =>
      (player as _FakePlayer).release();
  @override
  Future<void> emitReady(
    YlPlatformPlayer player,
    YlPlaybackSessionId sessionId,
  ) async {
    final p = player as _FakePlayer;
    if (p.state.sessionId == sessionId && p.broken != _Break.ready) {
      p.publish(p.state.copyWith(status: YlPlaybackStatus.ready));
    }
  }

  @override
  Future<void> emitFirstFrame(
    YlPlatformPlayer player,
    YlPlaybackSessionId sessionId,
  ) async {
    final p = player as _FakePlayer;
    if (p.state.sessionId == sessionId &&
        p.broken != _Break.firstFrame &&
        p.frames.add(sessionId)) {
      p.eventController.add(
        YlFirstFrameEvent(
          sessionId: sessionId,
          revision: p.commitRevisions[sessionId]!,
          occurredAt: const Duration(milliseconds: 1),
        ),
      );
    }
  }

  @override
  Future<void> emitTerminalFailure(
    YlPlatformPlayer player,
    YlPlaybackSessionId sessionId,
  ) async {
    final p = player as _FakePlayer;
    if (p.state.sessionId != sessionId) return;
    if (p.failed.add(sessionId) || p.broken == _Break.terminal) {
      p.publish(
        p.state.copyWith(status: YlPlaybackStatus.failed, failure: _failure),
      );
      p.eventController.add(
        YlPlaybackFailedEvent(
          sessionId: sessionId,
          revision: p.state.revision,
          occurredAt: const Duration(milliseconds: 2),
          failure: _failure,
        ),
      );
    }
  }
}

class _FakePlayer implements YlPlatformPlayer {
  _FakePlayer({
    this.broken,
    this.delayedIdle = false,
    this.volumeFuture,
    this.releaseFuture,
    this.disposeFuture,
    this.cleanupHangs = false,
    this.disposeHangs = false,
    this.timeline = const YlTimeline(
      isSeekable: true,
      duration: Duration(seconds: 10),
    ),
    this.publicFailureMessage,
  });
  final _Break? broken;
  final bool delayedIdle;
  final Future<void>? volumeFuture;
  final Future<void>? releaseFuture;
  final Future<void>? disposeFuture;
  final bool cleanupHangs;
  final bool disposeHangs;
  final YlTimeline timeline;
  final String? publicFailureMessage;
  final didDispose = Completer<void>();
  final stateController = StreamController<YlPlayerState>.broadcast();
  final eventController = StreamController<YlPlayerEvent>.broadcast();
  final frames = <YlPlaybackSessionId>{};
  final failed = <YlPlaybackSessionId>{};
  final commitRevisions = <YlPlaybackSessionId, int>{};
  int serial = 0;
  int releases = 0;
  int disposeCalls = 0;
  bool disposed = false;
  bool hold = false;
  Completer<YlPlatformLoadResult>? held;
  YlPlaybackSessionId? heldId;
  @override
  final ValueNotifier<int?> textureId = ValueNotifier<int?>(1);
  @override
  YlPlayerState state = YlPlayerState();
  @override
  Stream<YlPlayerState> get states => stateController.stream;
  @override
  Stream<YlPlayerEvent> get events => eventController.stream;
  @override
  YlPlatformImplementationInfo get implementation =>
      YlPlatformImplementationInfo(
        name: 'fake',
        version: '1',
        spiMajor: broken == _Break.major ? 1 : 2,
      );
  @override
  YlPlayerCapabilities get capabilities => YlPlayerCapabilities(
    deviceProfile: 'fake',
    supportedOperations: YlPlayerOperation.values,
  );

  void publish(YlPlayerState next) {
    state = next.copyWith(
      revision: broken == _Break.revision ? 0 : state.revision + 1,
    );
    stateController.add(state);
  }

  YlPlaybackSessionId? stopped;
  void check([YlPlaybackSessionId? id]) {
    if (id != null && id == stopped) _throw(YlFailureCodes.sessionStale);
    if (disposed) _throw(YlFailureCodes.playerDisposed);
    if (id != null && id != state.sessionId && broken != _Break.stale) {
      _throw(YlFailureCodes.sessionStale);
    }
  }

  bool rejects(YlLoadOptions options) =>
      broken == _Break.rejectEverything ||
      (broken == _Break.rejectStrict && options == _strict) ||
      (options == _unsupported && broken != _Break.acceptUnsupported);
  @override
  Future<YlSourceAssessment> assess(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) async {
    check();
    return YlSourceAssessment(
      outcome: rejects(options)
          ? YlSourceAssessmentOutcome.incompatible
          : YlSourceAssessmentOutcome.compatible,
      rejection: rejects(options) ? _policyFailure : null,
    );
  }

  @override
  Future<YlPlatformLoadResult> load(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) {
    check();
    if (rejects(options)) {
      return Future.error(const YlPlayerException(_policyFailure));
    }
    if (broken != _Break.cancellation) cancelHeld();
    final id = YlPlaybackSessionId(
      broken == _Break.identity ? 'fixed' : '${++serial}',
    );
    if (hold) {
      hold = false;
      held = Completer<YlPlatformLoadResult>();
      heldId = id;
      return held!.future;
    }
    return Future.value(commit(id));
  }

  YlPlatformLoadResult commit(YlPlaybackSessionId id) {
    if (broken != _Break.barrier) {
      publish(
        YlPlayerState(
          sessionId: id,
          status: YlPlaybackStatus.buffering,
          timeline: timeline,
          failure:
              broken == _Break.unsafe ||
                  broken == _Break.unsafeMessage ||
                  publicFailureMessage != null
              ? YlFailure(
                  category: YlFailureCategory.internal,
                  code: YlFailureCodes.internal,
                  message:
                      publicFailureMessage ??
                      (broken == _Break.unsafe
                          ? '/private-secret/movie.mp4'
                          : 'Authorization: private-secret'),
                  retryable: false,
                  scope: YlFailureScope.session,
                  diagnosticId: 'fake',
                )
              : null,
        ),
      );
    }
    commitRevisions[id] = state.revision;
    return YlPlatformLoadResult(sessionId: id);
  }

  void cancelHeld() {
    final pending = held;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(_exception(YlFailureCodes.loadCancelled));
    }
    held = null;
  }

  Future<void> release() async {
    releases++;
    await releaseFuture;
    if (cleanupHangs) return Completer<void>().future;
    final pending = held;
    held = null;
    if (pending != null && !pending.isCompleted) {
      if (disposed) {
        pending.completeError(_exception(YlFailureCodes.loadCancelled));
      } else {
        pending.complete(commit(heldId!));
      }
    }
  }

  @override
  Future<void> play(YlPlaybackSessionId id) async {
    check(id);
    publish(state.copyWith(status: YlPlaybackStatus.playing));
  }

  @override
  Future<void> pause(YlPlaybackSessionId id) async {
    check(id);
    publish(state.copyWith(status: YlPlaybackStatus.paused));
  }

  @override
  Future<void> seekTo(YlPlaybackSessionId id, Duration position) async {
    check(id);
    if (!state.timeline.isSeekable) _throw(YlFailureCodes.policyUnsupported);
    final window = state.timeline.dvrWindow;
    if (window != null && (position < window.start || position > window.end)) {
      throw RangeError('Seek outside the DVR window.');
    }
    if (window == null &&
        state.timeline.duration != null &&
        position > state.timeline.duration!) {
      throw RangeError('Seek outside the source duration.');
    }
    publish(
      state.copyWith(timeline: state.timeline.copyWith(position: position)),
    );
  }

  @override
  Future<void> seekToLiveEdge(YlPlaybackSessionId id) async {
    check(id);
  }

  @override
  Future<void> setPlaybackSpeed(YlPlaybackSessionId id, double speed) async {
    check(id);
  }

  @override
  Future<void> selectAudioTrack(YlPlaybackSessionId id, String trackId) async {
    check(id);
  }

  @override
  Future<void> setVideoConstraints(
    YlPlaybackSessionId id,
    YlVideoConstraints constraints,
  ) async {
    check(id);
  }

  @override
  Future<void> setVolume(double volume) async {
    check();
    await volumeFuture;
  }

  @override
  Future<void> stop() async {
    check();
    if (broken != _Break.stopHeld) cancelHeld();
    final captured = state.sessionId;
    if (delayedIdle && broken != _Break.stopFence) stopped = captured;
    if (broken != _Break.stop) {
      if (delayedIdle) {
        Timer(const Duration(milliseconds: 10), () {
          if (!disposed && state.sessionId == captured) {
            publish(YlPlayerState());
          }
        });
      } else {
        publish(YlPlayerState());
      }
    }
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await disposeFuture;
    if (disposeHangs) return Completer<void>().future;
    if (disposed) {
      if (broken == _Break.doubleDispose) throw StateError('private-secret');
      return;
    }
    disposed = true;
    if (broken != _Break.disposeHeld) cancelHeld();
    textureId.value = null;
    await stateController.close();
    await eventController.close();
    didDispose.complete();
  }
}

const _policyFailure = YlFailure(
  category: YlFailureCategory.unsupported,
  code: YlFailureCodes.policyUnsupported,
  message: 'Unsupported policy.',
  retryable: false,
  scope: YlFailureScope.command,
  diagnosticId: 'policy',
);
YlPlayerException _exception(String code) => YlPlayerException(
  YlFailure(
    category: YlFailureCategory.cancelled,
    code: code,
    message: 'Operation rejected.',
    retryable: false,
    scope: YlFailureScope.command,
    diagnosticId: 'fake',
  ),
);
Never _throw(String code) => throw _exception(code);
