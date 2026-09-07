# Player v0.2 Android Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Android's global handwritten channel protocol and eager peer deactivation with a private instance-scoped Pigeon transport, transactional Playback Session coordinator, honest strict-policy handling, and regression-tested Media3 integration.

**Architecture:** A small plugin entry owns a Player registry and Pigeon factory endpoint. Every created Player gets a unique channel suffix, typed host API, and typed Flutter callback API. SessionCoordinator constructs a candidate Media3 engine, DecoderLeaseCoordinator quiesces and restores scarce decoder owners transactionally, StateReducer owns session/revision/sequence ordering, and focused source/network/output/audio/metrics components wrap Media3.

**Tech Stack:** Flutter 3.44, Dart 3.12, Pigeon 28.0.0, Kotlin 2.3.20, Java 17, Android Gradle Plugin 9.0.1, Media3 1.11.0, OkHttp through media3-datasource-okhttp, Kotlin test and Mockito.

**Spec:** docs/superpowers/specs/2026-09-06-player-v2-architecture-design.md

## Global Constraints

- Complete docs/superpowers/plans/2026-09-06-player-v2-dart-api-and-spi.md first.
- Preserve all passing Media3 selector, load control, audio focus, surface restoration, lifecycle, health monitor, and stall watchdog behavior.
- Generated Dart and Kotlin files live only in yl_player_android. No generated type crosses into yl_player_platform_interface or yl_player.
- Every native callback and command is scoped by one Pigeon channel suffix. There is no process-wide event stream and no Dart-side filtering by numeric player ID.
- Every command, state snapshot, delta, and event carries a Playback Session ID when session-scoped.
- Full states and deltas carry validated revision and sequence values. A delta applies only when its previousRevision equals current revision and sequence is newer.
- Explicit managed network is accepted only for HTTP(S) routes built entirely by the managed OkHttp/Media3 stack.
- Explicit bounded buffer is rejected until an instrumented test proves the requested hard managed-byte ceiling. Default Media3 allocator target size is not a hard ceiling and must not be advertised as one.
- Explicit hardwareRequired for video commits only after MediaCodec initialization proves a hardware decoder. Codec-name heuristics alone are insufficient when API 29 hardwareAccelerated/softwareOnly evidence is available.
- Candidate failure before commit must leave the former Player/session authoritative and restorable.
- No public diagnostic contains a URI, query, header, credential, exception message, or stack.
- All Media3 and Android framework calls occur on the main looper unless a component explicitly documents a worker thread and hands immutable data back.

---

## File and Responsibility Map

- Pigeon:
  - Create packages/yl_player_android/pigeons/yl_player_android.dart.
  - Create generated lib/src/pigeon/yl_player_android.g.dart.
  - Create generated android/src/main/kotlin/dev/ylplayer/yl_player_android/pigeon/YlPlayerAndroid.g.kt.
  - Create tool/generate_pigeon.sh and tool/check_pigeon.sh.
- Dart adapter:
  - Rewrite lib/yl_player_android.dart.
  - Create lib/src/android_player.dart, android_codec.dart, android_transport.dart, and android_callbacks.dart.
- Native boundary:
  - Rewrite YlPlayerAndroidPlugin.kt as registration/lifecycle delegation only.
  - Create YlPlayerRegistry.kt and YlPigeonPlayerHost.kt.
- Coordination:
  - Create YlSessionCoordinator.kt, YlDecoderLeaseCoordinator.kt, YlStateReducer.kt, and YlSessionModels.kt.
- Engine:
  - Extract YlMedia3Engine.kt from YlMedia3Player.kt.
  - Create YlCandidateVideoOutput.kt for pre-commit hardware evidence without taking the public texture.
  - Keep and narrow YlAdaptiveLoadControl.kt, YlHardwareCodecSelector.kt, YlPlaybackPolicy.kt, YlPlaybackHealthMonitor.kt, YlPlaybackStallWatchdog.kt, YlFirstFrameGate.kt, YlLifecyclePolicy.kt, and YlVideoOutput.kt.
- Source/network:
  - Create YlSourceAssessment.kt, YlMediaSourceFactory.kt, YlManagedHttpClient.kt, YlOriginCredentialPolicy.kt, and YlManagedRedirectInterceptor.kt.
- Diagnostics/metrics:
  - Create YlFailureMapper.kt, YlSafeDiagnostics.kt, and YlMetricsCollector.kt.

---

### Task 1: Define and lock the private Pigeon schema

**Files:**
- Modify: packages/yl_player_android/pubspec.yaml
- Create: packages/yl_player_android/pigeons/yl_player_android.dart
- Create generated: packages/yl_player_android/lib/src/pigeon/yl_player_android.g.dart
- Create generated: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/pigeon/YlPlayerAndroid.g.kt
- Create: packages/yl_player_android/tool/generate_pigeon.sh
- Create: packages/yl_player_android/tool/check_pigeon.sh
- Create: packages/yl_player_android/test/pigeon_schema_test.dart

**Interfaces:**
- Produces schemaMajor = 2.
- Produces one factory HostApi, one per-instance Player HostApi, and one per-instance FlutterApi callback surface.
- Generated files are private package implementation details.

- [ ] **Step 1: Pin Pigeon and write a failing schema smoke test**

Add pigeon: 28.0.0 to dev_dependencies. The smoke test imports the generated library from src and constructs a create request, network source, bounded load option, full state, delta, and failure. It asserts no public yl_player or platform-interface barrel exports an Android-prefixed generated type.

Run:

~~~bash
flutter test packages/yl_player_android/test/pigeon_schema_test.dart
~~~

Expected: compilation fails because the schema and generated Dart library do not exist.

- [ ] **Step 2: Declare exact transport enums and records**

The Pigeon schema must declare these enums:

- AndroidSourceKind: file, network, content.
- AndroidStreamIntent: automatic, onDemand, live.
- AndroidMediaFormat: automatic, hls, mp4, mov, matroska, webm, mpegTs, mpegPs, flv, avi.
- AndroidNetworkPolicyKind: platformDefault, managed.
- AndroidBufferKind: automatic, lowLatency, smoothPlayback, bounded.
- AndroidDecoderPolicy: systemDefault, hardwarePreferred, hardwareRequired.
- AndroidAudioPolicy: appManaged, pluginManagedMediaPlayback.
- AndroidAssessmentOutcome: compatible, incompatible, requiresInspection.
- AndroidPlaybackStatus: idle, loading, ready, playing, paused, buffering, completed, failed.
- AndroidEngine: media3.
- AndroidDecoderMode: unknown, hardware, software.
- AndroidDecoderEvidence: none, hardwareOnly, hardwareAndSoftware.
- AndroidFailureCategory and AndroidFailureScope matching the public enums by name.

Declare these records with the listed fields and no dynamic/Object/map payload escape hatch:

- AndroidPlayerOptionsMessage: decoderPolicy, audioPolicy, positionUpdateIntervalMs.
- AndroidCreateRequest: schemaMajor, options.
- AndroidCreateReply: schemaMajor, channelSuffix, textureId, implementationName, implementationVersion, capabilities, initialState.
- AndroidCapabilitiesMessage: deviceProfile, decoderEvidence, maxConcurrentVideoDecoders, maxWidth, maxHeight, hardwareVideoCodecs, supportedOperations.
- AndroidHttpRequestMessage: headers and credentials as String-to-String maps.
- AndroidNetworkPolicyMessage: kind plus nullable connectTimeoutMs, readTimeoutMs, maxRetries, baseRetryDelayMs, maxRetryDelayMs, maxRedirects.
- AndroidSourceMessage: kind, locator, intent, format, request, and networkPolicy.
- AndroidVideoConstraintsMessage: nullable maxWidth, maxHeight, maxBitrate.
- AndroidBufferStrategyMessage: kind plus nullable minDurationMs, maxDurationMs, maxManagedBytes.
- AndroidLoadOptionsMessage: autoplay, nullable startPositionMs, bufferStrategy, videoConstraints, nullable decoderPolicyOverride.
- AndroidAssessRequest and AndroidLoadRequest: source plus options.
- AndroidAssessmentReply: outcome, nullable candidateEngine, satisfiedRequirements, limitations, nullable rejection.
- AndroidLoadReply: sessionId.
- AndroidSessionCommand: sessionId.
- AndroidSeekCommand, AndroidSpeedCommand, AndroidTrackCommand, and AndroidVideoConstraintsCommand: sessionId plus typed argument.
- AndroidTimelineMessage, AndroidVideoGeometryMessage, AndroidTrackMessage, AndroidMetricsMessage, and AndroidFailureMessage with one field for every public model field.
- AndroidStateMessage: sessionId, revision, sequence, status, timeline, nullable geometry, tracks, engine, decoderMode, nullable decoderIdentity, metrics, nullable failure.
- AndroidStateDeltaMessage: sessionId, previousRevision, revision, sequence, positionMs, bufferedPositionMs, isAtLiveEdge, liveOffsetMs, and only the nullable common metric fields allowed to change periodically.
- AndroidFirstFrameMessage, AndroidRetryScheduledMessage, AndroidEngineChangedMessage, and AndroidPlaybackFailedMessage: sessionId, revision, sequence, occurredAtMs plus event-specific typed fields.

Represent nullable clear-vs-unchanged delta fields with explicit hasX booleans paired with nullable values. Do not infer clear from Pigeon null.

- [ ] **Step 3: Declare exact APIs**

Use:

~~~dart
@HostApi()
abstract class AndroidPlayerFactoryHostApi {
  AndroidCreateReply create(AndroidCreateRequest request);
}

@HostApi()
abstract class AndroidPlayerHostApi {
  void attach();
  AndroidAssessmentReply assess(AndroidAssessRequest request);
  @async
  AndroidLoadReply load(AndroidLoadRequest request);
  void play(AndroidSessionCommand command);
  void pause(AndroidSessionCommand command);
  void seekTo(AndroidSeekCommand command);
  void seekToLiveEdge(AndroidSessionCommand command);
  void setPlaybackSpeed(AndroidSpeedCommand command);
  void selectAudioTrack(AndroidTrackCommand command);
  void setVideoConstraints(AndroidVideoConstraintsCommand command);
  void setVolume(double volume);
  void stop();
  void dispose();
}

@FlutterApi()
abstract class AndroidPlayerFlutterApi {
  void onState(AndroidStateMessage state);
  void onStateDelta(AndroidStateDeltaMessage delta);
  void onFirstFrame(AndroidFirstFrameMessage event);
  void onRetryScheduled(AndroidRetryScheduledMessage event);
  void onEngineChanged(AndroidEngineChangedMessage event);
  void onPlaybackFailed(AndroidPlaybackFailedMessage event);
}
~~~

The factory uses the fixed generated channel. AndroidPlayerHostApi and AndroidPlayerFlutterApi are always constructed/setup with AndroidCreateReply.channelSuffix.

- [ ] **Step 4: Generate committed sources**

Configure @ConfigurePigeon with package-relative dartOut and kotlinOut paths and KotlinOptions package dev.ylplayer.yl_player_android.pigeon. The generator script changes to its package directory and runs:

~~~bash
dart run pigeon --input pigeons/yl_player_android.dart
~~~

The check script runs the generator then:

~~~bash
git diff --exit-code -- lib/src/pigeon/yl_player_android.g.dart android/src/main/kotlin/dev/ylplayer/yl_player_android/pigeon/YlPlayerAndroid.g.kt
~~~

- [ ] **Step 5: Run schema checks and commit**

Run:

~~~bash
sh packages/yl_player_android/tool/generate_pigeon.sh
flutter test packages/yl_player_android/test/pigeon_schema_test.dart
sh packages/yl_player_android/tool/check_pigeon.sh
~~~

Expected: generation is deterministic, the smoke test passes, and git diff reports no drift after generation.

~~~bash
git add packages/yl_player_android/pubspec.yaml packages/yl_player_android/pigeons packages/yl_player_android/lib/src/pigeon packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/pigeon packages/yl_player_android/tool packages/yl_player_android/test/pigeon_schema_test.dart
git commit -m "build(android): add private pigeon protocol"
~~~

### Task 2: Implement the typed Dart adapter and callback reducer

**Files:**
- Rewrite: packages/yl_player_android/lib/yl_player_android.dart
- Create: packages/yl_player_android/lib/src/android_transport.dart
- Create: packages/yl_player_android/lib/src/android_codec.dart
- Create: packages/yl_player_android/lib/src/android_callbacks.dart
- Create: packages/yl_player_android/lib/src/android_player.dart
- Rewrite: packages/yl_player_android/test/yl_player_android_test.dart
- Create: packages/yl_player_android/test/android_codec_test.dart
- Create: packages/yl_player_android/test/android_player_test.dart

**Interfaces:**
- Consumes final YlPlayerPlatform/YlPlatformPlayer from the Dart/SPI plan.
- Produces a Pigeon-backed YlPlayerAndroid with injectable transport wrappers for Dart unit tests.
- Validates schema, session, revision, sequence, enum mapping, and safe failure mapping.

- [ ] **Step 1: Write failing codec tests**

Cover every enum in both directions, all nullable metrics, decoder unknown, display geometry, assessment rejection, failure redaction, and integer bounds. Verify a generated failure message whose message contains https://media.test/a?token=secret maps to a public fixed message and diagnostic ID without the URL.

- [ ] **Step 2: Write failing ordering tests**

Given state(session s1, revision 4, sequence 10):

- accept delta(s1, previousRevision 4, revision 5, sequence 11);
- ignore duplicate sequence 11;
- ignore delta for s0;
- ignore delta whose previousRevision is 3;
- accept a full state at revision 8/sequence 20;
- ignore a later-arriving full state at revision 7/sequence 21;
- report protocol.failure and terminate only after repeated structurally invalid callbacks, not for stale callbacks.

Also prove one AndroidPlayer object receives only its injected callback instance; there is no global event subscription.

- [ ] **Step 3: Prove tests fail**

Run:

~~~bash
flutter test packages/yl_player_android/test/android_codec_test.dart packages/yl_player_android/test/android_player_test.dart
~~~

Expected: the old MethodChannel/EventChannel adapter cannot satisfy the typed transport tests.

- [ ] **Step 4: Implement injectable transport ports**

Define private Dart interfaces:

~~~dart
abstract interface class AndroidFactoryTransport {
  Future<AndroidCreateReply> create(AndroidCreateRequest request);
}

abstract interface class AndroidPlayerTransport {
  Future<void> attach();
  Future<AndroidAssessmentReply> assess(AndroidAssessRequest request);
  Future<AndroidLoadReply> load(AndroidLoadRequest request);
  Future<void> play(AndroidSessionCommand command);
  Future<void> pause(AndroidSessionCommand command);
  Future<void> seekTo(AndroidSeekCommand command);
  Future<void> seekToLiveEdge(AndroidSessionCommand command);
  Future<void> setPlaybackSpeed(AndroidSpeedCommand command);
  Future<void> selectAudioTrack(AndroidTrackCommand command);
  Future<void> setVideoConstraints(AndroidVideoConstraintsCommand command);
  Future<void> setVolume(double volume);
  Future<void> stop();
  Future<void> dispose();
}
~~~

Production wrappers delegate one-to-one to generated Pigeon APIs. Tests use fakes without a binary messenger.

- [ ] **Step 5: Implement creation and teardown ordering**

Creation order is factory create, schema-major check, codec decode of capabilities/initial state, setup callback API on the returned suffix, player attach, then return YlPlatformPlayer. If any step after native creation fails, best-effort dispose the per-instance host API and unregister the Dart callback handler.

Disposal order is mark Dart adapter disposed, call native dispose, remove generated FlutterApi setup for the suffix, close local streams and texture notifier. Repeated calls share one Future.

- [ ] **Step 6: Run Dart tests and commit**

Run:

~~~bash
dart format packages/yl_player_android/lib packages/yl_player_android/test
flutter test packages/yl_player_android/test
flutter analyze packages/yl_player_android
~~~

Expected: all tests and analysis pass without importing yl_player_legacy_transport.dart.

~~~bash
git add packages/yl_player_android/lib packages/yl_player_android/test
git commit -m "refactor(android): use typed dart transport"
~~~

### Task 3: Split plugin entry, registry, per-instance host, and safe failure boundary

**Files:**
- Rewrite: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerAndroidPlugin.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerRegistry.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPigeonPlayerHost.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlFailureMapper.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlSafeDiagnostics.kt
- Create: packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlPlayerRegistryTest.kt
- Create: packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlFailureMapperTest.kt

**Interfaces:**
- Plugin implements FlutterPlugin, ComponentCallbacks2, and ActivityLifecycleCallbacks only.
- Registry implements generated AndroidPlayerFactoryHostApi and owns players/suffix uniqueness.
- One YlPigeonPlayerHost implements generated AndroidPlayerHostApi.
- Failures cross Pigeon only as typed FlutterError details generated from safe values.

- [ ] **Step 1: Write failing registry lifecycle tests**

With fake textures/messenger/player factory, assert create allocates one texture, registers exactly one suffix in the form p<monotonic-id>-<nonce>, and returns schema major 2. attach enables callbacks once. dispose removes handlers and releases the texture once. engine detach disposes every host and clears callbacks even when one teardown throws.

- [ ] **Step 2: Write failing redaction tests**

Feed IOException and IllegalStateException messages containing URLs, Authorization, Cookie, and stack frames. Assert public message is fixed, diagnosticId is non-empty, and only a locally logged redacted diagnostic contains implementation detail.

- [ ] **Step 3: Run failing JVM tests**

Run:

~~~bash
cd packages/yl_player_android/example/android
./gradlew testDebugUnitTest --tests '*YlPlayerRegistryTest' --tests '*YlFailureMapperTest' --stacktrace
~~~

Expected: classes do not exist.

- [ ] **Step 4: Implement boundary classes**

YlPlayerAndroidPlugin registers AndroidPlayerFactoryHostApi on attach and unregisters it on detach. It forwards lifecycle/memory/configuration events to registry methods; it contains no command switch, activePlayerId, player map, EventChannel, or MethodChannel.

YlPlayerRegistry owns a LinkedHashMap<String, YlPigeonPlayerHost>. It creates a texture and host atomically; failure releases the texture. Each host installs generated AndroidPlayerHostApi.setUp on its suffix. The host creates AndroidPlayerFlutterApi with the same suffix but sends nothing until attach.

YlFailureMapper maps known policy/source/network/container/decoder/resource/cancel cases to stable public codes. Unknown exceptions map to internal.failure. It logs one redacted line with diagnosticId through android.util.Log and never puts Throwable.message or stackTraceToString into Pigeon data.

- [ ] **Step 5: Pass and commit**

Run:

~~~bash
cd packages/yl_player_android/example/android
./gradlew testDebugUnitTest --tests '*YlPlayerRegistryTest' --tests '*YlFailureMapperTest' --stacktrace
~~~

Expected: tests pass.

~~~bash
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
git add packages/yl_player_android/android
git commit -m "refactor(android): split plugin registry boundary"
~~~

### Task 4: Add the Playback Session coordinator and authoritative state reducer

**Files:**
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlSessionModels.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlSessionCoordinator.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlStateReducer.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3Engine.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlCandidateVideoOutput.kt
- Modify then delete after extraction: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3Player.kt
- Create: packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlSessionCoordinatorTest.kt
- Create: packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlStateReducerTest.kt

**Interfaces:**
- Produces prepare, commit, cancel, replace, stop, and stale-command semantics.
- YlStateReducer is the only creator of full state/delta revision and sequence values.
- Engine callbacks include the immutable session ID captured when registered.

- [ ] **Step 1: Write failing transactional session tests**

Use fake candidate/active engines. Assert:

1. validation/prepare failure keeps the old session and sends no new state;
2. commit returns the new ID and then emits loading for that ID;
3. a second load cancels an uncommitted first candidate with load.cancelled;
4. an old candidate callback after cancellation is ignored;
5. command with the old ID throws session.stale;
6. stop cancels candidate, stops active engine, emits idle/null session, and preserves texture identity;
7. failure after commit produces failed state plus exactly one failure event for the new ID.

- [ ] **Step 2: Write reducer ordering tests**

Assert full semantic transitions increment revision and sequence by one. Timeline/metric ticks produce a delta with previousRevision equal current revision, revision incremented by one, and sequence incremented by one. Duplicate terminal failures are suppressed. firstFrame is emitted once per session.

- [ ] **Step 3: Prove tests fail**

Run:

~~~bash
cd packages/yl_player_android/example/android
./gradlew testDebugUnitTest --tests '*YlSessionCoordinatorTest' --tests '*YlStateReducerTest' --stacktrace
~~~

Expected: coordinator and reducer classes are missing.

- [ ] **Step 4: Extract an engine interface before moving Media3 code**

Define YlPlaybackEngineAdapter with typed methods prepare, activate, quiesce, restore, play, pause, seekTo, seekToLiveEdge, setPlaybackSpeed, selectAudioTrack, setVideoConstraints, stop, dispose, and callback registration. YlPreparedSession contains sessionId, source descriptor, load options, candidate engine, and decoder requirement state.

Move ExoPlayer construction and Player.Listener/AnalyticsListener code into YlMedia3Engine without changing policy algorithms. Keep one immutable sessionId per engine instance; never read a mutable current ID in an async callback. YlCandidateVideoOutput owns a private SurfaceTexture and Surface for pre-commit decoder initialization, never registers with Flutter, and releases both on commit/rollback/dispose. The active engine switches to YlVideoOutput only at commit.

- [ ] **Step 5: Implement coordinator/reducer**

Generate session IDs as a player-local monotonic string a<player-id>-s<load-sequence>; never include a source locator. Keep active and pending slots separate. Commit swaps slots only after candidate activation succeeds. Cancel/dispose increments an operation generation checked by every completion.

The reducer starts at idle revision 0 sequence 0. It converts Media3 callbacks into full states for status/track/geometry/decoder/failure changes and deltas for periodic timeline/common metrics only.

- [ ] **Step 6: Pass regression tests and commit**

Run:

~~~bash
cd packages/yl_player_android/example/android
./gradlew testDebugUnitTest --stacktrace
~~~

Expected: all existing and new JVM tests pass.

~~~bash
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
git add packages/yl_player_android/android
git commit -m "refactor(android): coordinate playback sessions"
~~~

### Task 5: Replace eager peer deactivation with transactional decoder leases

**Files:**
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlDecoderLeaseCoordinator.kt
- Create: packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlDecoderLeaseCoordinatorTest.kt
- Modify: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerRegistry.kt
- Modify: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlSessionCoordinator.kt
- Modify: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3Engine.kt

**Interfaces:**
- Registry owns one DecoderLeaseCoordinator.
- Session coordinator requests a lease only when candidate activation needs scarce video-decoder ownership.
- Lease transitions are validate/prepare, quiesce previous, activate candidate, commit; any failure restores the previous snapshot.

- [ ] **Step 1: Write the rollback matrix before implementation**

Using deterministic fakes, cover:

- candidate validation failure: previous untouched;
- candidate prepare failure: previous untouched;
- previous quiesce failure: candidate disposed, previous remains authoritative;
- candidate activation failure: previous restore called exactly once;
- candidate commit failure: candidate stopped/disposed and previous restored;
- success: previous deactivated only after candidate commit;
- candidate Player equals current owner: no peer quiesce;
- two overlapping requests: the newer request wins and the older completion cannot alter ownership;
- registry detach during transaction: both candidate and previous are disposed without restoration callbacks.

- [ ] **Step 2: Run and observe failure**

Run:

~~~bash
cd packages/yl_player_android/example/android
./gradlew testDebugUnitTest --tests '*YlDecoderLeaseCoordinatorTest' --stacktrace
~~~

Expected: class is missing and current plugin behavior deactivates peers before activation is viable.

- [ ] **Step 3: Implement an explicit transaction object**

Use:

~~~kotlin
internal interface YlDecoderLeaseParticipant {
    val leaseId: String
    fun quiesceForLease(): YlLeaseSnapshot
    fun activateForLease(): Result<Unit>
    fun commitLease()
    fun rollbackLease(snapshot: YlLeaseSnapshot)
    fun deactivateAfterLeaseTransfer()
}
~~~

YlDecoderLeaseCoordinator serializes transactions on the main looper. It stores owner only after commitLease succeeds. It keeps the prior snapshot until the commit point. Rollback errors are logged safely and reported as resource.exhausted for the candidate; they do not relabel the previous session as failed.

- [ ] **Step 4: Remove activePlayerId/eager filtering**

Delete every players.values.filter/deactivate path from the plugin/registry command boundary. Registry forwards lifecycle and memory events to the lease owner chosen by the coordinator. A normal inactive Player retains its committed session metadata and can reacquire a lease on play.

- [ ] **Step 5: Pass and commit**

Run:

~~~bash
cd packages/yl_player_android/example/android
./gradlew testDebugUnitTest --stacktrace
~~~

Expected: all tests pass and the lease rollback matrix is green.

~~~bash
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
git add packages/yl_player_android/android
git commit -m "fix(android): make decoder lease transactional"
~~~

### Task 6: Implement source assessment and strict request-policy enforcement

**Files:**
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlSourceAssessment.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMediaSourceFactory.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlManagedHttpClient.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlOriginCredentialPolicy.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlManagedRedirectInterceptor.kt
- Create: packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlSourceAssessmentTest.kt
- Create: packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlManagedRedirectInterceptorTest.kt
- Modify: packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlRedirectCredentialPolicyTest.kt
- Modify: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlaybackPolicy.kt
- Modify: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlAdaptiveLoadControl.kt
- Modify: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlHardwareCodecSelector.kt

**Interfaces:**
- assess and load share one pure route decision.
- Managed HTTP enforces timeouts/retries/redirect count and same-origin credentials.
- bounded returns incompatible until a hard byte ceiling is proven.
- hardwareRequired returns requiresInspection before load and commits only after positive decoder evidence.

- [ ] **Step 1: Write the assessment matrix**

Assert:

- file/content/network valid descriptors route to Media3;
- unsupported schemes and malformed content locators are incompatible;
- managed network is compatible for HTTP(S) progressive/HLS using managed OkHttp;
- bounded is incompatible with policy.unsupported;
- hardwarePreferred is compatible with limitation decoder evidence pending;
- hardwareRequired is requiresInspection for unknown video codec, incompatible if codec inspection proves no hardware decoder, and compatible only after candidate reports hardware;
- unknown containers are requiresInspection, not optimistically compatible.

- [ ] **Step 2: Write loopback redirect/credential tests**

Use MockWebServer or an in-process OkHttp interceptor chain. Test same-origin redirect retains ordinary headers and credentials; origin-changing redirect retains ordinary headers but strips every credential map key including X-Api-Key; redirect count is exactly enforced; 307/308 preserve method/body; credentials never reappear after returning to the original origin later in a redirect chain.

- [ ] **Step 3: Prove failures**

Run:

~~~bash
cd packages/yl_player_android/example/android
./gradlew testDebugUnitTest --tests '*YlSourceAssessmentTest' --tests '*YlManagedRedirectInterceptorTest' --stacktrace
~~~

Expected: classes are missing and current default request properties forward headers without credential classification.

- [ ] **Step 4: Implement managed networking**

For platformDefault, use Media3/OkHttp defaults and do not claim exact timeout/retry values. For managed, disable OkHttp automatic redirects and let YlManagedRedirectInterceptor follow at most maxRedirects. Construct every follow-up request from an immutable source-origin policy. Apply connect/read/call timeout values and Media3 load retry delays exactly from the request.

Ordinary headers are added to all required HLS/progressive requests except reserved transport headers. Credential keys are added only while every redirect so far remained at the original normalized scheme/host/effective-port origin.

- [ ] **Step 5: Implement decoder evidence and honest buffer behavior**

On API 29+, use MediaCodecInfo.isHardwareAccelerated and isSoftwareOnly. On API 24–28, use the existing conservative selector/name policy but classify mode unknown until onVideoDecoderInitialized names an accepted candidate. systemDefault uses MediaCodecSelector.DEFAULT, hardwarePreferred orders proven hardware candidates first but retains system/software fallback, and hardwareRequired filters to proven hardware candidates. hardwareRequired initializes against YlCandidateVideoOutput, uses a candidate timeout, and fails decoder.unavailable before commit if no positive evidence arrives.

Keep automatic/lowLatency/smoothPlayback in YlAdaptiveLoadControl as goals. Do not map bounded maxManagedBytes to DefaultAllocator.setTargetBufferSize and claim success. Return policy.unsupported until a separate hard-ceiling allocator/pipeline is proven by allocation tests.

- [ ] **Step 6: Pass and commit**

Run:

~~~bash
cd packages/yl_player_android/example/android
./gradlew testDebugUnitTest --stacktrace
~~~

Expected: all source, network, codec, load-control, and regression tests pass.

~~~bash
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
git add packages/yl_player_android/android
git commit -m "feat(android): enforce source request policies"
~~~

### Task 7: Make audio ownership, output, lifecycle, and metrics explicit

**Files:**
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlAudioFocusCoordinator.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMetricsCollector.kt
- Create: packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlAudioFocusCoordinatorTest.kt
- Create: packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlMetricsCollectorTest.kt
- Modify: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3Engine.kt
- Modify: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlVideoOutput.kt
- Modify: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlLifecyclePolicy.kt
- Modify: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerRegistry.kt

**Interfaces:**
- appManaged passes handleAudioFocus=false and handleAudioBecomingNoisy=false.
- pluginManagedMediaPlayback owns one shared media focus/noisy receiver and abandons only focus it acquired.
- Metrics map only the approved nullable common fields.
- Geometry uses Media3 VideoSize including unapplied rotation and pixel aspect ratio.

- [ ] **Step 1: Write failing ownership tests**

Assert appManaged never requests/abandons focus or registers a noisy receiver. Assert plugin-managed first play acquires once, multiple managed players reference-count ownership, failed acquisition prevents play, and final managed stop/dispose abandons/unregisters once. App lifecycle events must not abandon application-owned focus.

- [ ] **Step 2: Write metrics and geometry tests**

Assert a fresh metric snapshot is all null; observed zero counters become zero; Android device tier is absent; selected bitrate remains on selected track; managedBufferedBytes is null for normal Media3 buffering; rotation/PAR produce correct encoded/display geometry; static geometry is not repeated in periodic deltas.

- [ ] **Step 3: Implement and pass**

Configure Media3 AudioAttributes with handleAudioFocus equal to plugin ownership only. Centralize noisy receiver/focus count in YlAudioFocusCoordinator. YlMetricsCollector receives timestamped engine signals and returns immutable typed messages; no platform-only counter enters AndroidMetricsMessage.

Run:

~~~bash
cd packages/yl_player_android/example/android
./gradlew testDebugUnitTest --stacktrace
~~~

Expected: all  existing plus new tests pass.

- [ ] **Step 4: Commit**

~~~bash
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
git add packages/yl_player_android/android
git commit -m "feat(android): make playback ownership explicit"
~~~

### Task 8: Add Android emulator integration and remove legacy transport

**Files:**
- Create: packages/yl_player/example/integration_test/android_progressive_playback_test.dart
- Create: packages/yl_player/example/integration_test/android_hls_playback_test.dart
- Create: packages/yl_player/example/integration_test/android_session_replacement_test.dart
- Create: packages/yl_player/example/integration_test/android_multi_player_rollback_test.dart
- Create: tool/boot_ci_android_emulator.sh
- Create: tool/check_native_android.sh
- Modify: .github/workflows/ci.yml
- Modify: tool/check_foundation.sh
- Modify: packages/yl_player_android/lib/yl_player_android.dart
- Delete: Android use of package:yl_player_platform_interface/yl_player_legacy_transport.dart
- Delete: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlAndroidChannel.kt
- Delete after extraction: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3Player.kt

**Interfaces:**
- Android endorsed package is fully typed and independent of the legacy channel adapter.
- CI covers API 24 and one current API emulator using repository/loopback fixtures.

- [ ] **Step 1: Add failing integration cases**

Tests must prove create capabilities, local HLS and progressive playback, Ready before/independent of First Frame, seek, stop/reload, newer-load cancellation, stale-session rejection, source replacement, same-origin credential redirect behavior, and multi-Player candidate failure restoring previous playback.

- [ ] **Step 2: Add the native Android gate**

tool/check_native_android.sh runs:

~~~bash
cd packages/yl_player_android/example/android
./gradlew testDebugUnitTest --stacktrace
cd /Users/yy2021_8689/Desktop/Flutter/yl_player/packages/yl_player/example
flutter test integration_test/android_progressive_playback_test.dart -d "$YL_ANDROID_DEVICE_ID"
flutter test integration_test/android_hls_playback_test.dart -d "$YL_ANDROID_DEVICE_ID"
flutter test integration_test/android_session_replacement_test.dart -d "$YL_ANDROID_DEVICE_ID"
flutter test integration_test/android_multi_player_rollback_test.dart -d "$YL_ANDROID_DEVICE_ID"
~~~

The boot script accepts YL_ANDROID_API, creates an isolated AVD name, waits for sys.boot_completed, disables animations, and prints only the adb device ID.

- [ ] **Step 3: Add CI matrix and Pigeon drift gate**

Add an android-native-integration matrix for API 24 and 35. Run Pigeon drift once, JVM tests once, and emulator integration for both matrix entries. Keep timeouts explicit and upload adb/logcat only on failure.

- [ ] **Step 4: Remove old transport code and prove no string protocol remains**

Run:

~~~bash
rg -n 'MethodChannel|EventChannel|invokeMethod|onMethodCall|when \(call.method\)|"command"|"create"|"dispose"' packages/yl_player_android/lib packages/yl_player_android/android/src/main
~~~

Expected: no handwritten Flutter channel or string command dispatch remains; generated Pigeon internals may contain BasicMessageChannel names.

- [ ] **Step 5: Run full Android and foundation gates**

Run:

~~~bash
sh packages/yl_player_android/tool/check_pigeon.sh
sh tool/check_foundation.sh
cd packages/yl_player_android/example/android
./gradlew testDebugUnitTest --stacktrace
~~~

With an emulator ID:

~~~bash
YL_ANDROID_DEVICE_ID=<device-id> sh tool/check_native_android.sh
~~~

Expected: deterministic codegen, analysis, Dart suites, all JVM tests, and emulator tests pass.

- [ ] **Step 6: Commit**

~~~bash
git add packages/yl_player_android packages/yl_player/example/integration_test tool .github/workflows/ci.yml
git commit -m "feat(android): complete typed session backend"
~~~

### Task 9: Android phase self-review

**Files:**
- Modify only defects identified below.
- Modify: docs/verification/player-v2-migration.md

- [ ] **Step 1: Inspect architecture boundaries**

Confirm YlPlayerAndroidPlugin contains registration/lifecycle forwarding only; registry owns instances; coordinator owns sessions; lease coordinator owns cross-player exclusivity; engine owns Media3; source/network builders own request policy; reducer owns revisions; metrics and diagnostics are separate.

- [ ] **Step 2: Run forbidden-pattern scans**

Run:

~~~bash
rg -n 'EventChannel|MethodChannel|stackTraceToString|Throwable\.message|platformDiagnostic' packages/yl_player_android
rg -n 'activePlayerId|players\.values.*deactivate|setDefaultRequestProperties\(.*credentials' packages/yl_player_android/android/src/main
rg -n '[T]ODO|[F]IXME|[T]BD|[X]XX' docs/superpowers/plans/2026-09-06-player-v2-android.md
~~~

Expected: only generated Pigeon transport references Flutter channels; other scans return no production violations or planning gaps.

- [ ] **Step 3: Run final phase evidence**

Run:

~~~bash
sh packages/yl_player_android/tool/check_pigeon.sh
sh tool/check_foundation.sh
cd packages/yl_player_android/example/android
./gradlew testDebugUnitTest --stacktrace
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
git diff --check
~~~

Expected: all pass.

- [ ] **Step 4: Record deferred evidence**

Update docs/verification/player-v2-migration.md with API levels actually tested, test counts, codegen result, and explicit unverified items: physical Android TV decoder pressure, long playback soak, reconnect endurance, and device-specific MediaCodec evidence.

~~~bash
git add docs/verification/player-v2-migration.md
git commit -m "docs: record android v2 verification"
~~~
