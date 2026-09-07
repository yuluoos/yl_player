# Player v0.2 Dart API and Platform SPI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the v0.1 app API and handwritten platform contract with the approved explicit Player/Playback Session API, structurally equal domain values, safe failures, source assessment, and a reusable SPI conformance kit while keeping Android, iOS, and macOS runnable through a temporary legacy-channel adapter.

**Architecture:** Public domain values live in yl_player_platform_interface, the handwritten SPI accepts only those values, and yl_player owns lifecycle orchestration and session milestone futures. Endorsed packages temporarily adapt the existing version-1 MethodChannel/EventChannel protocol to the new SPI. The adapter is deliberately conservative: exact managed networking, bounded buffering, and hardware-required loads are rejected until their typed native implementations land.

**Tech Stack:** Dart 3.12, Flutter 3.44, plugin_platform_interface 2.1.8, flutter_test, existing MethodChannel/EventChannel transport.

**Spec:** docs/superpowers/specs/2026-09-06-player-v2-architecture-design.md

## Global Constraints

- Run every command from /Users/yy2021_8689/Desktop/Flutter/yl_player unless a step changes directory explicitly.
- Before Task 1, resolve the existing 11-file dirty baseline with the user. Never stash, reset, overwrite, or silently include it. The protected files are:
  - packages/yl_player/example/integration_test/macos_network_mkv_playback_test.dart
  - packages/yl_player/example/macos/RunnerTests/YlMacosFallbackTests.swift
  - packages/yl_player_macos/macos/yl_player_macos/Sources/yl_player_macos/YlAudioRenderer.swift
  - packages/yl_player_macos/macos/yl_player_macos/Sources/yl_player_macos/YlAvPlayerBackend.swift
  - packages/yl_player_macos/macos/yl_player_macos/Sources/yl_player_macos/YlDisplayTimer.swift
  - packages/yl_player_macos/macos/yl_player_macos/Sources/yl_player_macos/YlFallbackBackend.swift
  - packages/yl_player_macos/macos/yl_player_macos/Sources/yl_player_macos/YlFrameScheduler.swift
  - packages/yl_player_macos/macos/yl_player_macos/Sources/yl_player_macos/YlMediaClock.swift
  - packages/yl_player_macos/macos/yl_player_macos/Sources/yl_player_macos/YlVideoToolboxDecoder.swift
  - packages/yl_player_platform_interface/lib/src/channel/channel_player.dart
  - packages/yl_player_platform_interface/test/channel_player_test.dart
- If those files remain dirty, stop before editing any of them and request an explicit checkpoint decision. A commit is preferred because all baseline gates already passed, but this plan does not authorize committing user-owned work.
- Minimum versions remain Dart 3.12 and Flutter 3.44.
- No generated transport type, MethodChannel, EventChannel, wire map, validation helper, or platform registration class may be exported by package:yl_player/yl_player.dart.
- Every public value implements structural equality, hashCode, and a safe toString. A toString must never include a URI, path, header value, credential name/value, query, user-info, or native stack.
- Explicit YlNetworkPolicy.managed, YlBufferStrategy.bounded, and YlDecoderPolicy.hardwareRequired requests are either proven and honored or rejected with policy.unsupported. The temporary adapter rejects them.
- Load completes after session commit, not Ready or First Frame. Ready and First Frame remain separate correlated futures.
- A stale or stopped session must fail before a native command is sent.
- A rejected command must not mutate healthy state or synthesize a failure event.
- Each behavioral change follows red-green-refactor and ends in the focused commit shown below.

---

## File and Responsibility Map

- Replace packages/yl_player_platform_interface/lib/src/configuration.dart with:
  - src/options/player_options.dart
  - src/options/load_options.dart
  - src/options/policies.dart
  - src/options/video_constraints.dart
- Replace packages/yl_player_platform_interface/lib/src/media_source.dart with:
  - src/source/media_source.dart
  - src/source/http_request.dart
- Replace the current state/error/track/metric files with:
  - src/model/identifiers.dart
  - src/model/failure.dart
  - src/model/capabilities.dart
  - src/model/source_assessment.dart
  - src/model/timeline.dart
  - src/model/video_geometry.dart
  - src/model/media_track.dart
  - src/model/playback_metrics.dart
  - src/model/player_state.dart
  - src/model/player_event.dart
- Replace src/platform_player.dart and src/player_platform.dart with:
  - src/platform/platform_implementation_info.dart
  - src/platform/platform_load_result.dart
  - src/platform/platform_player.dart
  - src/platform/player_platform.dart
- Create src/testing/platform_conformance.dart and expose it only through lib/testing.dart.
- Rewrite src/channel/channel_codec.dart and src/channel/channel_player.dart as the temporary v0.1-wire-to-v0.2-SPI adapter; expose it only through lib/yl_player_legacy_transport.dart.
- Replace packages/yl_player/lib/src/player_controller.dart and add lib/src/playback_session.dart.
- Update the three endorsed Dart registration files and the main example to consume the new contract.

---

### Task 1: Add equality, identifiers, safe failures, and redaction

**Files:**
- Create: packages/yl_player_platform_interface/lib/src/model/value_helpers.dart
- Create: packages/yl_player_platform_interface/lib/src/model/identifiers.dart
- Create: packages/yl_player_platform_interface/lib/src/model/failure.dart
- Create: packages/yl_player_platform_interface/lib/src/diagnostics/safe_diagnostics.dart
- Create: packages/yl_player_platform_interface/test/failure_test.dart
- Modify: packages/yl_player_platform_interface/lib/yl_player_platform_interface.dart

**Interfaces:**
- Produces YlPlaybackSessionId, YlFailure, YlPlayerException, YlFailureCategory, YlFailureScope, YlFailureCodes, and YlSafeDiagnostics.
- YlPlaybackSessionId.value is a non-empty opaque String. Its toString is YlPlaybackSessionId(<redacted>).
- YlFailure.toString contains only category, code, retryable, scope, and diagnosticId.
- YlPlayerException.toString delegates only to the safe YlFailure string.

- [ ] **Step 1: Write failing value and leakage tests**

Create failure_test.dart with these cases:

~~~dart
test('session ids and failures use structural equality', () {
  const a = YlPlaybackSessionId('native-7');
  const b = YlPlaybackSessionId('native-7');
  expect(a, b);
  expect(a.hashCode, b.hashCode);

  const first = YlFailure(
    category: YlFailureCategory.network,
    code: YlFailureCodes.networkFailed,
    message: 'Playback request failed.',
    retryable: true,
    scope: YlFailureScope.session,
    diagnosticId: 'diag-42',
  );
  expect(first, const YlFailure(
    category: YlFailureCategory.network,
    code: YlFailureCodes.networkFailed,
    message: 'Playback request failed.',
    retryable: true,
    scope: YlFailureScope.session,
    diagnosticId: 'diag-42',
  ));
});

test('public strings never expose sensitive input', () {
  const secret = 'https://user:pass@example.test/a.m3u8?token=secret';
  final failure = YlFailure(
    category: YlFailureCategory.internal,
    code: YlFailureCodes.internal,
    message: YlSafeDiagnostics.publicMessage(secret),
    retryable: false,
    scope: YlFailureScope.player,
    diagnosticId: 'diag-1',
  );
  final text = <String>[
    failure.toString(),
    YlPlayerException(failure).toString(),
    const YlPlaybackSessionId(secret).toString(),
  ].join(' ');
  expect(text, isNot(contains('secret')));
  expect(text, isNot(contains('user:pass')));
  expect(text, isNot(contains('example.test')));
});

test('redaction removes URL, query, header, and bearer shapes', () {
  final redacted = YlSafeDiagnostics.redact(
    'GET https://media.test/a?token=abc '
    'Authorization: Bearer xyz Cookie: sid=123 X-Api-Key: value',
  );
  expect(redacted, isNot(contains('media.test')));
  expect(redacted, isNot(contains('abc')));
  expect(redacted, isNot(contains('xyz')));
  expect(redacted, isNot(contains('123')));
  expect(redacted, isNot(contains('value')));
});
~~~

- [ ] **Step 2: Prove the tests fail**

Run:

~~~bash
flutter test packages/yl_player_platform_interface/test/failure_test.dart
~~~

Expected: compilation fails because all v0.2 identifier, failure, and diagnostic symbols are missing.

- [ ] **Step 3: Implement the minimal safe value layer**

Use these exact public enums and codes:

~~~dart
enum YlFailureCategory {
  cancelled,
  unsupported,
  source,
  network,
  container,
  decoder,
  render,
  resource,
  protocol,
  platform,
  internal,
}

enum YlFailureScope { command, session, player }

abstract final class YlFailureCodes {
  static const playerDisposed = 'player.disposed';
  static const platformUnavailable = 'platform.unavailable';
  static const platformIncompatible = 'platform.incompatible';
  static const loadCancelled = 'load.cancelled';
  static const sessionStale = 'session.stale';
  static const policyUnsupported = 'policy.unsupported';
  static const sourceInvalid = 'source.invalid';
  static const sourceMissing = 'source.missing';
  static const networkFailed = 'network.failed';
  static const containerUnsupported = 'container.unsupported';
  static const decoderUnsupported = 'decoder.unsupported';
  static const decoderUnavailable = 'decoder.unavailable';
  static const resourceExhausted = 'resource.exhausted';
  static const protocolMismatch = 'protocol.mismatch';
  static const platformFailure = 'platform.failure';
  static const internal = 'internal.failure';
}
~~~

Implement handwritten Object.hash equality. Reject an empty YlPlaybackSessionId.value with ArgumentError at the boundary that creates it. Its toString must never print value. Implement redaction in this order: replace URI-like tokens; replace case-insensitive Authorization, Proxy-Authorization, Cookie, Set-Cookie, and any header whose name contains token, key, secret, credential, or auth; remove query fragments; then cap output at 512 characters. publicMessage returns a fixed Playback operation failed. string whenever the input contains a URI, header, credential, newline, or stack-frame shape.

- [ ] **Step 4: Format and pass**

Run:

~~~bash
dart format packages/yl_player_platform_interface/lib/src/model packages/yl_player_platform_interface/lib/src/diagnostics packages/yl_player_platform_interface/test/failure_test.dart
flutter test packages/yl_player_platform_interface/test/failure_test.dart
~~~

Expected: all tests pass.

- [ ] **Step 5: Commit**

~~~bash
git add packages/yl_player_platform_interface/lib/src/model packages/yl_player_platform_interface/lib/src/diagnostics packages/yl_player_platform_interface/lib/yl_player_platform_interface.dart packages/yl_player_platform_interface/test/failure_test.dart
git commit -m "feat: add safe player failure values"
~~~

### Task 2: Replace source, request, and policy models

**Files:**
- Create: packages/yl_player_platform_interface/lib/src/source/http_request.dart
- Create: packages/yl_player_platform_interface/lib/src/source/media_source.dart
- Create: packages/yl_player_platform_interface/lib/src/options/policies.dart
- Create: packages/yl_player_platform_interface/lib/src/options/video_constraints.dart
- Create: packages/yl_player_platform_interface/lib/src/options/player_options.dart
- Create: packages/yl_player_platform_interface/lib/src/options/load_options.dart
- Rewrite: packages/yl_player_platform_interface/lib/src/validation.dart
- Create: packages/yl_player_platform_interface/test/source_and_policy_test.dart
- Modify: packages/yl_player_platform_interface/lib/yl_player_platform_interface.dart

**Interfaces:**
- Produces sealed YlMediaSource with YlFileSource, YlNetworkSource, and YlAndroidContentSource.
- Produces YlHttpRequest with immutable headers and credentials maps.
- Produces YlStreamIntent, YlMediaFormat, YlNetworkPolicy, YlBufferStrategy, YlDecoderPolicy, YlAudioPolicy, YlVideoConstraints, YlPlayerOptions, and YlLoadOptions.
- validateYlSource, validateYlPlayerOptions, validateYlLoadOptions, validateYlVolume, validateYlPlaybackSpeed, validateYlSeekPosition, and validateYlTrackId throw ArgumentError before a platform call.

- [ ] **Step 1: Write failing source and strict-policy tests**

Add table-driven tests covering:

~~~dart
test('network source separates headers from same-origin credentials', () {
  final source = YlNetworkSource(
    Uri.parse('https://media.test/live.m3u8'),
    intent: YlStreamIntent.live,
    format: YlMediaFormat.hls,
    request: YlHttpRequest(
      headers: <String, String>{'User-Agent': 'yl-test'},
      credentials: <String, String>{'X-Api-Key': 'secret'},
    ),
  );
  expect(source.request.headers, {'User-Agent': 'yl-test'});
  expect(source.request.credentials, {'X-Api-Key': 'secret'});
  expect(source.toString(), isNot(contains('media.test')));
  expect(source.toString(), isNot(contains('secret')));
});

test('rejects ambiguous or unsafe network requests', () {
  expect(
    () => validateYlSource(YlNetworkSource(Uri.parse('ftp://media.test/a'))),
    throwsArgumentError,
  );
  expect(
    () => validateYlSource(
      YlNetworkSource(Uri.parse('https://user:pass@media.test/a')),
    ),
    throwsArgumentError,
  );
  expect(
    () => validateYlSource(YlNetworkSource(
      Uri.parse('https://media.test/a'),
      request: YlHttpRequest(
        headers: <String, String>{'Authorization': 'Bearer secret'},
      ),
    )),
    throwsArgumentError,
  );
});

test('bounded buffers require a coherent exact budget', () {
  expect(
    () => validateYlLoadOptions(const YlLoadOptions(
      bufferStrategy: YlBufferStrategy.bounded(
        minDuration: Duration(seconds: 2),
        maxDuration: Duration(seconds: 1),
        maxManagedBytes: 1024,
      ),
    )),
    throwsArgumentError,
  );
});
~~~

Also test absolute non-empty file paths, content scheme, CR/LF in header names or values, forbidden Host/Content-Length/Connection/Transfer-Encoding/Range headers, Authorization/Cookie in ordinary headers, duplicate names across headers and credentials ignoring case, start position >= zero, volume 0...1, speed 0.25...4, and every duration/int fitting signed 32-bit native milliseconds/bytes.

- [ ] **Step 2: Prove the focused suite fails**

Run:

~~~bash
flutter test packages/yl_player_platform_interface/test/source_and_policy_test.dart
~~~

Expected: compilation fails because the sealed source and v0.2 policy types do not exist.

- [ ] **Step 3: Implement the exact model surface**

Use these enum values:

~~~dart
enum YlStreamIntent { automatic, onDemand, live }

enum YlMediaFormat {
  automatic,
  hls,
  mp4,
  mov,
  matroska,
  webm,
  mpegTs,
  mpegPs,
  flv,
  avi,
}

enum YlDecoderPolicy { systemDefault, hardwarePreferred, hardwareRequired }
enum YlAudioPolicy { appManaged, pluginManagedMediaPlayback }
enum YlNetworkPolicyKind { platformDefault, managed }
enum YlBufferStrategyKind { automatic, lowLatency, smoothPlayback, bounded }
~~~

YlNetworkPolicy has const constructors platformDefault() and managed(...) with managed fields connectTimeout, readTimeout, maxRetries, baseRetryDelay, maxRetryDelay, and maxRedirects. YlBufferStrategy has const constructors automatic(), lowLatency(), smoothPlayback(), and bounded(...) with minDuration, maxDuration, and maxManagedBytes. Fields not used by the selected kind are null.

YlPlayerOptions fields are decoderPolicy, audioPolicy, and positionUpdateInterval. Defaults are hardwarePreferred, appManaged, and 250 ms. YlLoadOptions fields are autoplay, startPosition, bufferStrategy, videoConstraints, and decoderPolicyOverride. Defaults are false, null, automatic, unconstrained, and null.

YlNetworkSource owns its YlNetworkPolicy because fetch guarantees are source-specific. YlFileSource accepts a String absolute path. YlAndroidContentSource accepts a content URI. Every source carries intent and format, except file intent is fixed to onDemand.

Copy input maps into UnmodifiableMapView. Implement structural map equality by sorted lower-case keys without changing the caller-visible spelling. Forbid case-insensitive header collisions and the exact reserved set host, content-length, connection, transfer-encoding, and range. Require Authorization, Proxy-Authorization, Cookie, and custom credential-bearing values to be placed in credentials.

- [ ] **Step 4: Delete the superseded v0.1 model files and update exports**

Delete configuration.dart and media_source.dart only after all imports use the new files. Do not add deprecated typedefs or runtime compatibility constructors. Export domain types and validators from yl_player_platform_interface.dart; validators will be hidden by the app-facing barrel in Task 8.

- [ ] **Step 5: Format, test, and commit**

Run:

~~~bash
dart format packages/yl_player_platform_interface/lib packages/yl_player_platform_interface/test/source_and_policy_test.dart
flutter test packages/yl_player_platform_interface/test/source_and_policy_test.dart
flutter analyze packages/yl_player_platform_interface
~~~

Expected: all commands pass.

~~~bash
git add packages/yl_player_platform_interface
git commit -m "feat: define v0.2 sources and policies"
~~~

### Task 3: Add capabilities, assessment, state, events, geometry, tracks, and metrics

**Files:**
- Create: packages/yl_player_platform_interface/lib/src/model/capabilities.dart
- Create: packages/yl_player_platform_interface/lib/src/model/source_assessment.dart
- Create: packages/yl_player_platform_interface/lib/src/model/timeline.dart
- Create: packages/yl_player_platform_interface/lib/src/model/video_geometry.dart
- Create: packages/yl_player_platform_interface/lib/src/model/media_track.dart
- Create: packages/yl_player_platform_interface/lib/src/model/playback_metrics.dart
- Create: packages/yl_player_platform_interface/lib/src/model/player_state.dart
- Create: packages/yl_player_platform_interface/lib/src/model/player_event.dart
- Create: packages/yl_player_platform_interface/test/state_models_test.dart
- Delete after migration: packages/yl_player_platform_interface/lib/src/capabilities.dart
- Delete after migration: packages/yl_player_platform_interface/lib/src/media_track.dart
- Delete after migration: packages/yl_player_platform_interface/lib/src/playback_metrics.dart
- Delete after migration: packages/yl_player_platform_interface/lib/src/player_state.dart
- Delete after migration: packages/yl_player_platform_interface/lib/src/player_event.dart

**Interfaces:**
- Produces immutable capabilities and source-assessment values.
- Produces YlPlayerState with revision and session correlation.
- Produces only first-frame, retry-scheduled, engine-changed, and playback-failed events.
- Replaces isHardwareDecoding with YlDecoderMode.unknown/hardware/software.
- Every common metric is nullable; null means unmeasured or unsupported and zero means measured zero.

- [ ] **Step 1: Write failing structural and semantic tests**

Use this canonical state fixture:

~~~dart
final state = YlPlayerState(
  revision: 7,
  sessionId: const YlPlaybackSessionId('session-1'),
  status: YlPlaybackStatus.playing,
  timeline: const YlTimeline(
    position: Duration(seconds: 3),
    duration: Duration(minutes: 1),
    bufferedPosition: Duration(seconds: 8),
    isSeekable: true,
    isLive: false,
  ),
  videoGeometry: const YlVideoGeometry(
    encodedSize: YlPixelSize(1920, 1088),
    displaySize: YlPixelSize(1920, 1080),
    pixelAspectRatio: 1,
    rotationDegrees: 0,
  ),
  engine: YlPlaybackEngine.media3,
  decoderMode: YlDecoderMode.hardware,
  decoderIdentity: 'c2.android.avc.decoder',
  metrics: const YlPlaybackMetrics(rebufferCount: 0),
);

test('equal snapshots have equal hashes and derived aspect ratio', () {
  expect(state, state.copyWith());
  expect(state.hashCode, state.copyWith().hashCode);
  expect(state.videoGeometry!.displayAspectRatio, closeTo(16 / 9, 0.0001));
});

test('metrics distinguish unknown from measured zero', () {
  expect(const YlPlaybackMetrics().rebufferCount, isNull);
  expect(const YlPlaybackMetrics(rebufferCount: 0).rebufferCount, 0);
});

test('events always carry session, revision, and timestamp', () {
  const event = YlFirstFrameEvent(
    sessionId: YlPlaybackSessionId('session-1'),
    revision: 8,
    occurredAt: Duration(milliseconds: 1234),
  );
  expect(event.sessionId.value, 'session-1');
  expect(event.revision, 8);
});
~~~

Add tests for copyWith explicitly clearing nullable values, defensive collection copies, rotation limited to 0/90/180/270, positive sizes and pixel aspect, DVR ordering, monotonically valid nonnegative revision, no capabilities field in YlPlayerState, no Android tier or selected bitrate in metrics, and safe toString output.

- [ ] **Step 2: Run and observe the missing-type failure**

Run:

~~~bash
flutter test packages/yl_player_platform_interface/test/state_models_test.dart
~~~

Expected: compilation fails on the new state and event constructors.

- [ ] **Step 3: Implement the exact state vocabulary**

Use:

~~~dart
enum YlPlaybackStatus {
  idle,
  loading,
  ready,
  playing,
  paused,
  buffering,
  completed,
  failed,
}

enum YlPlaybackEngine { unknown, media3, avPlayer, managedFallback }
enum YlDecoderMode { unknown, hardware, software }
enum YlDecoderEvidence { none, hardwareOnly, hardwareAndSoftware }
enum YlTrackKind { audio, video }
enum YlSourceAssessmentOutcome { compatible, incompatible, requiresInspection }
enum YlPlayerOperation {
  seek,
  seekToLiveEdge,
  playbackSpeed,
  audioTrackSelection,
  videoConstraints,
  volume,
  stop,
}
~~~

YlPlayerCapabilities fields are implementationName, implementationVersion, deviceProfile, availableEngines, supportedOperations, decoderEvidence, hardwareVideoCodecs, maxConcurrentVideoDecoders, maxWidth, and maxHeight. Keep every collection immutable. decoderEvidence describes whether the implementation can positively distinguish no mode, hardware only, or both hardware and software.

YlSourceAssessment fields are outcome, candidateEngine, satisfiedRequirements, limitations, and rejection. satisfiedRequirements and limitations are immutable List<String>; rejection is a nullable YlFailure and is required only for incompatible.

YlTimeline fields are position, duration, bufferedPosition, isSeekable, isLive, isAtLiveEdge, liveOffset, and dvrWindow. YlDvrWindow contains start and end. YlVideoGeometry contains encodedSize, displaySize, pixelAspectRatio, and rotationDegrees. displaySize is the clean-aperture size before unapplied rotation; rotationDegrees is the clockwise rotation still required at the Flutter view. Native code reports zero after it has already oriented the pixels. displayAspectRatio applies pixelAspectRatio and then inverts for 90/270-degree rotation.

YlPlaybackMetrics has nullable loadToReady, loadToFirstFrame, rebufferCount, rebufferDuration, droppedVideoFrames, audioUnderruns, estimatedBitrate, managedBufferedDuration, managedBufferedBytes, liveOffset, and reconnectCount.

YlMediaTrack retains id, kind, label, language, codec, bitrate, width, height, and isSelected. Selected bitrate stays on the selected video track.

YlPlayerState fields are revision, sessionId, status, timeline, videoGeometry, audioTracks, videoTracks, engine, decoderMode, decoderIdentity, metrics, and failure.

Use Duration since an implementation-local monotonic epoch for event occurredAt; this avoids wall-clock ordering and timezone semantics.

- [ ] **Step 4: Implement only the approved event set**

Define sealed YlPlayerEvent plus YlFirstFrameEvent, YlRetryScheduledEvent, YlPlaybackEngineChangedEvent, and YlPlaybackFailedEvent. All subclasses require sessionId, revision, and occurredAt. Delete YlTracksChangedEvent and YlFallbackEvent; engine transitions become YlPlaybackEngineChangedEvent and tracks remain state.

- [ ] **Step 5: Format, pass, and commit**

Run:

~~~bash
dart format packages/yl_player_platform_interface/lib packages/yl_player_platform_interface/test/state_models_test.dart
flutter test packages/yl_player_platform_interface/test/state_models_test.dart
flutter analyze packages/yl_player_platform_interface
~~~

Expected: all commands pass.

~~~bash
git add packages/yl_player_platform_interface
git commit -m "feat: add correlated player state models"
~~~

### Task 4: Replace the platform SPI and publish a conformance runner

**Files:**
- Create: packages/yl_player_platform_interface/lib/src/platform/platform_implementation_info.dart
- Create: packages/yl_player_platform_interface/lib/src/platform/platform_load_result.dart
- Create: packages/yl_player_platform_interface/lib/src/platform/platform_player.dart
- Create: packages/yl_player_platform_interface/lib/src/platform/player_platform.dart
- Create: packages/yl_player_platform_interface/lib/src/testing/platform_conformance.dart
- Create: packages/yl_player_platform_interface/lib/testing.dart
- Create: packages/yl_player_platform_interface/test/platform_conformance_test.dart
- Rewrite: packages/yl_player_platform_interface/test/player_platform_test.dart
- Delete: packages/yl_player_platform_interface/lib/src/platform_player.dart
- Delete: packages/yl_player_platform_interface/lib/src/player_platform.dart

**Interfaces:**
- Produces ylPlayerSpiMajor = 2 and YlPlatformImplementationInfo.
- YlPlayerPlatform.createPlayer accepts YlPlayerOptions.
- YlPlatformPlayer owns non-null capabilities, texture identity, state and event routes, source assessment, load, session-scoped commands, player volume, stop, and idempotent disposal.
- Produces a framework-agnostic YlPlatformConformance runner that returns named failures rather than importing flutter_test in public library code.

- [ ] **Step 1: Write the failing SPI contract test**

Use this exact contract:

~~~dart
abstract interface class YlPlatformPlayer {
  YlPlatformImplementationInfo get implementation;
  YlPlayerCapabilities get capabilities;
  ValueListenable<int?> get textureId;
  YlPlayerState get state;
  Stream<YlPlayerState> get states;
  Stream<YlPlayerEvent> get events;
  Future<YlSourceAssessment> assess(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  });
  Future<YlPlatformLoadResult> load(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  });
  Future<void> play(YlPlaybackSessionId sessionId);
  Future<void> pause(YlPlaybackSessionId sessionId);
  Future<void> seekTo(YlPlaybackSessionId sessionId, Duration position);
  Future<void> seekToLiveEdge(YlPlaybackSessionId sessionId);
  Future<void> setPlaybackSpeed(YlPlaybackSessionId sessionId, double speed);
  Future<void> selectAudioTrack(
    YlPlaybackSessionId sessionId,
    String trackId,
  );
  Future<void> setVideoConstraints(
    YlPlaybackSessionId sessionId,
    YlVideoConstraints constraints,
  );
  Future<void> setVolume(double volume);
  Future<void> stop();
  Future<void> dispose();
}
~~~

YlPlatformLoadResult has one required sessionId. The player state/event routes are authoritative for all other load progress.

Test that assigning a class with the proper PlatformInterface token succeeds, mocking with MockPlatformInterfaceMixin succeeds, a foreign implementation fails token verification, and the unsupported default throws YlPlayerException with platform.unavailable.

- [ ] **Step 2: Prove the old SPI fails**

Run:

~~~bash
flutter test packages/yl_player_platform_interface/test/player_platform_test.dart
~~~

Expected: compilation fails because createPlayer still accepts YlPlayerConfiguration and session-scoped methods have no session ID.

- [ ] **Step 3: Implement the SPI and runtime handshake**

YlPlatformImplementationInfo fields are name, version, and spiMajor. YlPlayerController will require spiMajor == ylPlayerSpiMajor. Do not put transport version in this type.

The unsupported platform implementation throws:

~~~dart
YlPlayerException(const YlFailure(
  category: YlFailureCategory.platform,
  code: YlFailureCodes.platformUnavailable,
  message: 'No yl_player platform implementation is registered.',
  retryable: false,
  scope: YlFailureScope.player,
  diagnosticId: 'platform-unavailable',
))
~~~

- [ ] **Step 4: Add the conformance adapter and runner**

Define:

~~~dart
abstract interface class YlPlatformConformanceFixture {
  YlMediaSource get source;
  Future<YlPlatformPlayer> createPlayer();
  Future<void> emitReady(
    YlPlatformPlayer player,
    YlPlaybackSessionId sessionId,
  );
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
  const YlConformanceFailure(this.caseName, this.error);
  final String caseName;
  final Object error;
}

final class YlPlatformConformance {
  const YlPlatformConformance(this.fixture);
  final YlPlatformConformanceFixture fixture;
  Future<List<YlConformanceFailure>> run();
}
~~~

run executes isolated players for lifecycle, load identity, newer-load cancellation, stale-session rejection, stop, revision monotonicity, first-frame correlation, one terminal failure event, safe public strings, unsupported strict policy rejection, and double disposal. Each case catches its own error and returns a named failure; an empty result means conformant. It must never depend on package:test or flutter_test.

- [ ] **Step 5: Test the runner against a conformant and deliberately broken fake**

Run:

~~~bash
flutter test packages/yl_player_platform_interface/test/platform_conformance_test.dart packages/yl_player_platform_interface/test/player_platform_test.dart
~~~

Expected: the conformant fake returns an empty failure list; the broken fake reports at least stale-session and revision-order cases.

- [ ] **Step 6: Commit**

~~~bash
git add packages/yl_player_platform_interface
git commit -m "feat: publish player v2 platform spi"
~~~

### Task 5: Implement explicit controller creation and Playback Session handles

**Files:**
- Rewrite: packages/yl_player/lib/src/player_controller.dart
- Create: packages/yl_player/lib/src/playback_session.dart
- Rewrite: packages/yl_player/test/support/fake_player_platform.dart
- Rewrite: packages/yl_player/test/player_controller_test.dart
- Create: packages/yl_player/test/playback_session_test.dart

**Interfaces:**
- Produces await YlPlayerController.create(...).
- YlPlayerController implements Listenable without extending ChangeNotifier, because its public dispose returns Future<void>.
- Produces YlPlaybackSession.id, ready, firstFrame, and session-scoped commands.
- Controller owns assess, load, volume, stop, and dispose.

- [ ] **Step 1: Write failing explicit-creation tests**

Cover successful creation, platform create failure returned by create, SPI-major mismatch, initial capabilities available before return, no native creation triggered by reading state/texture/view, and stream attachment before create completes.

Use:

~~~dart
final controller = await YlPlayerController.create(
  options: const YlPlayerOptions(),
  platform: fakePlatform,
);
expect(controller.capabilities, fakePlatform.backend.capabilities);
expect(controller.state.status, YlPlaybackStatus.idle);
expect(fakePlatform.createCount, 1);
~~~

- [ ] **Step 2: Write failing load/session lifecycle tests**

Cover this exact sequence:

~~~dart
final firstLoad = controller.load(firstSource);
fakeBackend.commit(const YlPlaybackSessionId('s1'));
final first = await firstLoad;
expect(first.ready, doesNotComplete);

fakeBackend.emitState(sessionId: first.id, status: YlPlaybackStatus.ready);
await first.ready;
expect(first.firstFrame, doesNotComplete);

fakeBackend.emitFirstFrame(first.id);
await first.firstFrame;
await first.play();
expect(fakeBackend.lastCommand, ('play', first.id));

final secondLoad = controller.load(secondSource);
fakeBackend.commit(const YlPlaybackSessionId('s2'));
final second = await secondLoad;
await expectLater(first.pause(), throwsA(
  isA<YlPlayerException>().having(
    (error) => error.failure.code,
    'code',
    YlFailureCodes.sessionStale,
  ),
));
expect(second.id, const YlPlaybackSessionId('s2'));
~~~

Also cover a newer Load cancelling an older uncommitted Load, pre-commit failure retaining the old session, post-commit failure completing pending milestones with the new failure, stop invalidating the current session, player volume remaining usable without a session, double dispose sharing one Future, and post-dispose commands throwing player.disposed.

- [ ] **Step 3: Prove the controller suite fails**

Run:

~~~bash
flutter test packages/yl_player/test/player_controller_test.dart packages/yl_player/test/playback_session_test.dart
~~~

Expected: compilation fails because create is not static/async and YlPlaybackSession does not exist.

- [ ] **Step 4: Implement lifecycle orchestration**

Use an internal ChangeNotifier for addListener/removeListener delegation. Subscribe to platform state and events before the private constructor is returned. On every accepted state:

1. reject a lower revision;
2. replace state;
3. complete ready for a matching session when status is ready, playing, paused, buffering, or completed;
4. complete pending session futures with YlPlayerException when matching status is failed;
5. notify Listenable listeners once;
6. add the snapshot once to states.

Cache first-frame session IDs so an event arriving between native commit and Dart load completion still completes the returned session.

Before every session command, compare the handle ID to state.sessionId and ensure state is not idle/failed. On mismatch throw session.stale locally and do not call the backend.

Use an incrementing Dart load serial. A later load makes an earlier incomplete call finish with load.cancelled even if a broken implementation returns it later. The platform remains responsible for native candidate cancellation.

Dispose ordering is: mark terminal, invalidate pending sessions, cancel subscriptions, await backend.dispose best-effort, set texture null, close streams, dispose the internal notifier. Repeated calls return the same Future.

- [ ] **Step 5: Validate command/state authority**

Add a fake backend command failure and assert it propagates without changing state or emitting YlPlaybackFailedEvent. Add an authoritative native failed state plus event and assert exactly one state transition and one event are observed.

- [ ] **Step 6: Format, test, and commit**

Run:

~~~bash
dart format packages/yl_player/lib packages/yl_player/test
flutter test packages/yl_player/test/player_controller_test.dart packages/yl_player/test/playback_session_test.dart
flutter analyze packages/yl_player
~~~

Expected: all commands pass.

~~~bash
git add packages/yl_player/lib packages/yl_player/test
git commit -m "feat: add explicit player sessions"
~~~

### Task 6: Adapt the existing native wire without claiming strict-policy support

**Files:**
- Rewrite: packages/yl_player_platform_interface/lib/src/channel/channel_codec.dart
- Rewrite: packages/yl_player_platform_interface/lib/src/channel/channel_player.dart
- Replace: packages/yl_player_platform_interface/lib/yl_player_channel.dart
- Create: packages/yl_player_platform_interface/lib/yl_player_legacy_transport.dart
- Rewrite: packages/yl_player_platform_interface/test/channel_codec_test.dart
- Rewrite: packages/yl_player_platform_interface/test/channel_player_test.dart
- Modify: packages/yl_player_android/lib/yl_player_android.dart
- Modify: packages/yl_player_ios/lib/yl_player_ios.dart
- Modify: packages/yl_player_macos/lib/yl_player_macos.dart
- Modify: packages/yl_player_android/test/yl_player_android_test.dart
- Modify: packages/yl_player_ios/test/yl_player_ios_test.dart
- Modify: packages/yl_player_macos/test/yl_player_macos_test.dart

**Interfaces:**
- Produces createYlLegacyChannelPlayer for endorsed packages only.
- Maps legacy source generation to deterministic YlPlaybackSessionId values of legacy:<platform>:<playerId>:<generation>.
- Discards legacy platformDiagnostic values and generates a safe diagnostic ID.
- Rejects strict managed-network, bounded-buffer, and hardware-required requests with policy.unsupported before invoking open.

- [ ] **Step 1: Preserve and port the dirty fallback-marker regression**

The current uncommitted test named native fallback activation marker does not terminate the channel must remain present and passing after the rewrite. Port it to expect no public event and to rely on the following authoritative engine-changed state/event only.

- [ ] **Step 2: Write failing adapter semantics tests**

Add tests for:

- create waits for the first full state/capability snapshot and times out as protocol.mismatch;
- protocol version other than 1 rejects creation;
- generation 3 maps to legacy:android:7:3;
- load returns only after a full state for a newer generation is observed;
- first-frame, retry, and error legacy events are correlated to the current session;
- stale generation deltas and events are ignored;
- managed, bounded, and hardwareRequired assessment is incompatible and load sends no method call;
- a PlatformException detail containing a secret URL produces a safe YlPlayerException;
- stop emits the command but clears the adapter session only after the authoritative idle state;
- dispose remains idempotent.

- [ ] **Step 3: Prove failures**

Run:

~~~bash
flutter test packages/yl_player_platform_interface/test/channel_codec_test.dart packages/yl_player_platform_interface/test/channel_player_test.dart
~~~

Expected: old decoded types and methods do not satisfy the v0.2 SPI, and strict requirements currently pass through.

- [ ] **Step 4: Implement the temporary bridge**

Keep protocolVersion = 1. Decode capabilities out of the first full state but never repeat them in public playback state. Convert AVPlayer legacy isHardwareDecoding false to YlDecoderMode.unknown. Convert Media3 true to hardware and false to unknown; software is asserted only when native provides an explicit software decoder marker.

Track the latest accepted generation and revision. The legacy wire has no revision, so increment one for every accepted full snapshot or delta. Never increment for ignored envelopes. Correlate unversioned first-frame/retry/failure events to the current generation only; this limitation is temporary and must be removed by the Android and Apple typed-transport plans.

For default-policy source assessment, return requiresInspection unless the route can be determined from source kind and format without inspecting content. For every explicit strict requirement, return incompatible with policy.unsupported. load always runs assess first.

Rename the explicit entrypoint to yl_player_legacy_transport.dart and add a deprecation comment stating it is removed before v0.2 publication. Do not export it from yl_player_platform_interface.dart or yl_player.dart.

- [ ] **Step 5: Update all three Dart registrations**

Each registerWith assigns the new YlPlayerPlatform singleton. createPlayer accepts YlPlayerOptions and delegates to createYlLegacyChannelPlayer with its existing channel names and initial engine. Keep dependency injection of MethodChannel, EventChannel, and nativeEvents for tests.

- [ ] **Step 6: Test and commit**

Run:

~~~bash
dart format packages/yl_player_platform_interface packages/yl_player_android/lib packages/yl_player_android/test packages/yl_player_ios/lib packages/yl_player_ios/test packages/yl_player_macos/lib packages/yl_player_macos/test
flutter test packages/yl_player_platform_interface/test
flutter test packages/yl_player_android/test
flutter test packages/yl_player_ios/test
flutter test packages/yl_player_macos/test
~~~

Expected: all tests pass.

~~~bash
git add packages/yl_player_platform_interface packages/yl_player_android/lib packages/yl_player_android/test packages/yl_player_ios/lib packages/yl_player_ios/test packages/yl_player_macos/lib packages/yl_player_macos/test
git commit -m "refactor: bridge native v1 transport to player v2"
~~~

### Task 7: Add real Stop behavior to the temporary native implementations

**Files:**
- Modify: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3Player.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlStopPolicy.kt
- Create: packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlStopPolicyTest.kt
- Modify: packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlPlaybackBackend.swift
- Modify: packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlIosPlayer.swift
- Modify: packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlAvPlayerBackend.swift
- Modify: packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackBackend.swift
- Modify: packages/yl_player_macos/macos/yl_player_macos/Sources/yl_player_macos/YlPlaybackBackend.swift
- Modify: packages/yl_player_macos/macos/yl_player_macos/Sources/yl_player_macos/YlMacosPlayer.swift
- Modify: packages/yl_player_macos/macos/yl_player_macos/Sources/yl_player_macos/YlAvPlayerBackend.swift
- Modify: packages/yl_player_macos/macos/yl_player_macos/Sources/yl_player_macos/YlFallbackBackend.swift
- Modify: packages/yl_player/example/ios/RunnerTests/RunnerTests.swift
- Modify: packages/yl_player/example/macos/RunnerTests/RunnerTests.swift

**Interfaces:**
- Existing legacy command name stop becomes supported.
- Stop cancels pending open/retry/recovery, clears the current media, resets metrics/tracks/geometry/failure, emits one idle full state, and retains texture/native player identity.

- [ ] **Step 1: Write failing native policy tests**

Extract a pure YlStopPolicy on Android returning an idle state-reset decision and add a test that it clears session data without disposing texture identity. On Apple, add fake YlPlaybackBackend tests proving stop is distinct from deactivate and dispose.

- [ ] **Step 2: Run and observe failure**

Run:

~~~bash
cd packages/yl_player_android/example/android
./gradlew testDebugUnitTest --tests '*YlStopPolicyTest' --stacktrace
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
sh tool/check_native_ios.sh
~~~

Expected: Android cannot resolve YlStopPolicy and the Apple fake backend does not implement stop.

- [ ] **Step 3: Implement Android stop**

Add the stop branch to YlMedia3Player.command. It must cancel callbacks/watchdogs, increment sourceGeneration to invalidate old callbacks, pause, stop, clearMediaItems, detach or clear the video surface without releasing the texture, clear track selections and metrics, set status to idle, and emit one full state. Do not deactivate peers or change activePlayerId for stop; the typed coordinator replaces that policy in the Android plan.

- [ ] **Step 4: Implement Apple stop**

Add func stop() to YlPlaybackBackend. Both AVPlayer and fallback implementations cancel pending async work, invalidate their generation, clear media/pixel buffers, and emit idle without unregistering the Flutter texture. YlIosPlayer and YlMacosPlayer cancel their open coordinator then call the current backend stop; a stopped candidate cannot later commit.

- [ ] **Step 5: Run native gates and commit**

Run:

~~~bash
cd packages/yl_player_android/example/android
./gradlew testDebugUnitTest --stacktrace
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh --unit-only
~~~

Expected: Android JVM tests and Apple native/unit integration gates pass.

~~~bash
git add packages/yl_player_android/android packages/yl_player_ios/ios packages/yl_player_macos/macos packages/yl_player/example/ios/RunnerTests packages/yl_player/example/macos/RunnerTests
git commit -m "feat: add non-destructive player stop"
~~~

### Task 8: Switch the app barrel and examples to the breaking v0.2 API

**Files:**
- Rewrite: packages/yl_player/lib/yl_player.dart
- Rewrite: packages/yl_player/example/lib/main.dart
- Rewrite: packages/yl_player/example/test/widget_test.dart
- Rewrite all platform integration tests under: packages/yl_player/example/integration_test
- Rewrite: packages/yl_player/README.md
- Rewrite: packages/yl_player_platform_interface/README.md
- Delete after import migration: packages/yl_player_platform_interface/lib/yl_player_channel.dart
- Delete after import migration: superseded v0.1 model files listed in Tasks 2–4

**Interfaces:**
- package:yl_player/yl_player.dart exports only YlPlayerController, YlPlaybackSession, YlPlayerView, and app-useful domain values.
- It does not wildcard-export yl_player_platform_interface.
- Example startup awaits YlPlayerController.create before rendering the player view.

- [ ] **Step 1: Write the failing export-boundary test**

Create packages/yl_player/test/public_api_test.dart. Import only package:yl_player/yl_player.dart and instantiate every documented app-facing type. Add packages/yl_player/test/fixtures/platform_api_must_not_compile.dart importing the app barrel and referring to YlPlayerPlatform. Invoke dart analyze on that fixture from a test process and assert a non-zero exit containing undefined_identifier.

- [ ] **Step 2: Update the example to explicit async ownership**

Use a FutureBuilder or an initState-owned Future<YlPlayerController> that is created once. The minimal flow is:

~~~dart
final player = await YlPlayerController.create();
final session = await player.load(
  YlNetworkSource(
    Uri.parse(url),
    intent: isLive ? YlStreamIntent.live : YlStreamIntent.onDemand,
  ),
);
await session.play();
~~~

Dispose by awaiting player.dispose from an unawaited wrapper in State.dispose; do not create a player from build or a texture getter.

- [ ] **Step 3: Migrate every integration test**

Replace constructor/open with awaited create/load. Keep Ready and First Frame assertions separate. Replace direct controller play/pause/seek calls with session calls. Use player.stop when a test needs to end a source but reuse the native player.

- [ ] **Step 4: Restrict exports**

Use an explicit show list when re-exporting platform-interface domain types. Do not export YlPlayerPlatform, YlPlatformPlayer, YlPlatformLoadResult, YlPlatformImplementationInfo, validators, testing helpers, or legacy transport.

- [ ] **Step 5: Run the complete phase gate**

Run:

~~~bash
sh tool/check_foundation.sh
cd packages/yl_player_android/example/android
./gradlew testDebugUnitTest --stacktrace
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh
git diff --check
~~~

Expected: all automated Dart, Android, iOS Simulator, macOS unit/universal/Rosetta/integration checks pass; the intentional negative export fixture fails only inside its asserting test.

- [ ] **Step 6: Commit**

~~~bash
git add packages/yl_player packages/yl_player_platform_interface
git commit -m "feat!: expose player v0.2 api"
~~~

### Task 9: Self-review the phase boundary

**Files:**
- Create: docs/verification/player-v2-migration.md
- Modify only other files found defective by the checks below.

- [ ] **Step 1: Verify spec coverage**

Confirm with tests or code inspection that explicit creation, Load commit, Ready, First Frame, stale sessions, Stop, state revisions, event correlation, strict-policy rejection, safe diagnostics, structural equality, and third-party conformance all exist.

- [ ] **Step 2: Scan for forbidden legacy/public surface**

Run:

~~~bash
rg -n 'YlPlayerConfiguration|YlBufferMode|YlFormatHint|YlPlayerError|YlTracksChangedEvent|YlFallbackEvent|isHardwareDecoding|platformDiagnostic' packages --glob '*.dart'
rg -n 'MethodChannel|EventChannel|createYlLegacyChannelPlayer' packages/yl_player/lib packages/yl_player_platform_interface/lib/yl_player_platform_interface.dart
rg -n '[T]ODO|[F]IXME|[T]BD|[X]XX' docs/superpowers/plans/2026-09-06-player-v2-dart-api-and-spi.md
~~~

Expected: the first command finds old names only inside the explicitly temporary legacy adapter and migration documentation; the second and third find nothing.

- [ ] **Step 3: Verify type consistency and clean diff**

Run:

~~~bash
dart format --output=none --set-exit-if-changed packages
flutter analyze
git diff --check
git status --short
~~~

Expected: format, analysis, and diff checks pass. git status contains only intentional phase work and no lost baseline changes.

- [ ] **Step 4: Record the checkpoint**

Write docs/verification/player-v2-migration.md with the exact commands, outcomes, skipped physical-device evidence, and current commit. Commit only that verification document:

~~~bash
git add docs/verification/player-v2-migration.md
git commit -m "docs: record player v2 dart migration"
~~~
