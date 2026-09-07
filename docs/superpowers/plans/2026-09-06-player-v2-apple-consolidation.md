# Player v0.2 Apple Package Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace yl_player_ios and yl_player_macos with one endorsed yl_player_apple package that shares a Darwin core, one combined FFmpeg bridge XCFramework, and a private instance-scoped Pigeon Dart/Swift transport while preserving all currently verified iOS and macOS playback behavior.

**Architecture:** yl_player_apple declares iOS and macOS with sharedDarwinSource. Its Dart registration selects the same generated transport on both platforms. Native code is organized into Shared, Engines, iOS, and macOS folders; platform APIs are injected through narrow lifecycle/audio/texture/display protocols. Existing algorithms move first and remain behaviorally frozen. The post-checkpoint macOS implementation is the base for divergent shared files because it contains the latest verified timing/decoder hardening; iOS-specific behavior is ported under explicit adapters and must retain the complete iOS test matrix.

**Tech Stack:** Flutter 3.44, Dart 3.12, Pigeon 28.0.0, Swift 5.9 package manifest, CocoaPods, iOS 15+, macOS 12+, AVFoundation, VideoToolbox, AudioToolbox/AVFAudio, Network, FFmpeg 9.0.1 bridge.

**Spec:** docs/superpowers/specs/2026-09-06-player-v2-architecture-design.md

## Global Constraints

- Complete the Dart/SPI plan and Android plan first; the Apple package consumes the exact v0.2 public/SPI types.
- The protected dirty macOS/channel baseline must already be checkpointed or otherwise resolved with the user before any copy or merge.
- This plan is behavior-preserving. Do not change clock math, scheduling thresholds, queue budgets, reconnect ordering, decoder selection, HLS rewriting, source-routing preference, or error recovery except where typed session correlation requires it.
- If a moved implementation fails an existing test, first restore behavior. Do not weaken/delete the test or call the difference a platform abstraction.
- Generated Dart and Swift Pigeon files live only in yl_player_apple.
- iOS and macOS use one combined YlFFmpegBridge.xcframework with three library entries: ios-arm64, ios-arm64_x86_64-simulator, and macos-arm64_x86_64.
- Deployment floors are iOS 15.0 and macOS 12.0 in pubspec metadata, podspec, Package.swift, and consumer projects.
- No encoded packet, decoded frame, pixel buffer, or PCM crosses Dart.
- AVPlayer decoder mode is always unknown. It never claims software merely because hardware evidence is unavailable.
- Until the hardening plan lands, the consolidated package rejects managed network, bounded buffer, and hardwareRequired with policy.unsupported. This avoids behavior changes during the move.
- Old yl_player_ios and yl_player_macos directories remain untouched after the copy until the final cleanup plan deletes them.

---

## File and Responsibility Map

- Package root:
  - Create packages/yl_player_apple/pubspec.yaml, analysis_options.yaml, README.md, CHANGELOG.md, LICENSE, THIRD_PARTY_NOTICES.md, and LICENSES/FFmpeg-LGPL-2.1-or-later.txt.
  - Create lib/yl_player_apple.dart and lib/src/apple_player.dart, apple_codec.dart, apple_callbacks.dart, apple_transport.dart.
  - Create pigeons/yl_player_apple.dart and generated Dart/Swift outputs.
- Darwin packaging:
  - Create darwin/yl_player_apple.podspec.
  - Create darwin/yl_player_apple/Package.swift.
  - Create darwin/yl_player_apple/Frameworks/YlFFmpegBridge.xcframework.
- Native source tree:
  - darwin/yl_player_apple/Sources/yl_player_apple/Generated
  - darwin/yl_player_apple/Sources/yl_player_apple/Shared/Session
  - darwin/yl_player_apple/Sources/yl_player_apple/Shared/SourceRouting
  - darwin/yl_player_apple/Sources/yl_player_apple/Shared/Network
  - darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS
  - darwin/yl_player_apple/Sources/yl_player_apple/Shared/FFmpeg
  - darwin/yl_player_apple/Sources/yl_player_apple/Shared/VideoToolbox
  - darwin/yl_player_apple/Sources/yl_player_apple/Shared/Audio
  - darwin/yl_player_apple/Sources/yl_player_apple/Shared/Clock
  - darwin/yl_player_apple/Sources/yl_player_apple/Shared/Metrics
  - darwin/yl_player_apple/Sources/yl_player_apple/Shared/Diagnostics
  - darwin/yl_player_apple/Sources/yl_player_apple/Engines/AvPlayer
  - darwin/yl_player_apple/Sources/yl_player_apple/Engines/ManagedFallback
  - darwin/yl_player_apple/Sources/yl_player_apple/iOS
  - darwin/yl_player_apple/Sources/yl_player_apple/macOS
- Tooling:
  - Create packages/yl_player_apple/tool/apple_ffmpeg/build_xcframework.sh and test_build_contract.sh.
  - Create packages/yl_player_apple/tool/generate_pigeon.sh and check_pigeon.sh.
  - Update root native-check scripts only after the example switches.

---

### Task 1: Create the dual-platform package and packaging skeleton

**Files:**
- Create: packages/yl_player_apple/pubspec.yaml
- Create: packages/yl_player_apple/analysis_options.yaml
- Create: packages/yl_player_apple/lib/yl_player_apple.dart
- Create: packages/yl_player_apple/test/yl_player_apple_test.dart
- Create: packages/yl_player_apple/README.md
- Create: packages/yl_player_apple/CHANGELOG.md
- Copy licenses: packages/yl_player_apple/LICENSE, THIRD_PARTY_NOTICES.md, LICENSES/FFmpeg-LGPL-2.1-or-later.txt
- Create: packages/yl_player_apple/darwin/yl_player_apple.podspec
- Create: packages/yl_player_apple/darwin/yl_player_apple/Package.swift
- Modify: pubspec.yaml

**Interfaces:**
- Produces one Flutter plugin package implementing yl_player on iOS and macOS.
- Both platform entries use dartPluginClass YlPlayerApple, pluginClass YlPlayerApplePlugin, and sharedDarwinSource: true.

- [ ] **Step 1: Write the package metadata test before registration code**

The test reads pubspec.yaml and asserts both platforms, matching classes, sharedDarwinSource true, and no Android/web entry. It reads the podspec and Package.swift to assert iOS 15.0/macOS 12.0.

Run:

~~~bash
flutter test packages/yl_player_apple/test/yl_player_apple_test.dart
~~~

Expected: the package does not exist.

- [ ] **Step 2: Create exact pubspec registration**

Use:

~~~yaml
name: yl_player_apple
description: Endorsed shared iOS and macOS implementation for yl_player.
version: 0.2.0-dev.1
resolution: workspace
environment:
  sdk: ^3.12.0
  flutter: '>=3.44.0'
dependencies:
  flutter:
    sdk: flutter
  yl_player_platform_interface: ^0.2.0-dev.1
dev_dependencies:
  flutter_lints: ^6.0.0
  flutter_test:
    sdk: flutter
  pigeon: 28.0.0
flutter:
  plugin:
    implements: yl_player
    platforms:
      ios:
        pluginClass: YlPlayerApplePlugin
        dartPluginClass: YlPlayerApple
        sharedDarwinSource: true
      macos:
        pluginClass: YlPlayerApplePlugin
        dartPluginClass: YlPlayerApple
        sharedDarwinSource: true
~~~

Add packages/yl_player_apple to the root workspace but do not change yl_player dependencies/default_package yet.

- [ ] **Step 3: Create podspec and Package.swift floors/frameworks**

The podspec source glob is yl_player_apple/Sources/yl_player_apple/**/*.swift, vendored framework is yl_player_apple/Frameworks/YlFFmpegBridge.xcframework, iOS floor is 15.0, macOS floor is 12.0, and dependencies select Flutter on iOS and FlutterMacOS on macOS. Frameworks include AVFoundation, AudioToolbox, CoreMedia, VideoToolbox, AVFAudio, Network, QuartzCore, and AppKit/UIKit conditionally through source code.

Package.swift declares iOS 15 and macOS 12, one binary target YlFFmpegBridge, one library target yl_player_apple, and the generated FlutterFramework package dependency expected by Flutter's Swift package integration.

- [ ] **Step 4: Resolve and test package metadata**

Run:

~~~bash
flutter pub get
flutter test packages/yl_player_apple/test/yl_player_apple_test.dart
dart format --output=none --set-exit-if-changed packages/yl_player_apple/lib packages/yl_player_apple/test
~~~

Expected: workspace resolution and metadata tests pass; native compilation is not expected until sources/artifact exist.

- [ ] **Step 5: Commit**

~~~bash
git add pubspec.yaml pubspec.lock packages/yl_player_apple
git commit -m "build(apple): create shared plugin package"
~~~

### Task 2: Build one deterministic cross-platform FFmpeg bridge

**Files:**
- Create: packages/yl_player_apple/darwin/native/YlFFmpegBridge/include/YlFFmpegBridge.h
- Create: packages/yl_player_apple/darwin/native/YlFFmpegBridge/YlFFmpegBridge.m
- Create: packages/yl_player_apple/darwin/native/YlFFmpegBridge/module.modulemap
- Create: packages/yl_player_apple/tool/apple_ffmpeg/ffmpeg-9.0.1.lock
- Create: packages/yl_player_apple/tool/apple_ffmpeg/bridge-artifact.lock
- Create: packages/yl_player_apple/tool/apple_ffmpeg/FFMPEG_RELEASE_KEY.asc
- Create: packages/yl_player_apple/tool/apple_ffmpeg/build_xcframework.sh
- Create: packages/yl_player_apple/tool/apple_ffmpeg/test_build_contract.sh
- Create generated artifact: packages/yl_player_apple/darwin/yl_player_apple/Frameworks/YlFFmpegBridge.xcframework
- Modify: tool/ios_ffmpeg/build_xcframework.sh

**Interfaces:**
- Produces one bridge module named YlFFmpegBridge for iOS device/simulator and universal macOS.
- Artifact contents are reproducible from pinned FFmpeg source/checksum/configuration.

- [ ] **Step 1: Write failing combined-artifact contract**

The contract must inspect Info.plist AvailableLibraries and fail unless it contains exactly:

- ios-arm64 with SupportedPlatform ios;
- ios-arm64_x86_64-simulator with SupportedPlatform ios and SupportedPlatformVariant simulator;
- macos-arm64_x86_64 with SupportedPlatform macos.

It then checks:

- iOS device binary architecture arm64;
- simulator binary architectures arm64 and x86_64;
- macOS binary architectures arm64 and x86_64;
- identical public header/module map in all slices;
- nm exposes every YlFFmpegBridge symbol used by current Swift sources;
- otool LC_BUILD_VERSION minimums iOS 15.0 and macOS 12.0;
- artifact SHA-256 equals bridge-artifact.lock.

Run:

~~~bash
sh packages/yl_player_apple/tool/apple_ffmpeg/test_build_contract.sh
~~~

Expected: failure because the combined artifact does not exist.

- [ ] **Step 2: Unify bridge source**

Start from the current iOS bridge header/implementation and port the macOS-only entry points. Keep one Objective-C source guarded only where Apple SDK types differ. Compare exported symbols from both old binaries before removing any declaration.

- [ ] **Step 3: Merge the existing slices without rebuilding FFmpeg first**

Use xcodebuild -create-xcframework with the two current iOS frameworks and the current universal macOS framework. This is a mechanical artifact composition, not an algorithm change. Then regenerate Info.plist and lock checksum through the approved build script.

- [ ] **Step 4: Make a full source rebuild produce the same layout**

Merge the pinned source verification/configuration from both old build scripts. Build arm64 iOS, arm64/x86_64 simulator, and arm64/x86_64 macOS, lipo only same-platform macOS/simulator slices, then xcodebuild -create-xcframework. Never lipo iOS and macOS together.

Root tool/ios_ffmpeg/build_xcframework.sh delegates to the package script during migration so there is one build implementation.

- [ ] **Step 5: Pass, verify linkage, and commit**

Run:

~~~bash
sh packages/yl_player_apple/tool/apple_ffmpeg/test_build_contract.sh
swift package dump-package --package-path packages/yl_player_apple/darwin/yl_player_apple
pod spec lint packages/yl_player_apple/darwin/yl_player_apple.podspec --quick --allow-warnings
~~~

Expected: artifact, manifest, and podspec checks pass.

~~~bash
git add packages/yl_player_apple/darwin packages/yl_player_apple/tool tool/ios_ffmpeg/build_xcframework.sh
git commit -m "build(apple): combine ffmpeg bridge slices"
~~~

### Task 3: Move identical native sources into the shared Darwin tree

**Files:**
- Create shared files under packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple:
  - Shared/FFmpeg/YlByteRingBuffer.swift
  - Shared/FFmpeg/YlByteSource.swift
  - Shared/FFmpeg/YlBoundedPacketQueue.swift
  - Shared/FFmpeg/YlFallbackBufferBudget.swift
  - Shared/FFmpeg/YlFallbackModels.swift
  - Shared/FFmpeg/YlPreparedFallback.swift
  - Shared/FFmpeg/YlOpenedMedia.swift
  - Shared/SourceRouting/YlSourceRouter.swift
  - Shared/Network/YlNetworkByteSource.swift
  - Shared/Network/YlNetworkRequestPolicy.swift
  - Shared/HLS/YlHlsHeaderPolicy.swift
  - Shared/HLS/YlHlsManifestRewriter.swift
  - Shared/HLS/YlHlsMediaProxy.swift
  - Shared/HLS/YlHlsResourceLoader.swift
  - Shared/HLS/YlHlsURLCodec.swift
  - Shared/Session/YlOpenCoordinator.swift
  - Shared/Session/YlLiveReconnectController.swift
  - Shared/Metrics/YlFallbackStateEncoder.swift
  - Shared/Metrics/YlFallbackTrackCatalog.swift
  - Engines/ManagedFallback/YlFallbackQualityPolicy.swift
- Create: packages/yl_player_apple/tool/check_source_parity.sh

**Interfaces:**
- Produces a single source of truth for files currently identical or trivially platform-neutral.
- check_source_parity records exact source hashes and fails if a copied file changed during the move.

- [ ] **Step 1: Capture a machine-readable pre-move manifest**

check_source_parity.sh computes SHA-256 for each iOS/macOS source pair. It marks identical pairs and records the chosen source for one-sided files. Its test mode compares copied shared files to the manifest.

Run:

~~~bash
sh packages/yl_player_apple/tool/check_source_parity.sh --capture
~~~

Expected: it reports identical pairs matching the current baseline and divergent pairs reserved for Task 4.

- [ ] **Step 2: Copy the exact identical files**

For the identical pairs, use a bulk mechanical copy from iOS and verify byte identity. Move iOS-only YlBoundedPacketQueue.swift into Shared/FFmpeg unchanged. Apply only module/import naming changes required to compile.

- [ ] **Step 3: Add pure shared tests to the existing Runner matrices**

Copy the corresponding iOS test cases for byte buffers, packet queues, buffer budget, source routing, HLS, network source, open coordinator, track/state encoding, and reconnect policy. Change only @testable import to yl_player_apple after Task 7 switches the example. Until then, compile the new sources through a temporary test target in Package.swift.

- [ ] **Step 4: Prove source identity and compile**

Run:

~~~bash
sh packages/yl_player_apple/tool/check_source_parity.sh --verify-identical
swift build --package-path packages/yl_player_apple/darwin/yl_player_apple
~~~

Expected: copied-source hashes match and the shared target compiles for the host macOS architecture.

- [ ] **Step 5: Commit**

~~~bash
git add packages/yl_player_apple/darwin/yl_player_apple/Sources packages/yl_player_apple/tool/check_source_parity.sh packages/yl_player_apple/darwin/yl_player_apple/Package.swift
git commit -m "refactor(apple): move platform-neutral sources"
~~~

### Task 4: Merge divergent engine code behind platform adapters without behavior changes

**Files:**
- Create under Shared/Audio: YlAudioRenderer.swift
- Create under Shared/Clock: YlMediaClock.swift, YlFrameScheduler.swift
- Create under Shared/VideoToolbox: YlVideoToolboxDecoder.swift
- Create under Shared/Session: YlPlaybackBackend.swift, YlFallbackRecoveryPolicy.swift
- Create under Engines/AvPlayer: YlAvPlayerBackend.swift, YlAvPlayerRecoveryPolicy.swift
- Create under Engines/ManagedFallback: YlFallbackBackend.swift
- Create under iOS: YlIosPlatformAdapter.swift, YlIosTextureOutput.swift, YlIosLifecycle.swift
- Create under macOS: YlMacosPlatformAdapter.swift, YlMacosTextureOutput.swift, YlMacosLifecycle.swift, YlDisplayTimer.swift
- Create: packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Session/YlPlatformServices.swift
- Create: packages/yl_player_apple/tool/diff_behavioral_constants.sh

**Interfaces:**
- Shared engines consume YlPlatformServices instead of importing UIKit/AppKit lifecycle/display behavior directly.
- Divergent algorithms retain their current platform-tested behavior.

- [ ] **Step 1: Add characterization tests before every merge**

Port all current iOS and macOS tests for AudioRenderer, FrameScheduler, MediaClock, VideoToolboxDecoder, AVPlayer state/failure policy, fallback lifecycle/recovery, and open/rollback. Keep the current dirty macOS high-rate scheduling and decoder regressions intact.

Run current gates once before copy and save test counts:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh --unit-only
~~~

Expected: both baseline gates pass.

- [ ] **Step 2: Define narrow platform services**

Use:

~~~swift
protocol YlTextureOutput: AnyObject {
  var textureId: Int64 { get }
  func publish(_ pixelBuffer: CVPixelBuffer?)
  func resize(width: Int, height: Int)
  func clear()
  func dispose()
}

protocol YlDisplayDriving: AnyObject {
  var isPaused: Bool { get set }
  func invalidate()
}

protocol YlLifecycleDriving: AnyObject {
  var onSuspend: (() -> Void)? { get set }
  var onResume: (() -> Void)? { get set }
  var onTerminate: (() -> Void)? { get set }
  func start()
  func stop()
}

struct YlPlatformServices {
  let platform: YlApplePlatform
  let textureOutput: any YlTextureOutput
  let makeDisplayDriver: (@escaping () -> Void) -> any YlDisplayDriving
}
~~~

UIKit/AppKit/Flutter registrar differences stay in iOS/macOS adapters.

- [ ] **Step 3: Merge each divergent file with a declared base**

Use the post-checkpoint macOS file as the shared base for YlAudioRenderer, YlAvPlayerBackend, YlFallbackBackend, YlFrameScheduler, YlMediaClock, YlPlaybackBackend, YlOpenCoordinator, and YlVideoToolboxDecoder because those contain the newest verified timing/rollback/decoder hardening.

Then port every iOS-only branch identified by git diff, including YlBoundedPacketQueue use, iOS interruption/lifecycle behavior, iOS AVPlayer recovery policy, and simulator/device VideoToolbox handling. Use compile-time platform adapters only for SDK differences; do not maintain two algorithm copies.

Unify YlAvPlayerFailurePolicy and YlAvPlayerRecoveryPolicy under YlAvPlayerRecoveryPolicy. Preserve both test matrices before deleting either old name in the new package.

- [ ] **Step 4: Lock behavioral constants**

diff_behavioral_constants.sh extracts numeric constants and relevant enum cases from old and new clock/scheduler/buffer/retry/decoder files. Every difference requires an allowlist line with old file, new file, and reason import/platform abstraction. No tuning change is allowed in this plan.

- [ ] **Step 5: Run both native test matrices against the shared files**

Temporarily point the example native test targets at yl_player_apple or add equivalent package tests. Run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh --unit-only
sh packages/yl_player_apple/tool/diff_behavioral_constants.sh
~~~

Expected: all existing tests pass and only allowlisted import/platform abstraction differences remain.

- [ ] **Step 6: Commit**

~~~bash
git add packages/yl_player_apple/darwin packages/yl_player_apple/tool packages/yl_player/example/ios/RunnerTests packages/yl_player/example/macos/RunnerTests
git commit -m "refactor(apple): unify native playback core"
~~~

### Task 5: Define and generate the private Apple Pigeon schema

**Files:**
- Create: packages/yl_player_apple/pigeons/yl_player_apple.dart
- Create generated: packages/yl_player_apple/lib/src/pigeon/yl_player_apple.g.dart
- Create generated: packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Generated/YlPlayerApple.g.swift
- Create: packages/yl_player_apple/tool/generate_pigeon.sh
- Create: packages/yl_player_apple/tool/check_pigeon.sh
- Create: packages/yl_player_apple/test/pigeon_schema_test.dart

**Interfaces:**
- Produces schemaMajor = 2, factory HostApi, per-instance Player HostApi, and per-instance FlutterApi callbacks.
- Transport covers both iOS and macOS with an ApplePlatform enum.

- [ ] **Step 1: Write a failing generated-schema smoke test**

Construct create/options/source/load/full-state/delta/event/failure messages and assert ApplePlatform.ios and ApplePlatform.macos round-trip through the Dart codec.

- [ ] **Step 2: Declare exact enum and message set**

Declare ApplePlatform ios/macos; source, intent, format, network, buffer, decoder, audio, assessment, status, failure category/scope enums matching the public names; AppleEngine avPlayer/managedFallback; AppleDecoderMode unknown/hardware/software; AppleDecoderEvidence none/hardwareOnly/hardwareAndSoftware.

Declare:

- ApplePlayerOptionsMessage: decoderPolicy, audioPolicy, positionUpdateIntervalMs.
- AppleCreateRequest: schemaMajor and options.
- AppleCreateReply: schemaMajor, channelSuffix, textureId, platform, implementationName, implementationVersion, capabilities, initialState.
- AppleCapabilitiesMessage: deviceProfile, availableEngines, supportedOperations, decoderEvidence, hardwareVideoCodecs, maxConcurrentVideoDecoders, maxWidth, maxHeight.
- AppleHttpRequestMessage: headers and credentials maps.
- AppleNetworkPolicyMessage: kind and nullable timeout/retry/redirect fields.
- AppleSourceMessage: kind, locator, intent, format, request, networkPolicy.
- AppleBufferStrategyMessage, AppleVideoConstraintsMessage, AppleLoadOptionsMessage.
- AppleAssessRequest, AppleAssessmentReply, AppleLoadRequest, AppleLoadReply.
- AppleSessionCommand, AppleSeekCommand, AppleSpeedCommand, AppleTrackCommand, AppleVideoConstraintsCommand.
- AppleTimelineMessage, AppleVideoGeometryMessage, AppleTrackMessage, AppleMetricsMessage, AppleFailureMessage.
- AppleStateMessage with sessionId/revision/sequence and every public state field.
- AppleStateDeltaMessage with sessionId/previousRevision/revision/sequence and only periodic timeline/common metric fields, using hasX flags for nullable clear semantics.
- AppleFirstFrameMessage, AppleRetryScheduledMessage, AppleEngineChangedMessage, ApplePlaybackFailedMessage with sessionId/revision/sequence/occurredAtMs and event fields.

No Object payload or string command name is allowed.

- [ ] **Step 3: Declare generated APIs**

Use the same method surface as the Android schema with Apple-prefixed types:

- ApplePlayerFactoryHostApi.create.
- ApplePlayerHostApi.attach, assess, async load, play, pause, seekTo, seekToLiveEdge, setPlaybackSpeed, selectAudioTrack, setVideoConstraints, setVolume, stop, dispose.
- ApplePlayerFlutterApi.onState, onStateDelta, onFirstFrame, onRetryScheduled, onEngineChanged, onPlaybackFailed.

- [ ] **Step 4: Generate and lock**

Configure @ConfigurePigeon for package-relative Dart and Swift output paths, then run:

~~~bash
sh packages/yl_player_apple/tool/generate_pigeon.sh
flutter test packages/yl_player_apple/test/pigeon_schema_test.dart
sh packages/yl_player_apple/tool/check_pigeon.sh
~~~

Expected: generated sources compile and a second generation produces no diff.

- [ ] **Step 5: Commit**

~~~bash
git add packages/yl_player_apple/pigeons packages/yl_player_apple/lib/src/pigeon packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Generated packages/yl_player_apple/tool/generate_pigeon.sh packages/yl_player_apple/tool/check_pigeon.sh packages/yl_player_apple/test/pigeon_schema_test.dart
git commit -m "build(apple): add private pigeon protocol"
~~~

### Task 6: Implement the Apple Dart adapter

**Files:**
- Rewrite: packages/yl_player_apple/lib/yl_player_apple.dart
- Create: packages/yl_player_apple/lib/src/apple_transport.dart
- Create: packages/yl_player_apple/lib/src/apple_codec.dart
- Create: packages/yl_player_apple/lib/src/apple_callbacks.dart
- Create: packages/yl_player_apple/lib/src/apple_player.dart
- Rewrite: packages/yl_player_apple/test/yl_player_apple_test.dart
- Create: packages/yl_player_apple/test/apple_codec_test.dart
- Create: packages/yl_player_apple/test/apple_player_test.dart

**Interfaces:**
- Produces YlPlayerApple registration and YlPlatformPlayer implementation.
- Pigeon wrappers are injectable for unit tests.
- State ordering and lifecycle rules match the Android Dart adapter exactly.

- [ ] **Step 1: Write codec and ordering tests**

Cover every enum, iOS/macOS capabilities, AVPlayer decoder unknown, managed fallback hardware/software modes, geometry, nullable metrics, safe failures, source assessment, full-state ordering, delta previousRevision, sequence duplicates, stale-session events, and disposal.

- [ ] **Step 2: Write creation failure cleanup tests**

Assert schema mismatch, invalid texture/state, callback setup failure, and attach failure each best-effort dispose native host and remove callback setup. Successful create exposes capabilities immediately and has no property-read side effect.

- [ ] **Step 3: Prove failure**

Run:

~~~bash
flutter test packages/yl_player_apple/test
~~~

Expected: generated DTOs exist but the platform adapter is absent.

- [ ] **Step 4: Implement typed adapter**

Create private AppleFactoryTransport and ApplePlayerTransport interfaces matching every generated host method. Decode/encode public types without map coercion. Reject strict managed/bounded/hardwareRequired assessments in this consolidation phase. Create callback handler before attach and remove it after native dispose.

YlPlayerApple.registerWith assigns YlPlayerPlatform.instance = YlPlayerApple(). It has no platform-specific Dart class.

- [ ] **Step 5: Pass and commit**

Run:

~~~bash
dart format packages/yl_player_apple/lib packages/yl_player_apple/test
flutter test packages/yl_player_apple/test
flutter analyze packages/yl_player_apple
~~~

Expected: all pass without importing the legacy transport.

~~~bash
git add packages/yl_player_apple/lib packages/yl_player_apple/test
git commit -m "refactor(apple): use typed dart transport"
~~~

### Task 7: Add shared native registry, sessions, reducer, and typed callbacks

**Files:**
- Create under Shared/Session:
  - YlApplePlayerRegistry.swift
  - YlApplePlayerHost.swift
  - YlAppleSessionCoordinator.swift
  - YlAppleStateReducer.swift
  - YlAppleSessionModels.swift
- Create under Shared/Diagnostics:
  - YlAppleFailureMapper.swift
  - YlAppleSafeDiagnostics.swift
- Create: packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/YlPlayerApplePlugin.swift
- Create/modify iOS and macOS lifecycle/texture adapters.
- Port tests into packages/yl_player/example/ios/RunnerTests and macos/RunnerTests.

**Interfaces:**
- One registry implements ApplePlayerFactoryHostApi.
- One host per suffix implements ApplePlayerHostApi.
- Session coordinator preserves current open/rollback semantics and supplies public session IDs.
- State reducer owns revisions/sequences and emits generated callbacks.

- [ ] **Step 1: Write registry/session/reducer tests before boundary code**

On both iOS and macOS test targets, cover:

- unique per-player suffix and one texture registration;
- attach-before-callback ordering;
- load commit returns session ID;
- newer load cancels older pending load;
- pre-commit failure preserves active session;
- stale command rejection;
- stop returns idle without unregistering texture;
- full/delta revision and sequence monotonicity;
- first frame and terminal failure exactly once per session;
- engine transition event correlation;
- safe failure mapping;
- double dispose and plugin detach cleanup.

- [ ] **Step 2: Prove tests fail**

Run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh --unit-only
~~~

Expected: tests referencing the new registry/host/reducer fail to compile.

- [ ] **Step 3: Implement registry and conditional plugin registration**

YlPlayerApplePlugin uses #if os(iOS) to register with FlutterPluginRegistrar and #if os(macOS) for FlutterPluginRegistrar from FlutterMacOS. Both construct platform adapters and one YlApplePlayerRegistry. Registration contains no string method switch or FlutterEventChannel.

The factory creates texture/platform services, generates suffix p<player-id>-<nonce>, installs ApplePlayerHostApiSetup on that suffix, and returns typed capabilities/initial idle state. Host creates ApplePlayerFlutterApi with the same suffix and remains silent until attach.

- [ ] **Step 4: Implement common session and reducer**

Generate opaque IDs apple-<player-id>-s<sequence>, never source-derived. Wrap existing YlOpenCoordinator and backend candidate slots; preserve didCommit/didRollback ordering. Capture session ID in every backend callback closure.

Reducer begins revision/sequence at zero, emits full states for semantic changes and deltas for periodic timeline/metrics. AVPlayer maps decoder mode unknown. Managed fallback maps hardware only after VideoToolbox session creation evidence; otherwise unknown in this phase.

- [ ] **Step 5: Replace map event emission**

Change engine emit closures to typed internal domain callbacks, then encode only at YlApplePlayerHost. Remove YlIosChannel.swift and YlMacosChannel.swift from the new package. Keep old package files untouched until cleanup.

- [ ] **Step 6: Pass both native unit gates and commit**

Run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh --unit-only
~~~

Expected: all old behavior characterizations plus new registry/session/reducer tests pass against yl_player_apple.

~~~bash
git add packages/yl_player_apple/darwin packages/yl_player/example/ios/RunnerTests packages/yl_player/example/macos/RunnerTests
git commit -m "refactor(apple): add typed native sessions"
~~~

### Task 8: Switch endorsement and prove iOS/macOS parity

**Files:**
- Modify: packages/yl_player/pubspec.yaml
- Modify: pubspec.yaml
- Modify: packages/yl_player/example/pubspec.yaml
- Modify: packages/yl_player/example/ios/RunnerTests/*.swift
- Modify: packages/yl_player/example/macos/RunnerTests/*.swift
- Modify: tool/check_foundation.sh
- Modify: tool/check_native_ios.sh
- Modify: tool/check_native_macos.sh
- Modify: .github/workflows/ci.yml
- Modify generated platform registrants/project references as produced by Flutter tooling.

**Interfaces:**
- yl_player defaults to yl_player_apple for both iOS and macOS.
- Old platform packages remain in the workspace only as unendorsed migration artifacts.

- [ ] **Step 1: Change dependency/default-package wiring atomically**

Remove yl_player_ios and yl_player_macos dependencies from yl_player, add yl_player_apple ^0.2.0-dev.1, and point both platform default_package entries to yl_player_apple. Root workspace still lists old packages until final deletion but foundation checks stop treating them as endorsed.

- [ ] **Step 2: Regenerate Flutter native wiring**

Run flutter pub get and platform config-only builds. Verify GeneratedPluginRegistrant and iOS/macOS project linkage name only YlPlayerApplePlugin, never both old and new plugins.

- [ ] **Step 3: Rename native test imports**

Change every @testable import yl_player_ios or yl_player_macos to @testable import yl_player_apple. Do not remove or skip any test. Keep platform-specific test filenames where they communicate coverage.

- [ ] **Step 4: Update gate scripts**

Foundation tests yl_player_apple Dart tests and combined bridge contract. iOS/macOS scripts use the new pod/module/binary names. macOS universal check looks for YlPlayerApplePlugin and yl_player_apple.o for arm64/x86_64.

- [ ] **Step 5: Run the complete parity gate**

Run:

~~~bash
sh packages/yl_player_apple/tool/check_pigeon.sh
sh packages/yl_player_apple/tool/apple_ffmpeg/test_build_contract.sh
sh tool/check_foundation.sh
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh
git diff --check
~~~

Expected: Dart, iOS native/integration, macOS native/universal/Rosetta/integration, codegen, and artifact checks all pass with the new package.

- [ ] **Step 6: Commit**

~~~bash
git add pubspec.yaml pubspec.lock packages/yl_player packages/yl_player_apple packages/yl_player/example tool .github/workflows/ci.yml
git commit -m "feat!: endorse shared apple implementation"
~~~

### Task 9: Apple consolidation self-review

**Files:**
- Modify only defects identified below.
- Modify: docs/verification/player-v2-migration.md

- [ ] **Step 1: Prove one source of truth**

Run:

~~~bash
find packages/yl_player_apple/darwin/yl_player_apple/Sources -name '*.swift' -exec basename {} \; | sort | uniq -d
rg -n 'FlutterMethodChannel|FlutterEventChannel|FlutterMethodCall|YlIosChannel|YlMacosChannel' packages/yl_player_apple
rg -n '[T]ODO|[F]IXME|[T]BD|[X]XX' docs/superpowers/plans/2026-09-06-player-v2-apple-consolidation.md
~~~

Expected: no duplicate basenames, no handwritten channel protocol, and no planning gaps.

- [ ] **Step 2: Verify platform conditionals are confined**

Run:

~~~bash
rg -n '#if os\(iOS\)|#if os\(macOS\)|import UIKit|import AppKit' packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines
~~~

Expected: no platform UI/lifecycle imports in Shared/Engines. Necessary AVFoundation availability checks are platform-neutral.

- [ ] **Step 3: Re-run all evidence**

Run:

~~~bash
sh packages/yl_player_apple/tool/check_pigeon.sh
sh packages/yl_player_apple/tool/apple_ffmpeg/test_build_contract.sh
sh packages/yl_player_apple/tool/diff_behavioral_constants.sh
sh tool/check_foundation.sh
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh
git diff --check
~~~

Expected: all pass.

- [ ] **Step 4: Record evidence and remaining claims**

Update docs/verification/player-v2-migration.md with artifact hashes, iOS Simulator model/OS, macOS architecture evidence, Rosetta result, test counts, and explicit outstanding evidence: physical iOS VideoToolbox, Intel Mac runtime hardware, Instruments/memgraph, and endurance/reconnect soak.

~~~bash
git add docs/verification/player-v2-migration.md
git commit -m "docs: record apple consolidation verification"
~~~
