# Player v0.2 Android Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Android's global handwritten channel protocol and eager peer deactivation with a private instance-scoped Pigeon transport, transactional Playback Session coordinator, honest strict-policy handling, and regression-tested Media3 integration.

**Architecture:** A small plugin entry owns a Player registry and Pigeon factory endpoint. Every created Player gets a unique channel suffix, typed host API, and typed Flutter callback API. SessionCoordinator constructs a candidate Media3 engine, DecoderLeaseCoordinator quiesces and restores scarce decoder owners transactionally, StateReducer owns session/revision/sequence ordering, and focused source/network/output/audio/metrics components wrap Media3.

**Tech Stack:** Flutter 3.44, Dart 3.12, Pigeon 28.0.0, Kotlin 2.3.20, Java 17, Android Gradle Plugin 9.0.1, Media3 1.11.0, OkHttp through media3-datasource-okhttp, Kotlin test and Mockito.

**Spec:** docs/superpowers/specs/2026-09-06-player-v2-architecture-design.md

## Global Constraints

- Complete docs/superpowers/plans/2026-09-06-player-v2-dart-api-and-spi.md first.
- Preserve tested Media3 selector, load control, surface restoration, lifecycle, health monitor, and stall watchdog behavior except the explicit evidence, ownership, session, and managed-policy corrections in this plan. Update conflicting legacy expectations with focused regression coverage before removing them.
- Generated Dart and Kotlin files live only in yl_player_android. No generated type crosses into yl_player_platform_interface or yl_player.
- Every native callback and command is scoped by one Pigeon channel suffix. There is no process-wide event stream and no Dart-side filtering by numeric player ID.
- Every command, state snapshot, delta, and event carries a Playback Session ID when session-scoped.
- Full states and deltas carry validated revision and sequence values. A delta applies only when its previousRevision equals current revision and sequence is newer. One native callback dispatcher serializes and awaits acknowledgement across all generated callback methods; event delivery is not discarded merely because a newer state revision was accepted.
- Explicit managed network is accepted only for HTTP(S) routes built entirely by the managed OkHttp/Media3 stack.
- Explicit bounded buffer is rejected until an instrumented test proves the requested hard managed-byte ceiling. Default Media3 allocator target size is not a hard ceiling and must not be advertised as one.
- Explicit hardwareRequired for video commits only after MediaCodec initialization proves a hardware decoder. Codec-name heuristics alone never prove hardware, including on API 24–28; use API 29+ hardwareAccelerated/softwareOnly evidence tied to the initialized decoder, or independently verified evidence.
- Candidate failure before commit leaves the former Player/session authoritative; restore any resources quiesced for the candidate. A distinct restoration failure must be reported honestly rather than retaining a false playing state.
- No public diagnostic contains a URI, query, header, credential, exception message, or stack.
- All Media3 and Android framework calls occur on the main looper unless a component explicitly documents a worker thread and hands immutable data back. Never block the main looper awaiting decoder initialization, callback acknowledgement, release, or restoration.
- Task gates run the named new suites and affected existing regression suites; repository-wide analysis/foundation and all Android suites are phase gates after Task 8 replaces obsolete legacy tests. Intermediate tasks must not require unmigrated tests to pass against deleted APIs.
- Shell blocks are run within the selected worktree. Discover its root with `YL_REPO_ROOT=$(git rev-parse --show-toplevel)` and quote all derived paths; scripts independently discover their own worktree root. Never navigate to another checkout by an absolute developer path.

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
  - Create YlPlayerRegistry.kt, YlPigeonPlayerHost.kt, and YlCallbackDispatcher.kt.
- Coordination:
  - Create YlSessionCoordinator.kt, YlDecoderLeaseCoordinator.kt, YlStateReducer.kt, and YlSessionModels.kt.
- Engine:
  - Extract YlMedia3Engine.kt from YlMedia3Player.kt.
  - Create YlCandidateVideoOutput.kt for pre-commit hardware evidence without taking the public texture.
  - Keep and narrow YlAdaptiveLoadControl.kt, YlHardwareCodecSelector.kt, YlPlaybackPolicy.kt, YlPlaybackHealthMonitor.kt, YlPlaybackStallWatchdog.kt, YlFirstFrameGate.kt, YlLifecyclePolicy.kt, and YlVideoOutput.kt.
- Source/network:
  - Create YlSourceAssessment.kt, YlMediaSourceFactory.kt, YlManagedHttpClient.kt, YlManagedRetryPolicy.kt, YlOriginCredentialPolicy.kt, and YlManagedRedirectInterceptor.kt.
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
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
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
- AndroidEngine: unknown, media3. unknown is valid for idle/no active engine; capabilities advertise media3 only.
- AndroidTrackKind: audio, video.
- AndroidPlayerOperation: seek, seekToLiveEdge, playbackSpeed, audioTrackSelection, videoConstraints, volume, stop.
- AndroidDecoderMode: unknown, hardware, software.
- AndroidDecoderEvidence: none, hardwareOnly, hardwareAndSoftware.
- AndroidFailureCategory and AndroidFailureScope matching the public enums by name.

Declare these records with the listed fields and no dynamic/Object/map payload escape hatch:

All names below are schema classes; `int` generates Kotlin `Long`, `double` generates `Double`, and `?` denotes nullable. Lists and map entries are non-null and decoded into immutable public collections. Every field is required unless marked nullable.

- AndroidPlayerOptionsMessage: decoderPolicy: AndroidDecoderPolicy, audioPolicy: AndroidAudioPolicy, positionUpdateIntervalMs: int.
- AndroidCreateRequest: schemaMajor: int, options: AndroidPlayerOptionsMessage.
- AndroidCreateReply: schemaMajor: int, spiMajor: int, channelSuffix: String, textureId: int, implementationName: String, implementationVersion: String, capabilities: AndroidCapabilitiesMessage, initialState: AndroidStateMessage.
- AndroidCapabilitiesMessage: deviceProfile: String, availableEngines: List<AndroidEngine>, decoderEvidence: AndroidDecoderEvidence, maxConcurrentVideoDecoders: int?, maxWidth: int?, maxHeight: int?, hardwareVideoCodecs: List<String>, supportedOperations: List<AndroidPlayerOperation>.
- AndroidHttpRequestMessage: headers: Map<String, String>, credentials: Map<String, String>.
- AndroidNetworkPolicyMessage: kind: AndroidNetworkPolicyKind; connectTimeoutMs, readTimeoutMs, maxRetries, baseRetryDelayMs, maxRetryDelayMs, maxRedirects: int?. All six are non-null for managed and null for platformDefault. There is no call/overall timeout field or guarantee.
- AndroidSourceMessage: kind: AndroidSourceKind, locator: String, intent: AndroidStreamIntent, format: AndroidMediaFormat, request: AndroidHttpRequestMessage?, networkPolicy: AndroidNetworkPolicyMessage?. request/networkPolicy are non-null only for network; file intent is onDemand.
- AndroidVideoConstraintsMessage: maxWidth: int?, maxHeight: int?, maxBitrate: int?.
- AndroidBufferStrategyMessage: kind: AndroidBufferKind, minDurationMs: int?, maxDurationMs: int?, maxManagedBytes: int?. All three values are non-null only for bounded.
- AndroidLoadOptionsMessage: autoplay: bool, startPositionMs: int?, bufferStrategy: AndroidBufferStrategyMessage, videoConstraints: AndroidVideoConstraintsMessage, decoderPolicyOverride: AndroidDecoderPolicy?.
- AndroidAssessRequest and AndroidLoadRequest: source: AndroidSourceMessage, options: AndroidLoadOptionsMessage.
- AndroidAssessmentReply: outcome: AndroidAssessmentOutcome, candidateEngine: AndroidEngine?, satisfiedRequirements: List<String>, limitations: List<String>, rejection: AndroidFailureMessage?. Rejection is present exactly for incompatible. Requirement/limitation strings are validated stable IDs decoded as YlRequirementId/YlLimitationId; retain unknown valid IDs for forward compatibility, and never transport free-form source-dependent prose in these lists.
- AndroidLoadReply: sessionId: String.
- AndroidSessionCommand: sessionId: String.
- AndroidSeekCommand: sessionId: String, positionMs: int. AndroidSpeedCommand: sessionId: String, speed: double. AndroidTrackCommand: sessionId: String, trackId: String. AndroidVideoConstraintsCommand: sessionId: String, constraints: AndroidVideoConstraintsMessage.
- AndroidDvrWindowMessage: startMs: int, endMs: int. AndroidTimelineMessage: positionMs: int, durationMs: int?, bufferedPositionMs: int, isSeekable: bool, isLive: bool, isAtLiveEdge: bool?, liveOffsetMs: int?, dvrWindow: AndroidDvrWindowMessage?.
- AndroidSizeMessage: width: double, height: double. AndroidVideoGeometryMessage: encodedSize: AndroidSizeMessage, displaySize: AndroidSizeMessage, pixelAspectRatio: double, rotationDegrees: int. displaySize precedes unapplied rotation; pixelAspectRatio is applied exactly once when deriving display aspect ratio.
- AndroidTrackMessage: id: String, kind: AndroidTrackKind, label: String?, language: String?, codec: String?, bitrate: int?, width: int?, height: int?, isSelected: bool.
- AndroidMetricsMessage: loadToReadyMs, loadToFirstFrameMs, rebufferCount, rebufferDurationMs, droppedVideoFrames, audioUnderruns, estimatedBitrate, managedBufferedDurationMs, managedBufferedBytes, liveOffsetMs, reconnectCount: int?.
- AndroidFailureMessage: category: AndroidFailureCategory, code: String, message: String, retryable: bool, scope: AndroidFailureScope, diagnosticId: String.
- AndroidStateMessage: sessionId: String?, revision: int, sequence: int, status: AndroidPlaybackStatus, timeline: AndroidTimelineMessage, geometry: AndroidVideoGeometryMessage?, audioTracks: List<AndroidTrackMessage>, videoTracks: List<AndroidTrackMessage>, engine: AndroidEngine, decoderMode: AndroidDecoderMode, decoderIdentity: String?, metrics: AndroidMetricsMessage, failure: AndroidFailureMessage?. Idle has null sessionId; session-bearing states require a non-empty ID. A player-scoped terminal protocol failure may have null sessionId.
- AndroidStateDeltaMessage: sessionId: String, previousRevision: int, revision: int, sequence: int, positionMs: int?, bufferedPositionMs: int?, hasIsAtLiveEdge: bool, isAtLiveEdge: bool?, hasLiveOffsetMs: bool, liveOffsetMs: int?, metrics: AndroidMetricsDeltaMessage?.
- AndroidMetricsDeltaMessage: for each of the eleven AndroidMetricsMessage fields, declare an explicit `has<Field>: bool` plus a nullable int value of the same name. A true flag and null clears a measurement; false leaves it unchanged. Ordinary nullable position/bufferedPosition delta values mean unchanged because the corresponding state fields cannot be null. A metrics delta cannot change tracks, geometry, engine, decoder identity, status, or failure.
- All four event classes require sessionId: String, revision: int, sequence: int, occurredAtMs: int. AndroidFirstFrameMessage adds no fields. AndroidRetryScheduledMessage adds retryIndex: int, delayMs: int, failure: AndroidFailureMessage. AndroidEngineChangedMessage adds previousEngine: AndroidEngine and engine: AndroidEngine. AndroidPlaybackFailedMessage adds failure: AndroidFailureMessage.

Validate on both sides before creating public values: identifiers are non-empty; revisions/sequences, byte counts, positions and monotonic-epoch timestamps are nonnegative signed-64-bit integers; a delta has revision > previousRevision; counters are nonnegative and retryIndex starts at 1. Widths/heights, finite size dimensions, pixel aspect, selected bitrates, and position intervals are positive; rotation is 0/90/180/270. Public live offsets are nonnegative milliseconds; clamp a negative raw engine offset to zero before transport, and preserve null when unknown. DVR start <= end. Managed timeout values fit positive signed-32-bit milliseconds before OkHttp conversion; retry/redirect counts fit nonnegative signed-32-bit values; retry delays are nonnegative and baseRetryDelay <= maxRetryDelay. Request durations and bounded byte budgets fit signed-32-bit native ranges; timeline, revision, sequence, and measured counters retain signed-64-bit range. Bounded fields obey the shared validators, including minDuration <= maxDuration and byte budget 1...2147483647. Volume is finite in 0...1 and speed finite in 0.25...4; never narrow integers unchecked. All times are integer milliseconds, rates are bits/second, and memory is bytes. Public event occurredAt is Duration since the implementation-local monotonic epoch, never wall clock. Share these boundaries with Dart/SPI validators instead of introducing Android-only defaults.

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
  @async
  void play(AndroidSessionCommand command);
  void pause(AndroidSessionCommand command);
  void seekTo(AndroidSeekCommand command);
  void seekToLiveEdge(AndroidSessionCommand command);
  void setPlaybackSpeed(AndroidSpeedCommand command);
  void selectAudioTrack(AndroidTrackCommand command);
  void setVideoConstraints(AndroidVideoConstraintsCommand command);
  void setVolume(double volume);
  @async
  void stop();
  @async
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

The factory uses the fixed generated channel. AndroidPlayerHostApi and AndroidPlayerFlutterApi are always constructed/setup with AndroidCreateReply.channelSuffix. load/play/stop/dispose complete asynchronously so lease activation and teardown never require a main-looper wait; other command methods only perform immediate main-looper state checks and enqueue work.

- [ ] **Step 4: Generate committed sources**

Configure @ConfigurePigeon with package-relative dartOut and kotlinOut paths and KotlinOptions package dev.ylplayer.yl_player_android.pigeon. The generator/check scripts resolve their script directory first (`YL_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)`) and discover the selected worktree with `YL_REPO_ROOT=$(git -C "$YL_SCRIPT_DIR" rev-parse --show-toplevel)`. The generator then changes to the Android package directory and runs:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT/packages/yl_player_android"
dart run pigeon --input pigeons/yl_player_android.dart
~~~

The check script runs the generator then:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT/packages/yl_player_android"
git diff --exit-code -- lib/src/pigeon/yl_player_android.g.dart android/src/main/kotlin/dev/ylplayer/yl_player_android/pigeon/YlPlayerAndroid.g.kt
~~~

- [ ] **Step 5: Run schema checks and commit**

Run:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
sh packages/yl_player_android/tool/generate_pigeon.sh
flutter test packages/yl_player_android/test/pigeon_schema_test.dart
sh packages/yl_player_android/tool/check_pigeon.sh
~~~

Expected: generation is deterministic, the smoke test passes, and git diff reports no drift after generation.

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
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
- report protocol.mismatch and terminate only after repeated structurally invalid callbacks, not for stale callbacks;
- accept each valid same-session first-frame/failure milestone exactly once even if a newer full-state revision has arrived; event identity/sequence deduplication is separate from the state revision watermark;
- verify one native callback dispatcher awaits each generated callback acknowledgement before invoking another method, including onState -> onFirstFrame -> onStateDelta; delayed acknowledgements preserve this order without blocking the main looper;
- hold Load completion until both AndroidLoadReply and a matching authoritative full state have arrived, testing both arrival orders and immediate play after await load;
- an initial STATE_BUFFERING callback remains loading and cannot complete Ready; only an observed STATE_READY (or later state known to follow it) can do so.

Also prove one AndroidPlayer object receives only its injected callback instance; there is no global event subscription.

- [ ] **Step 3: Prove tests fail**

Run:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
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

Production wrappers invoke the generated Pigeon APIs and decode typed failures; the adapter owns the reply/state Load barrier rather than exposing the raw host Future directly. Tests use fakes without a binary messenger. For each pending Load retain both reply and matching authoritative state; complete only when both exist, without waiting for Ready or First Frame. Buffer state-first arrivals by session identity, and cancel the barrier on newer Load, Stop, Dispose, or terminal transport failure. A reply whose session was superseded never revives it. Same-session first-frame and failure milestones use independent deduplication and survive newer state revisions. Start a 5-second reply-to-state deadline only after a Load reply arrives without its matching state; expire it as protocol.mismatch, terminate adapter transport, and best-effort dispose rather than leave load unresolved if the callback channel fails. Backend failures or cancellation fail pending barriers immediately.

- [ ] **Step 5: Implement creation and teardown ordering**

Creation order is factory create, schema-major and public SPI-major checks, codec decode of implementation/capabilities/initial state, setup callback API on the returned suffix, player attach, then return YlPlatformPlayer. Map reply implementationName/implementationVersion/spiMajor into YlPlatformImplementationInfo exactly once; capabilities contain no duplicate metadata. If any step after native creation fails, best-effort dispose the per-instance host API and unregister the Dart callback handler.

Disposal order is mark Dart adapter disposed, call native dispose, remove generated FlutterApi setup for the suffix, close local streams and texture notifier. Repeated calls share one Future.

- [ ] **Step 6: Run Dart tests and commit**

Run:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
dart format packages/yl_player_android/lib packages/yl_player_android/test
flutter test packages/yl_player_android/test/android_codec_test.dart packages/yl_player_android/test/android_player_test.dart
flutter analyze packages/yl_player_android/lib/src packages/yl_player_android/lib/yl_player_android.dart
~~~

Expected: all tests and analysis pass without importing yl_player_legacy_transport.dart.

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
git add packages/yl_player_android/lib packages/yl_player_android/test
git commit -m "refactor(android): use typed dart transport"
~~~

### Task 3: Split plugin entry, registry, per-instance host, and safe failure boundary

**Files:**
- Rewrite: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerAndroidPlugin.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerRegistry.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPigeonPlayerHost.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlCallbackDispatcher.kt
- Create: packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlCallbackDispatcherTest.kt
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
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
cd "$YL_REPO_ROOT/packages/yl_player_android/example/android"
./gradlew testDebugUnitTest --tests '*YlPlayerRegistryTest' --tests '*YlFailureMapperTest' --tests '*YlCallbackDispatcherTest' --stacktrace
~~~

Expected: classes do not exist.

- [ ] **Step 4: Implement boundary classes**

YlPlayerAndroidPlugin registers AndroidPlayerFactoryHostApi on attach and unregisters it on detach. It forwards lifecycle/memory/configuration events to registry methods; it contains no command switch, activePlayerId, player map, EventChannel, or MethodChannel.

YlPlayerRegistry owns a LinkedHashMap<String, YlPigeonPlayerHost>. It creates a texture and host atomically; failure releases the texture. Each host installs generated AndroidPlayerHostApi.setUp on its suffix. The host creates AndroidPlayerFlutterApi with the same suffix but sends nothing until attach. YlCallbackDispatcher maintains one FIFO per Player across every callback method and permits exactly one unacknowledged invocation. Its completion callback posts continuation to the main looper; never wait synchronously. Enqueue immutable snapshots/events in reducer order. Use a 5-second acknowledgement deadline; a delivery error or deadline terminates the instance transport, cancels pending commands, and unregisters callbacks rather than skipping an item and silently losing a milestone. Disposal invalidates dispatcher generation and drops queued messages. Test blocked acknowledgement, failure, timeout, and detach with an in-flight item.

YlFailureMapper maps known policy/source/network/container/decoder/resource/cancel cases to stable public codes. Unknown exceptions map to internal.failure. It logs one redacted line with diagnosticId through android.util.Log and never puts Throwable.message or stackTraceToString into Pigeon data.

- [ ] **Step 5: Pass and commit**

Run:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
cd "$YL_REPO_ROOT/packages/yl_player_android/example/android"
./gradlew testDebugUnitTest --tests '*YlPlayerRegistryTest' --tests '*YlFailureMapperTest' --tests '*YlCallbackDispatcherTest' --stacktrace
~~~

Expected: tests pass.

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
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
2. commit publishes loading for the new ID and returns that ID; the adapter exposes Load completion only after both the response and matching full state are observed, regardless of channel delivery order;
3. a second load cancels an uncommitted first candidate with load.cancelled;
4. an old candidate callback after cancellation is ignored;
5. command with the old ID throws session.stale;
6. stop cancels candidate, stops active engine, emits idle/null session, and preserves texture identity;
7. failure after commit produces failed state plus exactly one failure event for the new ID;
8. initial Media3 STATE_BUFFERING remains loading until STATE_READY is observed; later buffering preserves the established Ready milestone;
9. private candidate output rendering never emits public firstFrame or consumes its gate; after commit the first render to the current public output emits exactly once, and late callbacks for the private/old output are ignored.

- [ ] **Step 2: Write reducer ordering tests**

Assert full semantic transitions increment revision and sequence by one. Timeline/metric ticks produce a delta with previousRevision equal current revision, revision incremented by one, and sequence incremented by one. Duplicate terminal failures are suppressed. firstFrame is emitted once per session.

- [ ] **Step 3: Prove tests fail**

Run:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
cd "$YL_REPO_ROOT/packages/yl_player_android/example/android"
./gradlew testDebugUnitTest --tests '*YlSessionCoordinatorTest' --tests '*YlStateReducerTest' --stacktrace
~~~

Expected: coordinator and reducer classes are missing.

- [ ] **Step 4: Extract an engine interface before moving Media3 code**

Define YlPlaybackEngineAdapter with typed methods prepare, activate, quiesce, restore, play, pause, seekTo, seekToLiveEdge, setPlaybackSpeed, selectAudioTrack, setVideoConstraints, stop, dispose, and callback registration. YlPreparedSession contains sessionId, source descriptor, load options, candidate engine, and decoder requirement state.

Move ExoPlayer construction and Player.Listener/AnalyticsListener code into YlMedia3Engine without changing policy algorithms. Keep one immutable sessionId per engine instance; never read a mutable current ID in an async callback. YlCandidateVideoOutput owns a private SurfaceTexture and Surface for pre-commit decoder initialization and never registers with Flutter. Surface transfer is ordered: attach the committed public output, await engine acknowledgement that the private Surface is detached, then release private Surface/SurfaceTexture; rollback/dispose also detach before release. The active engine switches to YlVideoOutput only at commit. Tag output callbacks with immutable output identity/generation as well as session ID. The first-frame gate accepts only a committed session and its current public output; private candidate rendering cannot emit or consume the public milestone. This explicitly changes the old listener, which ignores its output argument. Track reachedReady per session: initial STATE_BUFFERING maps to loading, STATE_READY establishes Ready, and only subsequent buffering maps to buffering.

- [ ] **Step 5: Implement coordinator/reducer**

Generate session IDs as a player-local monotonic string a<player-id>-s<load-sequence>; never include a source locator. Keep active and pending slots separate. Commit swaps slots only after the cancellable asynchronous candidate activation succeeds with any required positive decoder evidence. Same-Player source replacement still snapshots and quiesces its old engine when both engines would compete for the same scarce decoder; the absence of a peer does not exempt the old engine from resource accounting. Cancel/dispose increments an operation generation checked by every completion.

The reducer starts at idle revision 0 sequence 0. It converts Media3 callbacks into full states for status/track/geometry/decoder/failure changes and deltas for periodic timeline/common metrics only.

- [ ] **Step 6: Pass regression tests and commit**

Run:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
cd "$YL_REPO_ROOT/packages/yl_player_android/example/android"
./gradlew testDebugUnitTest --tests '*YlSessionCoordinatorTest' --tests '*YlStateReducerTest' --tests '*YlMedia3StatePolicyTest' --tests '*YlFirstFrameGateTest' --stacktrace
~~~

Expected: the named new and affected regression JVM suites pass.

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
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
- candidate Player equals current owner: no unrelated peer quiesce, but the former engine is quiesced/restored when needed for same-Player source replacement;
- two overlapping requests: the newer request wins and the older completion cannot alter ownership;
- registry detach during transaction: both candidate and previous are disposed without restoration callbacks;
- activation/restore completion arrives after cancellation/deadline: generation check ignores it and disposes the late candidate;
- a Load/Stop/detach during decoder initialization never blocks the main looper and cannot later commit;
- previous restoration is asynchronous and its success/failure is observed; resource restoration failure never falsely reports the prior session as playing.

- [ ] **Step 2: Run and observe failure**

Run:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
cd "$YL_REPO_ROOT/packages/yl_player_android/example/android"
./gradlew testDebugUnitTest --tests '*YlDecoderLeaseCoordinatorTest' --stacktrace
~~~

Expected: class is missing and current plugin behavior deactivates peers before activation is viable.

- [ ] **Step 3: Implement an explicit transaction object**

Use:

~~~kotlin
internal data class YlLeaseAttempt(val generation: Long, val deadlineMs: Long)
internal fun interface YlCancelHandle { fun cancel() }
internal interface YlDecoderLeaseParticipant {
    val leaseId: String
    fun quiesceForLease(attempt: YlLeaseAttempt, complete: (Result<YlLeaseSnapshot>) -> Unit): YlCancelHandle
    fun activateForLease(attempt: YlLeaseAttempt, complete: (Result<Unit>) -> Unit): YlCancelHandle
    fun commitLease()
    fun rollbackLease(snapshot: YlLeaseSnapshot, attempt: YlLeaseAttempt, complete: (Result<Unit>) -> Unit): YlCancelHandle
    fun deactivateAfterLeaseTransfer()
}
~~~

YlLeaseSnapshot is immutable and includes the previous session ID, source/options, position/live intent, selected tracks, speed, volume, intended play state, and output identity needed to restore it. It contains no transportable diagnostics. YlDecoderLeaseCoordinator serializes transaction transitions on the main looper, without serializing new commands behind a blocking wait. Each quiesce/activate/restore stage returns immediately, has a cancellable operation handle and a fresh generation, and completes on the main looper. Use SystemClock.elapsedRealtime and injected timers: quiesce deadline 5 seconds, activation deadline 15 seconds, restoration deadline 15 seconds. These internal resource deadlines are separate from network request policy. Each callback checks generation, cancellation, registry attachment, and deadline before changing ownership.

The coordinator stores owner only after commitLease succeeds and keeps the prior snapshot until that point. New Load/Stop/Dispose cancels the current stage and invalidates its generation. A cancelled or timed-out activation disposes the candidate before restoring the previous engine; a newer operation cannot start ownership transfer until release/rollback resolves. Late completions cannot commit or alter the owner. Restore errors are logged safely and return resource.exhausted for the candidate. Do not relabel the prior session as failed merely because replacement failed; if restoration itself cannot recover, emit an explicit resource.exhausted terminal failure for the prior session instead of retaining a false playing state. Detach disposes all participants and suppresses restoration callbacks.

- [ ] **Step 4: Remove activePlayerId/eager filtering**

Delete every players.values.filter/deactivate path from the plugin/registry command boundary. Registry forwards lifecycle and memory events to every active or pending session participant, including audio-only sessions and engines that require no scarce video lease. Decoder ownership only determines resource arbitration. Background entry cancels/quiesces candidates, suspends active playback, and publishes the resulting state; foreground restoration respects each saved playback intent and reacquires a lease where necessary. A normal inactive Player retains its committed session metadata and can reacquire a lease on play. Test audio-only background suspension, two non-exclusive active engines, and background entry during candidate activation.

- [ ] **Step 5: Pass and commit**

Run:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
cd "$YL_REPO_ROOT/packages/yl_player_android/example/android"
./gradlew testDebugUnitTest --tests '*YlDecoderLeaseCoordinatorTest' --tests '*YlSessionCoordinatorTest' --stacktrace
~~~

Expected: the named suites pass and the lease rollback matrix is green.

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
git add packages/yl_player_android/android
git commit -m "fix(android): make decoder lease transactional"
~~~

### Task 6: Implement source assessment and strict request-policy enforcement

**Files:**
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlSourceAssessment.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMediaSourceFactory.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlManagedHttpClient.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlManagedRetryPolicy.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlOriginCredentialPolicy.kt
- Create: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlManagedRedirectInterceptor.kt
- Create: packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlSourceAssessmentTest.kt
- Create: packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlManagedRedirectInterceptorTest.kt
- Modify: packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlRedirectCredentialPolicyTest.kt
- Modify: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlaybackPolicy.kt
- Modify: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlAdaptiveLoadControl.kt
- Modify: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlHardwareCodecSelector.kt
- Modify: packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlHardwareCodecSelectorTest.kt
- Create: packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlManagedRetryPolicyTest.kt

**Interfaces:**
- assess and load share one pure route decision.
- Managed HTTP enforces timeouts/retries/redirect count and same-origin credentials.
- bounded returns incompatible until a hard byte ceiling is proven.
- hardwareRequired for video returns requiresInspection only when positive evidence remains attainable and commits only after that evidence; known absence of trustworthy evidence is incompatible.

- [ ] **Step 1: Write the assessment matrix**

Assert:

- file/content/network valid descriptors route to Media3;
- unsupported schemes and malformed content locators are incompatible;
- managed network is compatible for HTTP(S) progressive/HLS using managed OkHttp;
- bounded is incompatible with policy.unsupported;
- hardwarePreferred is compatible with limitation decoder evidence pending;
- hardwareRequired is requiresInspection while positive hardware evidence remains attainable, incompatible if no hardware decoder/evidence can be proven, and compatible only after candidate initialization yields positive evidence; API 24–28 codec names alone never qualify;
- unknown containers are requiresInspection, not optimistically compatible.

- [ ] **Step 2: Write loopback redirect/credential tests**

Use MockWebServer or an in-process OkHttp interceptor chain; if using MockWebServer, add its matching OkHttp-version test dependency to packages/yl_player_android/android/build.gradle.kts in this task. Test both platformDefault and managed credential policy: same-origin redirect retains ordinary headers and credentials; origin-changing redirect retains ordinary headers but strips every credential map key including X-Api-Key; redirect count is exactly enforced; 307/308 preserve method/body; credentials never reappear after returning to the original origin later in a redirect chain. Include HLS master/media playlists, encryption keys, and segments fetched from another origin, not only progressive redirects.

With an injected clock and deterministic loopback transport, verify each hop's response-header deadline (including a connected server that deliberately stalls headers), read inactivity only after headers, redirect/retry hops starting fresh deadlines while retaining counters/credential stripping, maxRetries=0 permits only the initial attempt, exact retry count/delay, all retryable status codes, no retry for cancellation/certificate/validation failures, Retry-After acceptance/rejection, and that redirect hops do not consume the retry budget. Disable OkHttp retryOnConnectionFailure so automatic recovery cannot bypass the managed budget.

- [ ] **Step 3: Prove failures**

Run:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
cd "$YL_REPO_ROOT/packages/yl_player_android/example/android"
./gradlew testDebugUnitTest --tests '*YlSourceAssessmentTest' --tests '*YlManagedRedirectInterceptorTest' --tests '*YlManagedRetryPolicyTest' --stacktrace
~~~

Expected: classes are missing and current default request properties forward headers without credential classification.

- [ ] **Step 4: Implement managed networking**

For platformDefault, delegate timeout/retry scheduling to Media3/OkHttp and claim no exact values, while still applying source-origin credential protection to every request. For managed, disable OkHttp automatic redirects and retryOnConnectionFailure. YlManagedRedirectInterceptor follows at most maxRedirects per original resource request chain across all retry attempts. This counter is independent of maxRetries and is never reset by retrying the request; only a new independent resource request gets a fresh counter. It builds follow-ups from immutable source-origin policy and preserves the credential-stripped latch across retries, so credentials never reappear after any origin-changing hop. For each initial, retry, or redirect HTTP hop, connectTimeout is the deadline from hop start until response headers, including DNS/connect/TLS/server-header wait. readTimeout applies only to body-read inactivity after headers. There is no call/overall timeout guarantee. OkHttp connectTimeout alone does not implement this header deadline: YlManagedHttpClient uses an injected monotonic clock and a cancellable per-hop deadline around header acquisition, cancels that deadline as soon as headers arrive, and enables the configured body inactivity timeout afterward. Ensure an OkHttp socket read timeout cannot impose an unintended earlier header deadline. A header-deadline cancellation is a transient timeout eligible for the existing retry policy; user/source cancellation is terminal and never retried. A new hop gets a fresh header deadline while resource-wide retry/redirect counters and credential stripping remain unchanged.

YlManagedRetryPolicy owns retries for idempotent GET/HEAD requests. maxRetries excludes the initial attempt. Retry only transient transport failures and HTTP 408/429/500/502/503/504; never retry source validation, cancellation, certificate/TLS trust failures, or other HTTP statuses. Retry index starts at 1 and delay is min(maxRetryDelay, baseRetryDelay * 2^(retryIndex - 1)), using saturating arithmetic and no jitter. Ignore malformed Retry-After and use the exponential formula. A valid Retry-After replaces the formula only when its computed nonnegative delay is <= maxRetryDelay; a valid larger value refuses that retry. Parse HTTP-date using an injected wall clock, then schedule the resulting duration using the monotonic clock. Emit one retry event only after scheduling an actual retry. Keep Media3 loader, HLS fallback, and watchdog recovery from independently retrying the same managed request outside this policy; source-level restart must preserve the current request budget until it succeeds or fails terminally.

Ordinary headers are added to all required HLS/progressive requests except reserved transport headers. Credential keys are added only while every redirect so far remained at the original normalized scheme/host/effective-port origin.

- [ ] **Step 5: Implement decoder evidence and honest buffer behavior**

On API 29+, combine MediaCodecInfo.isHardwareAccelerated/isSoftwareOnly with the exact decoder confirmed by onVideoDecoderInitialized. On API 24–28, names may inform hardwarePreferred ordering but never prove hardware mode or satisfy hardwareRequired; retain mode unknown and reject the strict request unless an independent positive evidence provider exists and is tested. systemDefault uses MediaCodecSelector.DEFAULT; hardwarePreferred prioritizes proven hardware while retaining system/software fallback; hardwareRequired allows only independently proven hardware candidates. It initializes against YlCandidateVideoOutput through the asynchronous activation stage and fails decoder.unavailable before commit when no evidence arrives before its deadline. An audio-only source has no video hardware requirement and must not wait forever for a video callback. Test audio-only strict requests, API 24–28 name-only evidence rejection, and API 29+ initialization/evidence mismatch.

Keep automatic/lowLatency/smoothPlayback in YlAdaptiveLoadControl as goals. Do not map bounded maxManagedBytes to DefaultAllocator.setTargetBufferSize and claim success. Return policy.unsupported until a separate hard-ceiling allocator/pipeline is proven by allocation tests.

- [ ] **Step 6: Pass and commit**

Run:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
cd "$YL_REPO_ROOT/packages/yl_player_android/example/android"
./gradlew testDebugUnitTest --tests '*YlSourceAssessmentTest' --tests '*YlManagedRedirectInterceptorTest' --tests '*YlManagedRetryPolicyTest' --tests '*YlRedirectCredentialPolicyTest' --tests '*YlHardwareCodecSelectorTest' --tests '*YlAdaptiveLoadControlTest' --tests '*YlPlaybackPolicyTest' --stacktrace
~~~

Expected: the named source, network, codec, load-control, and affected regression tests pass.

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
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

Set ExoPlayer handleAudioFocus=false and handleAudioBecomingNoisy=false for both audio policies. appManaged performs no shared audio ownership operations. For pluginManagedMediaPlayback, YlAudioFocusCoordinator alone requests/abandons focus, registers/unregisters one noisy receiver, and drives engine pause/resume/duck through typed callbacks. Track actual owned focus and participating Players; failed acquisition adds no owner, candidate preparation does not request focus, and a lease transfer preserves ownership until successful handoff or rollback. Count only participating managed playback, and abandon only after its final release. Test actual ExoPlayer construction flags as well as AudioManager/receiver calls so per-engine automatic management cannot bypass the coordinator. YlMetricsCollector receives timestamped engine signals and returns immutable typed messages; no platform-only counter enters AndroidMetricsMessage.

Run:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
cd "$YL_REPO_ROOT/packages/yl_player_android/example/android"
./gradlew testDebugUnitTest --tests '*YlAudioFocusCoordinatorTest' --tests '*YlMetricsCollectorTest' --tests '*YlLifecyclePolicyTest' --tests '*YlPlaybackHealthMonitorTest' --tests '*YlPlaybackStallWatchdogTest' --stacktrace
~~~

Expected: the named ownership, metrics, lifecycle, health, and watchdog suites pass.

- [ ] **Step 4: Commit**

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
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
- Rewrite/remove after replacement coverage: packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlAndroidChannelTest.kt and obsolete legacy Dart transport suites.
- Delete: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlAndroidChannel.kt
- Delete after extraction: packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3Player.kt

**Interfaces:**
- Android endorsed package is fully typed and independent of the legacy channel adapter.
- CI covers the minimum API 24 and target API 36 emulator using repository/loopback fixtures. API 35 is an optional compatibility job, not labeled current and not substituted silently for API 36.

- [ ] **Step 1: Add failing integration cases**

Tests must prove create capabilities, local HLS and progressive playback, Ready before/independent of First Frame, seek, stop/reload, newer-load cancellation, stale-session rejection, source replacement, same-origin credential redirect behavior, and multi-Player candidate failure restoring previous playback. Add immediate play after Load, initial buffering not completing Ready, candidate private-output first frame suppression, audio-only background suspension, delayed callback acknowledgement, API 24 name-only hardwareRequired rejection, and cancellation while awaiting decoder evidence. Hardware pressure remains device-only evidence and emulator success must not claim it.

- [ ] **Step 2: Add the native Android gate**

tool/check_native_android.sh first resolves its own script directory and discovers YL_REPO_ROOT from that directory, so invoking it from outside the checkout is safe. It then runs:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
cd "$YL_REPO_ROOT/packages/yl_player_android/example/android"
if [ "${YL_ANDROID_SKIP_JVM:-0}" != "1" ]; then
  ./gradlew testDebugUnitTest --stacktrace
fi
cd "$YL_REPO_ROOT/packages/yl_player/example"
flutter test integration_test/android_progressive_playback_test.dart -d "$YL_ANDROID_DEVICE_ID"
flutter test integration_test/android_hls_playback_test.dart -d "$YL_ANDROID_DEVICE_ID"
flutter test integration_test/android_session_replacement_test.dart -d "$YL_ANDROID_DEVICE_ID"
flutter test integration_test/android_multi_player_rollback_test.dart -d "$YL_ANDROID_DEVICE_ID"
~~~

The boot script accepts YL_ANDROID_API, creates an isolated AVD name, waits for sys.boot_completed, disables animations, and prints only the adb device ID.

- [ ] **Step 3: Add CI matrix and Pigeon drift gate**

Add an android-native-integration matrix for API 24 and 36. Run Pigeon drift once, JVM tests once, and emulator integration for both matrix entries. Separate the JVM gate from the emulator runner so check_native_android.sh does not repeat the JVM suite in each matrix entry; its standalone mode runs both, while YL_ANDROID_SKIP_JVM=1 is used only after the shared JVM job succeeded. Keep timeouts explicit and upload adb/logcat only on failure.

- [ ] **Step 4: Remove old transport code and prove no string protocol remains**

Run:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
rg -n 'MethodChannel|EventChannel|invokeMethod|onMethodCall|when \(call.method\)|"command"|"create"|"dispose"' packages/yl_player_android/lib packages/yl_player_android/android/src/main
~~~

Expected: no handwritten Flutter channel or string command dispatch remains; generated Pigeon internals may contain BasicMessageChannel names.

- [ ] **Step 5: Run full Android and foundation gates**

Run:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
sh packages/yl_player_android/tool/check_pigeon.sh
sh tool/check_foundation.sh
cd "$YL_REPO_ROOT/packages/yl_player_android/example/android"
./gradlew testDebugUnitTest --stacktrace
~~~

With an emulator ID:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
YL_ANDROID_DEVICE_ID=<device-id> sh tool/check_native_android.sh
~~~

Expected: deterministic codegen, analysis, Dart suites, all JVM tests, and emulator tests pass.

- [ ] **Step 6: Commit**

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
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
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
rg -n 'EventChannel|MethodChannel|stackTraceToString|Throwable\.message|platformDiagnostic' packages/yl_player_android
rg -n 'activePlayerId|players\.values.*deactivate|setDefaultRequestProperties\(.*credentials' packages/yl_player_android/android/src/main
rg -n '[T]ODO|[F]IXME|[T]BD|[X]XX' docs/superpowers/plans/2026-09-06-player-v2-android.md
~~~

Expected: only generated Pigeon transport references Flutter channels; other scans return no production violations or planning gaps.

- [ ] **Step 3: Run final phase evidence**

Run:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
sh packages/yl_player_android/tool/check_pigeon.sh
sh tool/check_foundation.sh
cd "$YL_REPO_ROOT/packages/yl_player_android/example/android"
./gradlew testDebugUnitTest --stacktrace
cd "$YL_REPO_ROOT"
git diff --check
~~~

Expected: all pass.

- [ ] **Step 4: Record deferred evidence**

Update docs/verification/player-v2-migration.md with API levels actually tested, test counts, codegen result, and explicit unverified items: physical Android TV decoder pressure, long playback soak, reconnect endurance, and device-specific MediaCodec evidence.

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
git add docs/verification/player-v2-migration.md
git commit -m "docs: record android v2 verification"
~~~
