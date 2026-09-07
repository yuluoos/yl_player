# Player v0.2 Apple Core Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decompose the consolidated Apple playback core, implement truthful source assessment and strict managed-network/bounded-buffer/hardware-required behavior, make audio ownership explicit, and align diagnostics, metrics, and geometry across iOS and macOS.

**Architecture:** The shared managed fallback becomes a thin session orchestrator over demux, video, audio, presentation, recovery, and buffer-ledger components. One pure route assessor decides AVPlayer versus managed fallback and is reused by assess and load. AVPlayer remains the compatibility route but rejects guarantees it cannot prove. Managed fallback owns exact networking and queue budgets, and VideoToolbox supplies positive hardware evidence before a hardware-required video session commits.

**Tech Stack:** Swift 5.9, iOS 15+, macOS 12+, AVFoundation, VideoToolbox, CoreMedia/CoreVideo, AVFAudio/AudioToolbox, Network, FFmpeg bridge, XCTest through the Flutter example runners.

**Spec:** docs/superpowers/specs/2026-09-06-player-v2-architecture-design.md

## Global Constraints

- Complete the Apple consolidation plan first and begin from a fully green shared package.
- Each extraction commit must preserve all existing test results and behavioral constants before any new behavior is added.
- Keep the managed fallback orchestrator under 450 nonblank lines after decomposition. It coordinates components; it does not parse, decode, schedule, render audio, or implement retry policy itself.
- AVPlayer reports decoder mode unknown for every session.
- AVPlayer rejects managed networking, bounded buffering, and hardwareRequired. It may still satisfy platformDefault networking and automatic/lowLatency/smoothPlayback goals.
- Managed network applies only when every network request for the selected route goes through package-owned byte/HLS sources.
- Credentials are source-origin-only across all redirects and HLS child resources. Ordinary headers may follow required cross-origin resources.
- Bounded maxManagedBytes covers package-owned network/ring caches, compressed packets, queued decoded frames, and scheduled audio buffers. It explicitly excludes OS/TLS buffers, FFmpeg transient allocations, VideoToolbox internal surfaces, AVAudioEngine internals, and GPU memory.
- A bounded route must reserve from one shared ledger before retaining bytes/packets/frames/audio. Failure to reserve applies backpressure or rejects the load; it never temporarily exceeds the limit.
- hardwareRequired for a video session commits only after VTSessionCopyProperty proves hardware acceleration. Unknown is rejection, not success.
- App-managed audio is the default and performs no global audio-session activation/category/deactivation.
- Plugin-managed audio deactivates only an activation acquired by this package and only after the final plugin-managed Player releases it.
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
  - Shared/HLS/YlManagedHlsLoader.swift
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
- Components communicate with immutable session generation/ID values and typed callbacks.
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
wc -l packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/ManagedFallback/YlFallbackBackend.swift
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
- Create/modify assessment tests in both RunnerTests.

**Interfaces:**
- assess and load call the same pure YlEngineRouter.assess.
- Assessment returns compatible/incompatible/requiresInspection, candidate engine, satisfied requirement IDs, limitation IDs, and typed rejection.

- [ ] **Step 1: Write the complete route matrix**

Use table-driven tests for iOS and macOS:

- Android content source is incompatible/source.invalid.
- Local file with known HLS/MP4/MOV routes AVPlayer for default policies.
- Local file with Matroska/WebM/FLV/AVI/MPEG routes managed fallback.
- Network HLS/MP4/MOV with platformDefault and non-required decoder routes AVPlayer.
- Network fallback formats route managed fallback.
- automatic format with no reliable extension is requiresInspection.
- managed network forces a managed fallback-capable route or incompatible.
- bounded forces managed fallback or incompatible.
- hardwareRequired rejects AVPlayer and requires managed-fallback inspection.
- unsupported codec discovered during inspection becomes incompatible decoder.unsupported.
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

Do not place source locators or codecs copied from untrusted headers into these lists.

- [ ] **Step 4: Reuse the decision during load**

YlAppleSessionCoordinator first validates the public descriptor, calls router.assess, throws the assessment rejection when incompatible, and passes the exact candidate decision into prepare. If requiresInspection, the candidate may refine it but may not choose an engine that violates requested guarantees.

- [ ] **Step 5: Pass and commit**

Run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh --unit-only
~~~

Expected: route matrix and all prior tests pass.

~~~bash
git add packages/yl_player_apple/darwin packages/yl_player/example/ios/RunnerTests packages/yl_player/example/macos/RunnerTests
git commit -m "feat(apple): unify source assessment routing"
~~~

### Task 3: Enforce managed networking and origin-scoped credentials

**Files:**
- Create:
  - Shared/Network/YlManagedRequestPolicy.swift
  - Shared/Network/YlOriginCredentialPolicy.swift
  - Shared/HLS/YlManagedHlsLoader.swift
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
- Managed request policy enforces connect/read deadlines, retry delays/count, redirect count, and credential origin.
- All child requests carry an immutable request context with original origin and whether credential forwarding is still allowed.

- [ ] **Step 1: Write failing URLProtocol/loopback tests**

Cover:

- initial request receives ordinary headers and credentials;
- same-origin redirect retains both;
- scheme/host/effective-port origin change keeps ordinary headers and strips every credential key;
- once stripped, credentials do not reappear if a later redirect returns to the original origin;
- HLS master, variant, media playlist, key, init segment, and media segment use the same rule;
- relative child URI remains same origin;
- maxRedirects 0 rejects the first redirect;
- connect/read timeout and retry schedule match exact configured values;
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

YlManagedRequestPolicy owns timers and retry decisions used by byte source and HLS loader. No engine-specific caller independently schedules a retry. platformDefault remains in AVPlayer/system stack and does not synthesize exact metrics or guarantees.

- [ ] **Step 5: Run loopback integration**

Add managed-HLS and managed-progressive cases to existing authenticated loopback servers and run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh
~~~

Expected: both platform unit and integration suites pass.

- [ ] **Step 6: Commit**

~~~bash
git add packages/yl_player_apple/darwin packages/yl_player/example
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
- One ledger tracks networkCache, compressedPackets, queuedVideoFrames, and scheduledAudio categories.
- currentBytes never exceeds maxBytes.
- Duration thresholds are enforced alongside bytes and surfaced as managed metrics.

- [ ] **Step 1: Write deterministic ledger tests**

Assert reserve/release is thread-safe, rejects overflow and integer overflow, category counts sum to total, releasing an unknown token is harmless but diagnosed, generation reset releases all old reservations, and peakBytes never exceeds maxBytes under concurrent randomized reserve/release sequences.

- [ ] **Step 2: Write end-to-end bounded pipeline tests**

With a 16 MiB budget, feed oversized network chunks, compressed packets, decoded frames, and audio buffers. Assert each queue applies backpressure before retain, current/peak remain <= 16 MiB, cancellation releases to zero, seek generation releases old data, reconnect cannot retain both generations beyond budget, and reported managedBufferedBytes matches ledger total.

Also test a requested budget below the computed minimum for one decoder frame plus audio/network safety margin is rejected as policy.unsupported before commit.

- [ ] **Step 3: Prove current target sizing is insufficient**

Run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh --unit-only
~~~

Expected: new tests fail because independent queue targets can exceed a shared maxManagedBytes.

- [ ] **Step 4: Implement allocation tokens**

YlManagedBufferLedger.reserve(category:bytes:generation:) returns a token only when total + bytes <= max. The token releases exactly once in deinit and explicit release. Queues must reserve before copying/retaining an object. If reserve fails, network/demux pauses; decoded frame/audio scheduling drops or waits according to existing ordering policy without exceeding the limit.

YlBoundedBufferPlan validates minDuration <= maxDuration and partitions only scheduling watermarks, not independent byte ceilings. The ledger max is the sole byte authority. Reject plans unable to retain one maximum expected frame plus minimum packet/audio/network working sets based on inspected format.

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
- audio-only inspected source has no video decoder requirement and can commit with decoder mode unknown;
- late evidence from a cancelled candidate is ignored.

- [ ] **Step 2: Prove current decoder boolean is not enough**

Run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh --unit-only
~~~

Expected: tests fail because current paths do not gate commit on VTSessionCopyProperty evidence.

- [ ] **Step 3: Implement evidence reader**

After VTDecompressionSession creation, call VTSessionCopyProperty with kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder. Accept hardware only for kCFBooleanTrue. Treat unavailable property, type mismatch, or error as unknown. Safe decoder identity may contain a framework path name but never source data.

- [ ] **Step 4: Integrate candidate gating**

During prepare, inspect enough media to create the decoder session off the public texture path. For hardwareRequired, await evidence within the existing candidate deadline before willCommit/didCommit. On rejection dispose the candidate and execute rollback. Do not emit loading state for an uncommitted candidate.

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
- Registry owns one reference-counted YlAudioOwnershipCoordinator.
- appManaged never changes global session state.
- pluginManagedMediaPlayback acquires before play and releases on last stop/dispose.

- [ ] **Step 1: Write failing ownership matrix**

With fake audio session driver assert:

- appManaged create/load/play/pause/stop/dispose makes zero driver calls;
- first plugin-managed play configures media playback and activates once;
- second managed Player increments ownership without another activation;
- pause retains ownership, while stop/dispose releases that Player;
- last release deactivates with notifyOthers only if this coordinator activated;
- failed activation rejects play and does not increment ownership;
- an externally active session not activated by the plugin is never deactivated;
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

Coordinator keys leases by Player identity, stores whether it personally activated the iOS session, and serializes on main actor. iOS plugin-managed activation sets category playback with moviePlayback mode and activates without background entitlement changes. Release deactivates only after the final owned lease. App-managed path bypasses the coordinator entirely.

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

Each test accepts only two outcomes for an explicit requirement: successful session whose state/capabilities prove the requirement, or YlPlayerException policy.unsupported/decoder.unavailable before commit. It must fail on a successful unknown/weakened state.

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
wc -l packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/ManagedFallback/YlFallbackBackend.swift
rg -n 'localizedDescription|debugDescription|callStackSymbols|absoluteString' packages/yl_player_apple/darwin/yl_player_apple/Sources
rg -n '[T]ODO|[F]IXME|[T]BD|[X]XX' docs/superpowers/plans/2026-09-06-player-v2-apple-hardening.md
~~~

Expected: backend is under 450 nonblank lines; diagnostic scan finds only centralized redaction inputs or tests; plan scan is empty.

- [ ] **Step 5: Record and commit evidence**

Document supported/rejected route matrix, exact managed-buffer exclusion scope, Simulator hardware-required outcome, test counts, and deferred physical/endurance/profile evidence.

~~~bash
git add packages/yl_player_apple packages/yl_player/example tool .github/workflows/ci.yml docs/verification/player-v2-migration.md
git commit -m "feat(apple): complete strict player policies"
~~~
