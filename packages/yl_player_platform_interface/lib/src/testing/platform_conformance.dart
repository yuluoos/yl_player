import 'dart:async';

import '../../yl_player_platform_interface.dart';

/// Expected behavior declared independently of the adapter's own assessment.
enum YlConformancePolicyOutcome { success, unsupported }

/// One known source/policy expectation. Include at least one supported case
/// (defaults/preferences are allowed), plus strict success and unsupported cases
/// applicable to the adapter. Managed-route support is verified by native suites.
final class YlConformancePolicyCase {
  const YlConformancePolicyCase({
    required this.source,
    required this.options,
    required this.expected,
  });
  final YlMediaSource source;
  final YlLoadOptions options;
  final YlConformancePolicyOutcome expected;
  @override
  bool operator ==(Object other) =>
      other is YlConformancePolicyCase &&
      source == other.source &&
      options == other.options &&
      expected == other.expected;
  @override
  int get hashCode => Object.hash(source, options, expected);
  @override
  String toString() =>
      'YlConformancePolicyCase(source: $source, options: $options, expected: ${expected.name})';
}

/// An implementation-owned deterministic harness. [source] must be supported
/// with default load options, committing initially in buffering without Ready or
/// First Frame until the explicit hooks below inject them. Each created player
/// is isolated. Hook futures complete after their input is processed and its
/// observable state/events are published, including ignored/duplicate inputs.
/// Private transport reply ordering and controller milestone futures belong in
/// adapter/controller suites, not this SPI-only harness.
///
/// For metadata secrecy checks, use distinctive canary values of at least 16
/// characters in request headers/credentials, URI user info and queries. Short
/// values such as `2` can occur innocently in diagnostics and are not substring
/// secrecy markers. Even long values must be chosen to avoid ordinary output:
/// these finite checks cannot establish information flow from coincident text.
abstract interface class YlPlatformConformanceFixture {
  YlMediaSource get source;
  List<YlConformancePolicyCase> get policyCases;
  Future<YlPlatformPlayer> createPlayer();

  /// Arm a hold synchronously at the next load's pre-commit boundary.
  Future<void> holdNextLoad(YlPlatformPlayer player);

  /// Idempotently release any hold, including on stopped/disposed players.
  Future<void> releaseHeldLoad(YlPlatformPlayer player);
  Future<void> emitReady(
    YlPlatformPlayer player,
    YlPlaybackSessionId sessionId,
  );

  /// Inject the original session's first-frame evidence, even after newer
  /// timeline revisions. Repeated and stale injections must be handled normally.
  Future<void> emitFirstFrame(
    YlPlatformPlayer player,
    YlPlaybackSessionId sessionId,
  );
  Future<void> emitTerminalFailure(
    YlPlatformPlayer player,
    YlPlaybackSessionId sessionId,
  );
}

final class YlConformanceFailure {
  const YlConformanceFailure(this.caseName, this.failure);
  final String caseName;
  final YlFailure failure;
  @override
  bool operator ==(Object other) =>
      other is YlConformanceFailure &&
      caseName == other.caseName &&
      failure == other.failure;
  @override
  int get hashCode => Object.hash(caseName, failure);
  @override
  String toString() =>
      'YlConformanceFailure(caseName: <redacted>, failure: $failure)';
}

/// Runs isolated, bounded cases without a test-framework dependency.
final class YlPlatformConformance {
  const YlPlatformConformance(
    this.fixture, {
    this.caseTimeout = const Duration(seconds: 10),
    this.cleanupTimeout = const Duration(seconds: 2),
  });
  final YlPlatformConformanceFixture fixture;
  final Duration caseTimeout;
  final Duration cleanupTimeout;

  /// Each case shares one deadline, including creation and every operation.
  /// Cleanup has its own total budget, split between release, subscription
  /// cancellation and disposal so a hung release cannot prevent disposal.
  /// Late create results receive the same bounded cleanup. Late errors are
  /// observed without retaining or interpolating raw exception objects.
  Future<List<YlConformanceFailure>> run() async {
    if (caseTimeout <= Duration.zero || cleanupTimeout <= Duration.zero) {
      throw ArgumentError('Conformance deadlines must be positive.');
    }
    final failures = <YlConformanceFailure>[];
    final cases = <String, Future<void> Function(_Case)>{
      'lifecycle': (c) async {
        final p = c.player;
        _require(p.implementation.spiMajor == ylPlayerSpiMajor);
        validateYlPlayerCapabilities(p.capabilities);
        validateYlPlayerState(p.state);
        _require(
          p.state.sessionId == null && p.state.status == YlPlaybackStatus.idle,
        );
        _require(p.textureId.value == null || p.textureId.value! >= 0);
        final before = p.state;
        final assessment = await c.step(() => p.assess(fixture.source));
        _require(assessment.outcome != YlSourceAssessmentOutcome.incompatible);
        _require(p.state == before);
        await c.step(() => p.setVolume(0.5));
        await c.step(p.stop);
      },
      'load-identity': (c) async {
        final first = await _load(c);
        final second = await _load(c);
        _require(first.sessionId != second.sessionId);
      },
      'immediate-play': (c) async {
        final result = await _load(c);
        _require(c.player.state.status == YlPlaybackStatus.buffering);
        _require(c.events.whereType<YlFirstFrameEvent>().isEmpty);
        // No frame pump, Ready injection or stream wait between load and play.
        await c.step(() => c.player.play(result.sessionId));
      },
      'newer-load-cancellation': (c) async {
        await c.step(() => fixture.holdNextLoad(c.player));
        final pending = c.observe(() => c.player.load(fixture.source));
        final newer = await _load(c);
        await c.rejected(pending, YlFailureCodes.loadCancelled);
        await c.step(() => fixture.releaseHeldLoad(c.player));
        _require(c.player.state.sessionId == newer.sessionId);
      },
      'stale-session': (c) async {
        final old = await _load(c);
        final current = await _load(c);
        final before = c.player.state;
        for (final command in _sessionCommands(c.player, old.sessionId)) {
          await c.rejected(c.observe(command), YlFailureCodes.sessionStale);
        }
        _require(c.player.state == before);
        await c.step(() => c.player.play(current.sessionId));
      },
      'stop': (c) async {
        final result = await _load(c);
        await c.step(c.player.stop);
        _require(
          c.player.state.sessionId == null &&
              c.player.state.status == YlPlaybackStatus.idle,
        );
        await c.rejected(
          c.observe(() => c.player.play(result.sessionId)),
          YlFailureCodes.sessionStale,
        );
        await c.step(() => c.player.setVolume(0.5));
        final next = await _load(c);
        _require(next.sessionId != result.sessionId);
      },
      'revision-order': (c) async {
        final result = await _load(c);
        await c.step(() => fixture.emitReady(c.player, result.sessionId));
        _require(c.player.state.status == YlPlaybackStatus.ready);
        await c.step(() => c.player.play(result.sessionId));
        await c.step(() => c.player.pause(result.sessionId));
        await c.step(c.player.stop);
        await _load(c);
        _require(c.snapshots.isNotEmpty);
        var revision = c.initialRevision;
        for (final state in c.snapshots) {
          validateYlPlayerState(state);
          _require(state.revision > revision);
          revision = state.revision;
        }
        _require(c.player.state.revision == revision);
      },
      'first-frame-correlation': (c) async {
        final old = await _load(c);
        final current = await _load(c);
        await c.step(() => fixture.emitReady(c.player, current.sessionId));
        final timeline = c.player.state.timeline;
        if (timeline.isSeekable &&
            c.player.capabilities.supportedOperations.contains(
              YlPlayerOperation.seek,
            )) {
          final window = timeline.dvrWindow;
          final position = window == null
              ? Duration.zero
              : window.start + (window.end - window.start) ~/ 2;
          await c.step(() => c.player.seekTo(current.sessionId, position));
        } else {
          await c.step(() => c.player.play(current.sessionId));
        }
        final before = c.player.state;
        await c.step(() => fixture.emitFirstFrame(c.player, old.sessionId));
        _require(c.events.whereType<YlFirstFrameEvent>().isEmpty);
        await c.step(() => fixture.emitFirstFrame(c.player, current.sessionId));
        await c.waitFor(
          () => c.events.whereType<YlFirstFrameEvent>().isNotEmpty,
        );
        await c.step(() => fixture.emitFirstFrame(c.player, current.sessionId));
        final frames = c.events.whereType<YlFirstFrameEvent>().toList();
        _require(
          frames.length == 1 && frames.single.sessionId == current.sessionId,
        );
        _require(frames.single.revision <= before.revision);
        _require(
          c.player.state.revision >= before.revision &&
              c.player.state.sessionId == current.sessionId,
        );
      },
      'terminal-failure': (c) async {
        final result = await _load(c);
        await c.step(
          () => fixture.emitTerminalFailure(c.player, result.sessionId),
        );
        await c.waitFor(
          () => c.events.whereType<YlPlaybackFailedEvent>().isNotEmpty,
        );
        await c.step(
          () => fixture.emitTerminalFailure(c.player, result.sessionId),
        );
        final errors = c.events.whereType<YlPlaybackFailedEvent>().toList();
        _require(
          errors.length == 1 && errors.single.sessionId == result.sessionId,
        );
        _require(
          c.player.state.status == YlPlaybackStatus.failed &&
              c.player.state.failure == errors.single.failure,
        );
      },
      'safe-public-strings': (c) async {
        final assessment = await c.step(() => c.player.assess(fixture.source));
        final result = await _load(c);
        _checkStrings(c, result, assessment);
        await c.step(
          () => fixture.emitTerminalFailure(c.player, result.sessionId),
        );
        _checkStrings(c, result, assessment);
      },
      'stop-held-load': (c) => _invalidateHeld(c, dispose: false),
      'dispose-held-load': (c) => _invalidateHeld(c, dispose: true),
      'double-disposal': (c) async {
        await c.step(c.player.dispose);
        await c.step(c.player.dispose);
        await c.rejected(
          c.observe(() => c.player.load(fixture.source)),
          YlFailureCodes.playerDisposed,
        );
        await c.rejected(
          c.observe(() => c.player.setVolume(0.5)),
          YlFailureCodes.playerDisposed,
        );
      },
    };
    // Snapshot fixture declarations: subsequent list mutation cannot change a run.
    try {
      final policies = List<YlConformancePolicyCase>.unmodifiable(
        fixture.policyCases,
      );
      if (!policies.any(
        (p) => p.expected == YlConformancePolicyOutcome.success,
      )) {
        failures.add(_failure('policy-fixtures'));
      }
      for (var i = 0; i < policies.length; i++) {
        final policy = policies[i];
        cases['policy-$i'] = (c) => _policy(c, policy);
      }
    } on Object {
      failures.add(_failure('policy-fixtures'));
    }
    for (final entry in cases.entries) {
      final context = _Case(fixture, caseTimeout, cleanupTimeout);
      try {
        await context.create();
        await entry.value(context);
        context.check();
      } on TimeoutException {
        failures.add(_failure(entry.key, timeout: true));
      } on Object {
        failures.add(_failure(entry.key));
      } finally {
        if (!await context.cleanup()) {
          failures.add(_failure('${entry.key}.cleanup'));
        }
      }
    }
    return List.unmodifiable(failures);
  }

  Future<YlPlatformLoadResult> _load(_Case c) async {
    final result = await c.step(() => c.player.load(fixture.source));
    validateYlPlaybackSessionId(result.sessionId);
    _require(c.player.state.sessionId == result.sessionId);
    return result;
  }

  Future<void> _invalidateHeld(_Case c, {required bool dispose}) async {
    await _load(c);
    await c.step(() => fixture.holdNextLoad(c.player));
    final pending = c.observe(() => c.player.load(fixture.source));
    await c.step(dispose ? c.player.dispose : c.player.stop);
    // Cancellation must settle while the candidate is still held.
    await c.rejected(pending, YlFailureCodes.loadCancelled);
    await c.step(() => fixture.releaseHeldLoad(c.player));
    if (!dispose) _require(c.player.state.sessionId == null);
  }

  Future<void> _policy(_Case c, YlConformancePolicyCase policy) async {
    final before = c.player.state;
    final assessment = await c.step(
      () => c.player.assess(policy.source, options: policy.options),
    );
    _require(c.player.state == before);
    if (policy.expected == YlConformancePolicyOutcome.success) {
      _require(assessment.outcome != YlSourceAssessmentOutcome.incompatible);
      final loaded = await c.step(
        () => c.player.load(policy.source, options: policy.options),
      );
      validateYlPlaybackSessionId(loaded.sessionId);
      _require(c.player.state.sessionId == loaded.sessionId);
      await c.step(() => c.player.play(loaded.sessionId));
    } else {
      // Static rejection or inspection-time rejection are both valid; silently
      // relaxing the policy or rejecting with an unrelated error is not.
      if (assessment.outcome == YlSourceAssessmentOutcome.incompatible) {
        _require(
          assessment.rejection?.category == YlFailureCategory.unsupported &&
              assessment.rejection?.code == YlFailureCodes.policyUnsupported,
        );
      }
      final outcome = await c.outcome(
        c.observe(() => c.player.load(policy.source, options: policy.options)),
      );
      _require(
        outcome.code == YlFailureCodes.policyUnsupported &&
            outcome.category == YlFailureCategory.unsupported,
      );
      _require(c.player.state == before);
    }
  }

  void _checkStrings(
    _Case c,
    YlPlatformLoadResult result,
    YlSourceAssessment assessment,
  ) {
    final messages = <String>[
      if (assessment.rejection case final failure?) failure.message,
      if (c.player.state.failure case final failure?) failure.message,
      for (final event in c.events.whereType<YlPlaybackFailedEvent>())
        event.failure.message,
      for (final event in c.events.whereType<YlRetryScheduledEvent>())
        event.failure.message,
    ];
    for (final message in messages) {
      _require(YlSafeDiagnostics.publicMessage(message) == message);
    }
    final strings = <String>[
      ...messages,
      fixture.source.toString(),
      c.player.implementation.toString(),
      c.player.capabilities.toString(),
      c.player.state.toString(),
      result.toString(),
      assessment.toString(),
      if (c.player.state.failure case final failure?) failure.message,
      for (final event in c.events) event.toString(),
      for (final event in c.events.whereType<YlPlaybackFailedEvent>())
        event.failure.message,
    ];
    for (final secret in _sourceSecrecyMarkers(fixture.source)) {
      if (secret.isNotEmpty) {
        _require(strings.every((s) => !s.contains(secret)));
      }
    }
  }
}

// Full source identities are checked directly. Metadata uses fixture canaries;
// a short scalar could otherwise match unrelated state/version/revision text.
Iterable<String> _sourceSecrecyMarkers(YlMediaSource source) sync* {
  switch (source) {
    case YlFileSource():
      yield source.path;
    case YlNetworkSource():
      yield source.uri.toString();
      yield* [
        source.uri.userInfo,
        source.uri.query,
        ...source.request.headers.values,
        ...source.request.credentials.values,
      ].where((value) => value.length >= 16);
    case YlAndroidContentSource():
      yield source.uri.toString();
  }
}

Iterable<Future<void> Function()> _sessionCommands(
  YlPlatformPlayer p,
  YlPlaybackSessionId id,
) sync* {
  yield () => p.play(id);
  yield () => p.pause(id);
  yield () => p.seekTo(id, Duration.zero);
  yield () => p.seekToLiveEdge(id);
  yield () => p.setPlaybackSpeed(id, 1);
  yield () => p.selectAudioTrack(id, 'conformance-track');
  yield () => p.setVideoConstraints(id, const YlVideoConstraints());
}

void _require(bool condition) {
  if (!condition) throw const _Violation();
}

final class _Violation implements Exception {
  const _Violation();
}

YlConformanceFailure _failure(String name, {bool timeout = false}) =>
    YlConformanceFailure(
      name,
      YlFailure(
        category: YlFailureCategory.internal,
        code: timeout ? 'conformance.timeout' : 'conformance.failed',
        message: timeout
            ? 'Conformance case exceeded its deadline.'
            : 'Conformance requirement failed.',
        retryable: false,
        scope: YlFailureScope.player,
        diagnosticId: 'conformance',
      ),
    );

/// Only fixed/typed error metadata is kept; never raw exceptions or stack traces.
final class _Outcome<T> {
  const _Outcome.success(this.value)
    : failed = false,
      code = null,
      category = null;
  const _Outcome.failure(this.code, this.category)
    : failed = true,
      value = null;
  final T? value;
  final bool failed;
  final String? code;
  final YlFailureCategory? category;
}

Future<_Outcome<T>> _observe<T>(Future<T> Function() action) =>
    Future<T>.sync(action).then(
      _Outcome<T>.success,
      onError: (Object error, StackTrace stack) => _Outcome<T>.failure(
        error is YlPlayerException ? error.failure.code : null,
        error is YlPlayerException ? error.failure.category : null,
      ),
    );

final class _Case {
  _Case(this.fixture, this.timeout, this.cleanupTimeout);
  final YlPlatformConformanceFixture fixture;
  final Duration timeout;
  final Duration cleanupTimeout;
  final Stopwatch clock = Stopwatch()..start();
  final subscriptions = <StreamSubscription<Object?>>[];
  final snapshots = <YlPlayerState>[];
  final events = <YlPlayerEvent>[];
  YlPlatformPlayer? _player;
  YlPlatformPlayer get player => _player!;
  int initialRevision = 0;
  bool active = true;
  bool streamFailed = false;
  Completer<void> changed = Completer<void>();

  void check() {
    _require(active && !streamFailed);
  }

  void notify() {
    changed.complete();
    changed = Completer<void>();
  }

  Future<void> create() async {
    final creation = _observe(() async {
      final created = await fixture.createPlayer();
      if (!active) {
        unawaited(_cleanupPlayer(fixture, created, [], cleanupTimeout));
      } else {
        _player = created;
      }
      return created;
    });
    await outcome(creation);
    _require(_player != null);
    initialRevision = player.state.revision;
    subscriptions.add(
      player.states.listen(
        (state) {
          if (!active) return;
          snapshots.add(state);
          notify();
        },
        onError: (Object error, StackTrace stack) {
          streamFailed = true;
          notify();
        },
      ),
    );
    subscriptions.add(
      player.events.listen(
        (event) {
          if (!active) return;
          try {
            validateYlPlayerEvent(event);
          } on Object {
            streamFailed = true;
          }
          events.add(event);
          notify();
        },
        onError: (Object error, StackTrace stack) {
          streamFailed = true;
          notify();
        },
      ),
    );
  }

  Future<_Outcome<T>> observe<T>(Future<T> Function() action) {
    check();
    return _observe(action);
  }

  Future<_Outcome<T>> outcome<T>(Future<_Outcome<T>> future) async {
    check();
    final remaining = timeout - clock.elapsed;
    if (remaining <= Duration.zero) {
      throw TimeoutException('Conformance deadline.');
    }
    final result = await future.timeout(remaining);
    check();
    return result;
  }

  Future<T> step<T>(Future<T> Function() action) async {
    final result = await outcome(observe(action));
    _require(!result.failed);
    return result.value as T;
  }

  Future<void> rejected<T>(Future<_Outcome<T>> future, String code) async {
    final result = await outcome(future);
    _require(result.failed && result.code == code);
  }

  Future<void> waitFor(bool Function() predicate) async {
    while (!predicate()) {
      await step(() => changed.future);
    }
  }

  Future<bool> cleanup() async {
    active = false;
    final owned = _player;
    if (owned == null) return true;
    return _cleanupPlayer(fixture, owned, subscriptions, cleanupTimeout);
  }
}

Future<bool> _cleanupPlayer(
  YlPlatformConformanceFixture fixture,
  YlPlatformPlayer player,
  List<StreamSubscription<Object?>> subscriptions,
  Duration timeout,
) async {
  // Reserve a budget for every phase even if earlier work fails or never settles.
  final slice = Duration(
    microseconds: (timeout.inMicroseconds ~/ 3).clamp(
      1,
      timeout.inMicroseconds,
    ),
  );
  var succeeded = true;
  for (final action in <Future<void> Function()>[
    () => fixture.releaseHeldLoad(player),
    () async {
      await Future.wait(subscriptions.map((s) => s.cancel()));
    },
    player.dispose,
  ]) {
    try {
      final result = await _observe(action).timeout(slice);
      if (result.failed) succeeded = false;
    } on Object {
      succeeded = false;
    }
  }
  return succeeded;
}
