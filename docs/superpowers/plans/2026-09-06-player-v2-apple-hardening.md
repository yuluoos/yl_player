# Player v0.2 Apple Core Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decompose the consolidated Apple playback core, implement truthful source assessment and strict managed-network/bounded-buffer/hardware-required behavior, make audio ownership explicit, and align diagnostics, metrics, and geometry across iOS and macOS.

**Architecture:** The shared managed fallback becomes a thin session orchestrator over demux, video, audio, presentation, recovery, and buffer-ledger components. One pure route assessor decides AVPlayer versus managed fallback and is reused by assess and load. AVPlayer remains the compatibility route but rejects guarantees it cannot prove. Managed fallback owns exact networking and queue budgets, and VideoToolbox supplies positive hardware evidence before a hardware-required video session commits.

**Tech Stack:** Swift 5.9, iOS 15+, macOS 12+, AVFoundation, VideoToolbox, CoreMedia/CoreVideo, AVFAudio/AudioToolbox, Network, FFmpeg bridge, XCTest through the Flutter example runners.

**Spec:** docs/superpowers/specs/2026-09-06-player-v2-architecture-design.md

## Global Constraints

- Complete the Apple consolidation plan first and begin from a fully green shared package, including independent Flutter consumer linkage. Resolve paths from the active checkout/worktree in every execution shell:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
~~~
- Each extraction commit must preserve all existing test results and behavioral constants before any new behavior is added.
- Keep the managed fallback orchestrator under 450 nonblank lines after decomposition. It coordinates components; it does not parse, decode, schedule, render audio, or implement retry policy itself.
- AVPlayer reports decoder mode unknown for every session.
- AVPlayer rejects managed networking, bounded buffering, and hardwareRequired. It may still satisfy platformDefault networking and automatic/lowLatency/smoothPlayback goals.
- Managed network applies only when every network request for the selected route goes through package-owned byte sources. v0.2 retains FFmpeg demuxers matroska,flv only. Managed HLS/MP4/MOV/AVI/MPEG routes are unsupported; reject their strict requests before commit. A header-controlled AVPlayer HLS route remains a platformDefault compatibility path, not a managed fallback.
- Credentials are source-origin-only across all redirects and HLS child resources under both platformDefault and managed networking. Ordinary headers may follow required cross-origin resources. An opaque route must reject credential-bearing requests it cannot secure; platformDefault relaxes timing/retry guarantees, never credential safety.
- Bounded maxManagedBytes bounds assigned retained media payload, not process RSS or every heap allocation. It covers retained package-owned network/ring media payload, compressed packets (including queued closures/submissions), decoded frames retained for scheduling, and scheduled audio payload until completion/cancellation releases it. It excludes spare collection capacity/metadata, OS/TLS buffers, FFmpeg transient allocations, VideoToolbox internal surfaces, AVAudioEngine internals, and GPU memory. Exclusions cannot be used to hide copied or deferred media payload.
- A bounded route must reserve from one shared ledger before retaining bytes/packets/frames/audio. Failure to reserve applies backpressure or rejects the load; it never temporarily exceeds the limit.
- hardwareRequired for a video session commits only after VTSessionCopyProperty proves hardware acceleration. Unknown is rejection, not success.
- App-managed audio is the default and performs no global audio-session activation/category/deactivation.
- Plugin-managed audio deactivates only an activation acquired by this package and only after the final plugin-managed Player across all Flutter engine registries releases it. Player/session state remains instance-scoped; only the process-wide AVAudioSession lease coordinator is shared.
- Every behavior change has a focused failing unit/integration test before implementation.

---

## File and Responsibility Map

- Session/decomposition:
  - Shared/Session/YlManagedPlaybackSession.swift
  - Shared/FFmpeg/YlDemuxPipeline.swift
  - Shared/VideoToolbox/YlVideoPipeline.swift
  - Shared/Audio/YlAudioPipeline.swift
  - Shared/Clock/YlPresentationCoordinator.swift
  - Shared/Session/YlRecoveryCoordinator.swift
  - Engines/ManagedFallback/YlFallbackBackend.swift as orchestrator only
- Policy/routing:
  - Shared/SourceRouting/YlSourceAssessment.swift
  - Shared/SourceRouting/YlEngineRouter.swift
  - Shared/Network/YlManagedRequestPolicy.swift
  - Shared/Network/YlOriginCredentialPolicy.swift
  - Shared/HLS/YlHlsResourceLoader.swift and YlHlsMediaProxy.swift for credential-safe platformDefault HLS only
- Buffer/hardware:
  - Shared/FFmpeg/YlManagedBufferLedger.swift
  - Shared/FFmpeg/YlBoundedBufferPlan.swift
  - Shared/VideoToolbox/YlHardwareDecoderEvidence.swift
- Audio:
  - Shared/Audio/YlAudioOwnershipCoordinator.swift
  - iOS/YlIosAudioSession.swift
  - macOS/YlMacosAudioSession.swift
- Observability:
  - Shared/Metrics/YlMetricsCollector.swift
  - Shared/Metrics/YlVideoGeometryResolver.swift
  - Shared/Diagnostics/YlAppleSafeDiagnostics.swift

---

### Task 1: Characterize and decompose the managed fallback

**Files:**
- Modify: packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/ManagedFallback/YlFallbackBackend.swift
- Create:
  - Shared/Session/YlManagedPlaybackSession.swift
  - Shared/FFmpeg/YlDemuxPipeline.swift
  - Shared/VideoToolbox/YlVideoPipeline.swift
  - Shared/Audio/YlAudioPipeline.swift
  - Shared/Clock/YlPresentationCoordinator.swift
  - Shared/Session/YlRecoveryCoordinator.swift
- Split/rename tests in packages/yl_player/example/ios/RunnerTests and packages/yl_player/example/macos/RunnerTests.

**Interfaces:**
- YlFallbackBackend implements YlPlaybackBackend and delegates to six focused components.
- Components communicate with immutable session generation/ID values and typed callbacks. Preserve the consolidation per-Player acknowledged callback FIFO, ID-only load-reply plus authoritative state-callback barrier, ready milestone ordering, and firstFrame from committed texture output only.
- No policy threshold or clock equation changes.

- [ ] **Step 1: Add seam-level characterization tests**

Before moving code, add tests for:

- open prepare/commit/cancel and old-session rollback;
- demux EOF, transient read error, invalid packet, and cancellation;
- VideoToolbox configure/reconfigure, stale-generation frame drop, decode error;
- audio configure/convert/backpressure/flush/underrun;
- presentation frame choice at 0.25x, 1x, 2x, and 4x;
- seek flush ordering across demux/video/audio/presentation;
- live reconnect scheduling, cancellation, success, exhaustion;
- stop/dispose while each pipeline stage is active.

All tests use the current backend first so they characterize existing behavior.

- [ ] **Step 2: Capture size and behavioral constants**

Run:

~~~bash
awk 'NF { count++ } END { print count+0 }' packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/ManagedFallback/YlFallbackBackend.swift
sh packages/yl_player_apple/tool/diff_behavioral_constants.sh
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh --unit-only
~~~

Expected: baseline passes and captures the pre-extraction line count/constants.

- [ ] **Step 3: Extract in dependency order**

Extract without behavior changes in this order:

1. YlDemuxPipeline owns opened media, packet reading, track selection, seek, and cancellation token.
2. YlVideoPipeline owns format description, decoder, decoded frame callback, and generation filtering.
3. YlAudioPipeline owns converter/renderer configuration, packet submission, volume/rate, and underrun observation.
4. YlPresentationCoordinator owns media clock, frame scheduler, display driver, first-frame gate, and texture publication.
5. YlRecoveryCoordinator owns reconnect/reopen state, delay policy, operation generation, and terminal exhaustion.
6. YlManagedPlaybackSession composes the five components and exposes typed lifecycle/command methods.

Keep domain callbacks ordered through the existing host/reducer queue. A prepared candidate may inspect/create a decoder but may not publish texture/state milestones. Publish ready (or a full state with immutable monotonic loadToReady evidence) before playing or later rebuffering; buffering alone never proves ready. Reconfiguration/recovery retains the committed session milestone cache.

Each component receives dependencies through protocols; no singleton/global state.

- [ ] **Step 4: Reduce the backend to orchestration**

YlFallbackBackend stores one active YlManagedPlaybackSession and one prepared candidate. It forwards prepare/commit/play/pause/seek/constraints/stop/dispose and translates component callbacks to YlAppleStateReducer actions. It contains no DispatchSource timer, FFmpeg call, VTDecompressionSession call, AVAudioPCMBuffer manipulation, frame queue, or retry-delay calculation.

- [ ] **Step 5: Run parity gates after every extraction commit**

For each of the six extraction commits run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh --unit-only
sh packages/yl_player_apple/tool/diff_behavioral_constants.sh
~~~

Expected: all pass with no new constant allowlist entries.

- [ ] **Step 6: Verify boundary and commit final orchestration change**

Run:

~~~bash
rg -n 'av_read_frame|VTDecompressionSession|AVAudioPCMBuffer|DispatchSource|scheduleLiveReconnect' packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/ManagedFallback/YlFallbackBackend.swift
~~~

Expected: no matches.

~~~bash
git add packages/yl_player_apple/darwin packages/yl_player/example/ios/RunnerTests packages/yl_player/example/macos/RunnerTests
git commit -m "refactor(apple): decompose managed fallback"
~~~

### Task 2: Make source assessment the single routing authority

**Files:**
- Create:
  - packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/SourceRouting/YlSourceAssessment.swift
  - packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/SourceRouting/YlEngineRouter.swift
- Modify:
  - Shared/SourceRouting/YlSourceRouter.swift
  - Shared/Session/YlAppleSessionCoordinator.swift
  - Shared/Session/YlApplePlayerHost.swift
  - packages/yl_player_apple/lib/src/apple_player.dart
  - packages/yl_player_apple/lib/src/apple_codec.dart
  - packages/yl_player_apple/test/apple_player_test.dart
  - packages/yl_player_apple/test/apple_codec_test.dart
- Create/modify assessment tests in both RunnerTests.

**Interfaces:**
- assess and load call the same pure YlEngineRouter.assess.
- Assessment returns compatible/incompatible/requiresInspection, candidate engine, satisfied requirement IDs, limitation IDs, and typed rejection.

- [ ] **Step 1: Write the complete route matrix**

Use table-driven tests for iOS and macOS:

- Android content source is incompatible/source.invalid.
- Local HLS/MP4/MOV and headerless network HLS/MP4/MOV use AVPlayer for default policies; report decoder.modeUnknown and network.systemStackOpaque where applicable.
- Proven local/network Matroska and network FLV paths use managed fallback with codec/stream-intent inspection matching current support. Preserve the current network-Matroska live rejection. WebM or local FLV may use the same demuxers only after inspection and focused playback evidence; do not infer codec support from a container extension.
- AVI/MPEG-TS/MPEG-PS are unsupported by the pinned fallback artifact; do not return a compatible fallback candidate. Reject known unsupported routes with a stable container failure, and reject strict requirements with policy.unsupported before commit.
- Managed network, bounded buffering, and hardwareRequired requests on HLS/MP4/MOV are policy.unsupported in v0.2. Do not add a managed-HLS loader or change the FFmpeg allowlist in this plan.
- Default-policy credential/header-bearing HLS uses only the proven package-controlled loader/proxy route that applies source-origin filtering to every child/redirect. Unsupported URI forms or uncontrolled child requests reject instead of falling through to a bare AVURLAsset URL.
- Header/credential-bearing progressive AVPlayer routes reject unless all outgoing request metadata and redirect credentials can be enforced. Matroska/FLV use controlled byte sources under either network policy. Test custom credential keys separately from ordinary headers.
- automatic format with no reliable extension is requiresInspection. Inspection uses bounded package-owned I/O, preserves request credential rules, and cannot commit an engine violating policy.
- managed network forces a proven managed byte-source route or incompatible; bounded forces a proven managed fallback or incompatible.
- hardwareRequired rejects AVPlayer and requires managed-fallback inspection; unsupported codec discovery is decoder.unsupported, missing positive hardware evidence is decoder.unavailable.
- audio-only inspected sources need no video hardware evidence; do not claim success for a container the demuxer cannot open.
- source reachability is never claimed by assess.

- [ ] **Step 2: Prove the existing split logic fails**

Run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh --unit-only
~~~

Expected: new route tests reveal assess/load use different or absent policy decisions.

- [ ] **Step 3: Implement stable requirement/limitation IDs**

Use these strings in transport results:

- requirements: network.platformDefault, network.managed, buffer.automatic, buffer.lowLatency, buffer.smoothPlayback, buffer.bounded, decoder.systemDefault, decoder.hardwarePreferred, decoder.hardwareRequired.
- limitations: source.requiresInspection, codec.requiresInspection, decoder.modeUnknown, buffer.osMemoryExcluded, network.systemStackOpaque.

Map transport strings explicitly into validated YlRequirementId/YlLimitationId public value types; preserve unknown safe extension IDs without treating them as fulfilled built-in guarantees. Do not place source locators or codecs copied from untrusted headers into these lists.

- [ ] **Step 4: Reuse the decision during load**

YlAppleSessionCoordinator first validates the public descriptor, calls router.assess, throws the assessment rejection when incompatible, and passes the exact candidate decision into prepare. If requiresInspection, the candidate may refine it but may not choose an engine that violates requested guarantees.

Delete the consolidation-only blanket managed/bounded/hardwareRequired rejection from the Dart adapter. Route assess and load to the native authority and preserve native typed failures. Replace the temporary rejection test with generated-transport tests proving a known supported Matroska/FLV managed/bounded request reaches native and returns a committed session; separately require unsupported HLS/MP4 strict requests to reject. Include load reply/callback ordering so policy success cannot return before matching committed state is installed.

Run flutter test packages/yl_player_apple/test and both native route matrices before committing. Stage enforcement availability truthfully: until Tasks 3/4/5 wire their native mechanisms, unsupported requirements still reject natively; pure routing tests inject availability to verify eligible routes and Dart transport tests use an explicit enforcing fake. Enable each production guarantee only with its focused integration test. Final Task 8 success tests for supported managed/bounded fixtures may not accept policy.unsupported.

- [ ] **Step 5: Pass and commit**

Run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh --unit-only
~~~

Expected: route matrix and all prior tests pass.

~~~bash
git add packages/yl_player_apple/darwin packages/yl_player/example/ios/RunnerTests packages/yl_player/example/macos/RunnerTests
git add packages/yl_player_apple/lib packages/yl_player_apple/test
git commit -m "feat(apple): unify source assessment routing"
~~~

### Task 3: Enforce managed networking and origin-scoped credentials

**Files:**
- Create:
  - Shared/Network/YlManagedRequestPolicy.swift
  - Shared/Network/YlOriginCredentialPolicy.swift
- Create/update documentation: docs/policies.md, docs/platform-support.md
- Modify:
  - Shared/Network/YlNetworkByteSource.swift
  - Shared/Network/YlNetworkRequestPolicy.swift
  - Shared/HLS/YlHlsHeaderPolicy.swift
  - Shared/HLS/YlHlsManifestRewriter.swift
  - Shared/HLS/YlHlsMediaProxy.swift
  - Shared/HLS/YlHlsResourceLoader.swift
  - Shared/SourceRouting/YlEngineRouter.swift
  - Engines/ManagedFallback/YlFallbackBackend.swift
- Add network/HLS tests in iOS and macOS RunnerTests.

**Interfaces:**
- Managed byte-source policy enforces per-attempt connect/read deadlines, retry delays/count, redirect count, and credential origin. The credential filter is also used by platformDefault byte/HLS routes; those routes promise no exact network timing.
- All child requests carry an immutable request context with original origin and whether credential forwarding is still allowed.

- [ ] **Step 1: Write failing URLProtocol/loopback tests**

Cover:

- initial request receives ordinary headers and credentials;
- same-origin redirect retains both;
- scheme/host/effective-port origin change keeps ordinary headers and strips every credential key;
- once stripped, credentials do not reappear if a later redirect returns to the original origin;
- platformDefault controlled HLS master, variant, media playlist, key, init segment, and media segment use the same credential rule; managed HLS rejects before a network open;
- platformDefault progressive requests cannot bypass filtering through bare AVPlayer; supported byte routes succeed and unsupported controlled-routing requests reject;
- relative child URI remains same origin;
- maxRedirects 0 rejects the first redirect;
- connect deadline runs from each HTTP attempt/hop start until response headers, including DNS, connection, TLS, and server wait; read deadline measures inactivity between body progress events; redirect/retry attempt transitions cancel old timers; neither field promises an overall load deadline;
- maxRetries excludes the initial attempt, redirects have their own count, retries cannot restore stripped credentials, and fake-clock tests assert capped exponential backoff without jitter;
- only idempotent GET/HEAD transient transport failures and HTTP 408/429/500/502/503/504 retry; authentication, certificate/validation errors, unsupported redirects, cancellation, and permanent failures do not;
- valid Retry-After is honored only within the configured maximum retry delay, otherwise do not retry early; test absent, malformed, past, excessive, and HTTP-date values;
- cancellation stops retry and no callback arrives for a replaced session;
- public failure contains diagnostic ID but no URL/header/value.

- [ ] **Step 2: Run and observe current leakage/semantic failures**

Run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh --unit-only
~~~

Expected: new tests fail because existing header policy does not classify arbitrary credential keys consistently through every HLS child/redirect.

- [ ] **Step 3: Implement immutable request context**

Use:

~~~swift
struct YlRequestOrigin: Equatable {
  let scheme: String
  let host: String
  let effectivePort: Int
}

struct YlManagedRequestContext {
  let sourceOrigin: YlRequestOrigin
  let ordinaryHeaders: [String: String]
  let credentials: [String: String]
  let credentialsAllowed: Bool
  let redirectsFollowed: Int
}
~~~

Normalize scheme/host case and default ports. A redirect to a different origin returns a context with credentialsAllowed false permanently. Header comparison is case-insensitive while preserving original outgoing spelling.

- [ ] **Step 4: Centralize timeout/retry/redirect enforcement**

YlManagedRequestPolicy owns timers and request retries for managed Matroska/FLV byte sources. A connect timer covers each HTTP attempt/hop from start through response headers, including DNS/connection/TLS/server wait; the post-header read inactivity timer resets only on body progress. Internal attempt IDs fence stale timers/completions. maxRetries counts additional attempts after the initial one; maxRedirects is a separate budget for the original resource request across its redirects and retries, not a fresh allowance per retry. Retries never reset credentialsAllowed, and HLS child contexts inherit any prior stripping. Use min(maxRetryDelay, baseRetryDelay * 2^(retryIndex - 1)) with overflow-safe arithmetic and no jitter for eligible idempotent GET/HEAD transient errors/408/429/500/502/503/504. A valid nonnegative Retry-After seconds/date replaces the exponential delay when it fits maxRetryDelay; if it exceeds the cap, fail without retrying early. Absent/malformed values use the formula, and a past date means zero delay. Inject time for deterministic HTTP-date tests. No overall load-timeout guarantee is inferred from connect/read fields.

A session reconnect is permitted only for a distinct explicit recovery intent under the existing bounded reconnect policy; it must not restart the same exhausted original resource request with a fresh retry/redirect budget or multiply an active request retry loop. Preserve the exhausted request identity/budget through any internal reopen until success or terminal failure; a new user load is a new request intent. Keep existing reconnect ordering/constants unchanged and count request retries versus session reconnects separately. platformDefault retains existing network scheduling and exposes no exact policy guarantee, while reusing immutable credential filtering. HLS loader/proxy remains platformDefault-only. Update these semantics and rejection outcomes in docs/policies.md and docs/platform-support.md.

- [ ] **Step 5: Run loopback integration**

Add successful managed Matroska/FLV byte-source cases, platformDefault HLS credential/redirect cases, and deterministic policy.unsupported assertions for managed HLS/MP4 to the existing authenticated loopback servers. Reject unsupported strict formats before issuing upstream requests. Run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh
~~~

Expected: both platform unit and integration suites pass.

- [ ] **Step 6: Commit**

~~~bash
git add packages/yl_player_apple/darwin packages/yl_player/example
git add docs/policies.md docs/platform-support.md
git commit -m "feat(apple): enforce managed request policy"
~~~

### Task 4: Enforce one hard package-managed buffer ledger

**Files:**
- Create:
  - Shared/FFmpeg/YlManagedBufferLedger.swift
  - Shared/FFmpeg/YlBoundedBufferPlan.swift
- Modify:
  - Shared/FFmpeg/YlByteRingBuffer.swift
  - Shared/FFmpeg/YlBoundedPacketQueue.swift
  - Shared/FFmpeg/YlFallbackBufferBudget.swift
  - Shared/FFmpeg/YlDemuxPipeline.swift
  - Shared/VideoToolbox/YlVideoPipeline.swift
  - Shared/Clock/YlFrameScheduler.swift
  - Shared/Audio/YlAudioPipeline.swift
  - Shared/Audio/YlAudioRenderer.swift
  - Shared/Metrics/YlMetricsCollector.swift
  - Shared/SourceRouting/YlEngineRouter.swift
- Add ledger/buffer integration tests in both RunnerTests.

**Interfaces:**
- One Player-scoped ledger tracks networkCache, compressedPackets, queuedVideoFrames, and scheduledAudio payload reservations across active, prepared, seeking, and reconnecting generations. Candidate preparation cannot allocate a second independent budget. Different per-load bounds are checked against all retained payload: reserve within the stricter active/candidate boundary during overlap or reject the candidate without breaking old playback.
- currentBytes never exceeds maxBytes.
- Duration thresholds are enforced alongside bytes and surfaced as managed metrics.

- [ ] **Step 1: Write deterministic ledger tests**

Assert reserve/release is thread-safe, rejects overflow and integer overflow, category counts sum to total, and each token releases exactly once. A generation reset invalidates old work but does not erase reservations for still-retained payload. Reservations disappear only after the owning object/queued closure/output submission releases them or cancellation completion proves retention ended. Delay old callbacks through seek/reconnect and assert their bytes remain charged. peakBytes must never exceed maxBytes under concurrent randomized reserve/release sequences.

- [ ] **Step 2: Write end-to-end bounded pipeline tests**

With a 16 MiB assigned payload budget, feed oversized network chunks, compressed packets, decoded frames, and audio buffers. Assert reservation occurs before retention or dispatch-queue submission, current/peak remain <= 16 MiB, and bounded working sets still make playback progress. Hold asynchronous decoder/audio completions across cancellation/seek/reconnect: old retained payload remains charged until release, then drains to zero. Account for copied Data/PCM payload independently and transfer a single token only when ownership truly transfers without a second copy. Empty ring spare capacity is excluded as documented; retained rewind bytes still count. Assert active plus candidate payload cannot independently consume two 16 MiB budgets, and reported managedBufferedBytes matches the ledger.

Also test a requested budget below the computed minimum for one decoder frame plus audio/network safety margin is rejected as policy.unsupported before commit.

- [ ] **Step 3: Prove current target sizing is insufficient**

Run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh --unit-only
~~~

Expected: new tests fail because independent queue targets can exceed a shared maxManagedBytes.

- [ ] **Step 4: Implement allocation tokens**

YlManagedBufferLedger.reserve(category:bytes:generation:) returns a token only when total + bytes <= max. The token releases exactly once in deinit or explicit release after the associated retention ends. Queues reserve before copying/retaining or capturing payload in async closures, and carry the token into every queued submission. A decoder output frame is charged before the package retains it beyond the callback; reject/drop without retention when no token is available. Scheduled PCM tokens live through playback completion or confirmed stop/reset cancellation, not merely through the scheduling call. Generation invalidation drops admission for old work but does not zero live tokens. Never block the same serial executor whose completions release the budget; pause producer admission and resume from release notifications. Reserve minimum per-stage working sets/watermarks to avoid network cache starving decoder/audio progress.

YlBoundedBufferPlan validates minDuration <= maxDuration and partitions only scheduling watermarks, not independent byte ceilings. Runtime duration checks must drive producer admission and startup/rebuffer watermarks as specified by the shared bounded contract; testing constructor validation and byte totals alone is insufficient. Add deterministic queue-timestamp tests for both duration bounds, rate changes, seek, EOF, and insufficient data so bounded playback cannot stall permanently waiting for a watermark the source cannot supply. The ledger max is the sole byte authority. Reject plans unable to retain one maximum expected frame plus minimum packet/audio/network working sets based on inspected format.

- [ ] **Step 5: Document exclusion scope in assessment**

A compatible bounded assessment includes requirement buffer.bounded and limitation buffer.osMemoryExcluded. AVPlayer remains incompatible. Common metrics set managedBufferedDuration/managedBufferedBytes only for this route; other routes leave them null.

- [ ] **Step 6: Pass and commit**

Run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh
~~~

Expected: ledger unit/property tests and real fixture playback pass without exceeding requested bounds.

~~~bash
git add packages/yl_player_apple/darwin packages/yl_player/example
git commit -m "feat(apple): enforce bounded managed buffers"
~~~

### Task 5: Require positive VideoToolbox hardware evidence before commit

**Files:**
- Create: Shared/VideoToolbox/YlHardwareDecoderEvidence.swift
- Modify:
  - Shared/VideoToolbox/YlVideoToolboxDecoder.swift
  - Shared/VideoToolbox/YlVideoPipeline.swift
  - Shared/Session/YlManagedPlaybackSession.swift
  - Shared/Session/YlAppleSessionCoordinator.swift
  - Shared/SourceRouting/YlEngineRouter.swift
  - Shared/Metrics/YlMetricsCollector.swift
- Add hardware-evidence tests in both RunnerTests.

**Interfaces:**
- Decoder evidence is unknown/hardware/software with a safe decoder identity.
- hardwareRequired video candidate is not committed while evidence is unknown.

- [ ] **Step 1: Write evidence and commit-gate tests**

Inject a VT session property reader. Test CFBoolean true -> hardware, false -> software, missing/error -> unknown. Test:

- hardwareRequired + hardware commits;
- hardwareRequired + software fails decoder.unavailable and restores old session;
- hardwareRequired + unknown timeout fails and restores;
- hardwarePreferred + unknown commits with decoderMode unknown;
- AVPlayer + hardwareRequired is never selected;
- audio-only inspection imposes no video hardware requirement; an implemented audio-only route can commit with decoder mode unknown, while an unsupported audio-only route rejects truthfully for its actual capability limitation;
- late evidence from a cancelled candidate is ignored;
- decoder recreation after seek, reconnect, format change, or recovery rechecks hardware evidence before admitting new frames; a hardwareRequired committed session fails safely rather than switching to unknown/software;
- candidate decoded output never publishes firstFrame/public texture, and committed reconfiguration cannot resolve firstFrame twice.

- [ ] **Step 2: Prove current decoder boolean is not enough**

Run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh --unit-only
~~~

Expected: tests fail because current paths do not gate commit on VTSessionCopyProperty evidence.

- [ ] **Step 3: Implement evidence reader**

After VTDecompressionSession creation, call VTSessionCopyProperty using the existing compatible "UsingHardwareAcceleratedVideoDecoder" as CFString key on iOS 15/16. The named SDK constant kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder is iOS 17+; use it only behind a matching availability check, or retain the same CFString key for the shared reader. Preserve the existing compatible RequireHardwareAcceleratedVideoDecoder key path. Accept hardware only for a CFBoolean value equal to kCFBooleanTrue, with an explicit CF type check; an arbitrary numeric/bridged value is not positive evidence. Treat unavailable property, type mismatch, or error as unknown. Build with IPHONEOS_DEPLOYMENT_TARGET=15.0 to catch availability errors and exercise injected iOS 15/16 property outcomes. Safe decoder identity is an allowlisted framework/decoder name, never a filesystem path or source data.

- [ ] **Step 4: Integrate candidate gating**

During prepare, inspect enough media to create the decoder session off the public texture path while holding the same retained-payload reservations used by the active/candidate ledger. For hardwareRequired, await evidence within the existing candidate deadline before willCommit/didCommit. On rejection dispose the candidate and execute rollback. Do not emit loading state for an uncommitted candidate.

- [ ] **Step 5: Add simulator/device-honest integration**

On Simulator, run a fixture with hardwareRequired and assert either a committed state whose decoderMode is hardware or decoder.unavailable; unknown/software must never commit. Record Simulator as policy-honesty evidence, not physical hardware performance evidence.

- [ ] **Step 6: Pass and commit**

Run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh
~~~

Expected: all policy and playback tests pass.

~~~bash
git add packages/yl_player_apple/darwin packages/yl_player/example
git commit -m "feat(apple): gate sessions on decoder evidence"
~~~

### Task 6: Implement explicit shared audio ownership

**Files:**
- Create:
  - Shared/Audio/YlAudioOwnershipCoordinator.swift
  - Shared/Audio/YlAudioSessionDriving.swift
  - iOS/YlIosAudioSession.swift
  - macOS/YlMacosAudioSession.swift
- Modify:
  - Shared/Session/YlApplePlayerRegistry.swift
  - Shared/Session/YlAppleSessionCoordinator.swift
  - Engines/AvPlayer/YlAvPlayerBackend.swift
  - Shared/Audio/YlAudioPipeline.swift
- Add audio ownership/interruption tests to both RunnerTests.

**Interfaces:**
- All registries share one process-wide reference-counted YlAudioOwnershipCoordinator for AVAudioSession. A lease key contains unique engine/registry identity plus Player identity; engine detach releases only its own leases.
- appManaged never changes global session state.
- pluginManagedMediaPlayback acquires before play and releases on last stop/dispose.

- [ ] **Step 1: Write failing ownership matrix**

With fake audio session driver assert:

- appManaged create/load/play/pause/stop/dispose makes zero driver calls;
- first plugin-managed play configures media playback and activates once;
- second managed Player increments ownership without another activation, including a Player in a second FlutterEngine/registry;
- disposing/detaching the first registry does not deactivate audio while another registry retains a lease;
- pause retains ownership, while stop/dispose releases that Player;
- last release deactivates with notifyOthers only if this coordinator activated;
- failed activation rejects play and does not increment ownership;
- appManaged never asks the driver to infer global activation ownership; an external app activation is not claimed as a plugin lease;
- interruption begins pauses managed playback and interruption end does not autoplay unless the prior session intended playback;
- macOS driver is a no-global-session implementation but still tracks plugin-owned output lifecycle.

- [ ] **Step 2: Prove current behavior is implicit**

Run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh --unit-only
~~~

Expected: ownership tests fail because current backends do not distinguish app and plugin ownership.

- [ ] **Step 3: Implement coordinator**

Provide one process-wide coordinator shared by every plugin registry, serializing on main actor. Key leases by (engineIdentity, playerIdentity), record successful package-owned activation calls, and inject the shared coordinator for cross-registry tests. Do not infer ownership from isOtherAudioPlaying or a presumed readable global active flag. iOS plugin-managed activation sets category playback with moviePlayback mode and activates without background entitlement changes. Release deactivates only after the last lease across all registries; engine detach releases only that engine's leases. App-managed bypasses the coordinator entirely.

Acquire through the same path for explicit play, autoplay after commit, and interruption/lifecycle resume. Failed preparation cannot acquire or release an active session's lease; failed activation does not increment count or start output. Stop/dispose/output failure cleanup releases each owned lease exactly once. Preserve playback intent through interruption and never resurrect a stopped/replaced Player. Hosts choosing appManaged retain responsibility for any other plugins' shared-session coordination.

Do not add background audio, remote command center, now playing metadata, or global route selection.

- [ ] **Step 4: Pass and commit**

Run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh --unit-only
~~~

Expected: ownership/interruption and all playback tests pass.

~~~bash
git add packages/yl_player_apple/darwin packages/yl_player/example/ios/RunnerTests packages/yl_player/example/macos/RunnerTests
git commit -m "feat(apple): make audio ownership explicit"
~~~

### Task 7: Normalize geometry, metrics, and diagnostic boundaries

**Files:**
- Create:
  - Shared/Metrics/YlMetricsCollector.swift
  - Shared/Metrics/YlVideoGeometryResolver.swift
- Modify:
  - Shared/Diagnostics/YlAppleSafeDiagnostics.swift
  - Shared/Diagnostics/YlAppleFailureMapper.swift
  - Engines/AvPlayer/YlAvPlayerBackend.swift
  - Shared/VideoToolbox/YlVideoPipeline.swift
  - Shared/Audio/YlAudioPipeline.swift
  - Shared/Session/YlAppleStateReducer.swift
- Add focused tests in both RunnerTests.

**Interfaces:**
- Geometry includes encoded/display sizes, pixel aspect ratio, and normalized rotation.
- Common metrics are nullable until observed.
- Static capability/track/geometry/decoder fields never appear in periodic deltas.

- [ ] **Step 1: Write geometry tests**

Cover clean aperture, non-square pixel aspect, 90/270 rotation swapping display axes, AVAssetTrack preferred transform, absent format metadata, and invalid zero/negative data. Assert AVPlayer decoder mode remains unknown.

- [ ] **Step 2: Write metric semantic tests**

Assert null before observation versus measured zero, load-to-ready/first-frame clocks use monotonic duration, rebuffer intervals do not double count, reconnect increments once per actual reconnect, managed buffer values only exist on bounded managed routes, and no selected bitrate/platform-only counters enter common metrics.

- [ ] **Step 3: Write diagnostic fuzz tests**

Generate strings containing URLs, IPv6 hosts, query tokens, percent-encoded secrets, headers with mixed case, cookies, bearer/basic credentials, file paths, and Swift stack frames. Assert public failure/event/state/toString-equivalent payloads contain none and remain <= 512 characters.

- [ ] **Step 4: Implement resolvers/collector/redaction**

AVPlayer resolver combines presentationSize, naturalSize/preferredTransform, and format-description clean-aperture/PAR where available. Managed resolver uses decoded format description. rotationDegrees is only the clockwise transform still unapplied to the texture; report zero if native output already oriented pixels. Normalize rotation to 0/90/180/270 and reject invalid geometry rather than emitting zero sizes.

One YlMetricsCollector per session receives typed signals. One YlAppleSafeDiagnostics entrypoint processes every error before logging or transport. Remove ad hoc localizedDescription and debugDescription transport.

- [ ] **Step 5: Pass and commit**

Run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh
~~~

Expected: geometry, metric, fuzz, and integration suites pass.

~~~bash
git add packages/yl_player_apple/darwin packages/yl_player/example
git commit -m "refactor(apple): normalize playback observability"
~~~

### Task 8: Add strict-policy integration coverage and finish the phase

**Files:**
- Create:
  - packages/yl_player/example/integration_test/apple_managed_network_test.dart
  - packages/yl_player/example/integration_test/apple_bounded_buffer_test.dart
  - packages/yl_player/example/integration_test/apple_hardware_required_test.dart
  - packages/yl_player/example/integration_test/apple_session_replacement_test.dart
  - packages/yl_player/example/integration_test/apple_audio_policy_test.dart
- Modify: tool/check_native_ios.sh
- Modify: tool/check_native_macos.sh
- Modify: .github/workflows/ci.yml
- Modify: docs/verification/player-v2-migration.md

**Interfaces:**
- Automated Apple gates prove strict requests are enforced or rejected and do not silently degrade.

- [ ] **Step 1: Add platform-neutral integration assertions**

Use explicit expected outcomes by fixture. Known supported repository Matroska/FLV fixtures with managed network and bounded buffers must load successfully through the public Dart API and exhibit exact request behavior/ledger evidence; policy.unsupported is a test failure for these fixtures. HLS/MP4/MOV/AVI/MPEG strict routes must reject before commit with policy.unsupported, without issuing uncontrolled upstream requests or replacing the active session. A hardwareRequired fixture may produce hardware success or decoder.unavailable on hardware-dependent environments; unknown/software must never commit. Native injected hardware-evidence tests still require deterministic positive success. platformDefault authenticated HLS must prove credential filtering with real requests, or reject an explicitly unsupported HLS feature rather than bypassing the loader.

Test callback acknowledgement delays and both load reply/state orders through the public API, ready-before-play/rebuffer milestone retention, and no firstFrame from cancelled candidates. Assert the temporary Dart strict-policy refusal is absent.

Session replacement test keeps old playback observable during candidate preparation, forces candidate failure, then verifies old session remains authoritative and can still pause/play.

- [ ] **Step 2: Add all tests to both scripts where applicable**

iOS and macOS run managed network, bounded buffer, hardware required, and session replacement. iOS additionally runs real audio-session ownership tests; macOS runs no-global-session semantics. All servers are loopback and fixtures are repository-local.

- [ ] **Step 3: Run complete Apple evidence**

Run:

~~~bash
sh packages/yl_player_apple/tool/check_pigeon.sh
sh packages/yl_player_apple/tool/apple_ffmpeg/test_build_contract.sh
sh tool/check_foundation.sh
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh
git diff --check
~~~

Expected: all pass.

- [ ] **Step 4: Architecture and leakage scans**

Run:

~~~bash
awk 'NF { count++ } END { print count+0; exit(count >= 450) }' packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/ManagedFallback/YlFallbackBackend.swift
rg -n 'localizedDescription|debugDescription|callStackSymbols|absoluteString' packages/yl_player_apple/darwin/yl_player_apple/Sources
rg -n '[T]ODO|[F]IXME|[T]BD|[X]XX' docs/superpowers/plans/2026-09-06-player-v2-apple-hardening.md
~~~

Expected: backend is under 450 nonblank lines; diagnostic scan finds only centralized redaction inputs or tests; plan scan is empty.

- [ ] **Step 5: Record and commit evidence**

Document supported/rejected route matrix (managed Matroska/FLV; managed HLS/MP4/MOV/AVI/MPEG unsupported), successful public-API strict fixtures, exact retained-payload budget exclusions and asynchronous lifetime evidence, Simulator hardware-required outcome, cross-engine audio ownership results, callback/load barrier tests, test counts, and deferred physical/endurance/profile evidence.

~~~bash
git add packages/yl_player_apple packages/yl_player/example tool .github/workflows/ci.yml docs/verification/player-v2-migration.md
git commit -m "feat(apple): complete strict player policies"
~~~
