# Player v0.2 Apple Package Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace yl_player_ios and yl_player_macos with one endorsed yl_player_apple package that shares a Darwin core, one combined FFmpeg bridge XCFramework, and a private instance-scoped Pigeon Dart/Swift transport while preserving all currently verified iOS and macOS playback behavior.

**Architecture:** yl_player_apple declares iOS and macOS with sharedDarwinSource. Its Dart registration selects the same generated transport on both platforms. Native code is organized into Shared, Engines, iOS, and macOS folders; platform APIs are injected through narrow lifecycle/audio/texture/display protocols. Existing algorithms move first and remain behaviorally frozen. The macOS implementation from 1b239e0/49f59cf plus subsequent authorized review fixes is the base for divergent shared files because it contains the latest verified timing/decoder hardening; iOS-specific behavior is ported under explicit adapters and must retain the complete iOS test matrix.

**Tech Stack:** Flutter 3.44, Dart 3.12, Pigeon 28.0.0, Swift 5.9 package manifest, CocoaPods, iOS 15+, macOS 12+, AVFoundation, VideoToolbox, AudioToolbox/AVFAudio, Network, FFmpeg 9.0.1 bridge.

**Spec:** docs/superpowers/specs/2026-09-06-player-v2-architecture-design.md

## Global Constraints

- Complete the Dart/SPI plan and Android plan first, including the early coherent 0.2.0-dev.1 workspace version bootstrap and temporary old Apple-package constraints. The Apple package consumes those exact public/SPI types; do not postpone version alignment to release cleanup.
- The macOS/channel baseline is checkpointed in 1b239e0 and 49f59cf. Preserve the subsequent authorized review fixes and their regression tests before any copy/merge; do not reset, stash, or absorb unrelated current edits.
- This plan is behavior-preserving. Do not change clock math, scheduling thresholds, queue budgets, reconnect ordering, decoder selection, HLS rewriting, source-routing preference, or error recovery except where typed session correlation requires it.
- If a moved implementation fails an existing test, first restore behavior. Do not weaken/delete the test or call the difference a platform abstraction.
- Generated Dart and Swift Pigeon files live only in yl_player_apple.
- iOS and macOS use one combined YlFFmpegBridge.xcframework with three library entries: ios-arm64, ios-arm64_x86_64-simulator, and macos-arm64_x86_64.
- Deployment floors are iOS 15.0 and macOS 12.0 in pubspec metadata, podspec, Package.swift, and consumer projects.
- No encoded packet, decoded frame, pixel buffer, or PCM crosses Dart.
- AVPlayer decoder mode is always unknown. It never claims software merely because hardware evidence is unavailable.
- Until the hardening plan lands, the consolidated package rejects managed network, bounded buffer, and hardwareRequired with policy.unsupported. This avoids behavior changes during the move.
- Old yl_player_ios and yl_player_macos directories remain untouched after the copy until the final cleanup plan deletes them. The earlier version bootstrap is already checkpointed.
- Resolve command paths from the active checkout/worktree, never from a fixed original checkout. Start each execution shell with:

~~~bash
YL_REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$YL_REPO_ROOT"
~~~

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
  - Create tool/bootstrap_apple_consumers.sh and tool/check_apple_consumer.sh for independent Flutter native test consumers, reused by final consumer gates.
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
- Create temporary registration skeleton: packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/YlPlayerApplePlugin.swift
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

Package.swift declares iOS 15 and macOS 12, one binary target YlFFmpegBridge, one library target yl_player_apple, and the generated FlutterFramework package dependency expected by Flutter's Swift package integration. Preserve the hyphenated product name yl-player-apple expected by Flutter plugin integration. Use platform-scoped CocoaPods dependencies/framework settings and compile-time adapter imports for Flutter versus FlutterMacOS.

Do not run a bare swift build in this source package: FlutterFramework is supplied by Flutter's generated consumer environment, not a checked-in sibling package. Task 3 bootstraps independent Flutter consumers before compiling source; dump-package here only validates the manifest shape. The consumers set the actual Xcode iOS 15/macOS 12 deployment targets before config-only generation and verify the generated SwiftPM aggregator floor too. Add a minimal conditional native registration class so the independent host can link while the core is being moved; it exposes no player behavior until Task 7 replaces it with the typed registry. Keep the public Dart registration skeleton equally explicit; no temporary stub may report successful playback or capability support.

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
- Artifact contents are reproducible from pinned FFmpeg source/checksum/configuration and recorded Xcode/SDK/toolchain inputs. Verification is read-only and cannot bless an unverified artifact by rewriting its lock.
- Keep the existing demux allowlist matroska,flv, parsers aac,h264,hevc,mpegaudio, and file protocol. Networking/decoders/GPL/nonfree remain disabled. This phase adds no managed HLS, MP4, AVI, or MPEG demux support.

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
- canonical per-file source/header/modulemap/plist and per-slice binary SHA-256 values equal bridge-artifact.lock;
- pinned source signature/checksum, bridge source hashes, configure allowlist, and recorded toolchain match the artifact provenance;
- verification never updates the lock, and a corrupted binary/source/configuration fails verification.

Run:

~~~bash
sh packages/yl_player_apple/tool/apple_ffmpeg/test_build_contract.sh
~~~

Expected: failure because the combined artifact does not exist.

- [ ] **Step 2: Unify bridge source**

Compare the current iOS/macOS bridge source, header, module map, and exported symbols first. The current source/header are identical; copy them byte-for-byte if that remains true at the checkpoint. If they diverge, explicitly reconcile every entry point and rebuild affected slices from that source before calling the result a unified artifact. Keep one Objective-C source guarded only where Apple SDK types differ. Do not pair new headers/source with stale binaries.

- [ ] **Step 3: Merge the existing slices without rebuilding FFmpeg first**

Use xcodebuild -create-xcframework with the two current iOS frameworks and the current universal macOS framework only after validating every input against its existing source/artifact lock. This is a provisional mechanical composition. Preserve the versioned macOS framework layout, symlinks, install name, exported ABI, and deployment minimums. Do not mark the artifact verified by merely refreshing checksums; final lock acceptance requires the clean source rebuild and comparison in Step 4.

- [ ] **Step 4: Make a full source rebuild produce the same layout**

Merge the pinned source verification/configuration from both old build scripts without expanding enabled components. Build arm64 iOS, arm64/x86_64 simulator, and arm64/x86_64 macOS into a fresh temporary output directory, lipo only same-platform macOS/simulator slices, then xcodebuild -create-xcframework. Never lipo iOS and macOS together.

Give the script separate --verify and --rebuild-check modes. --verify checks the committed artifact/lock without mutation. --rebuild-check verifies signed source inputs, rebuilds outside the committed output, compares source/configuration/toolchain provenance and canonical per-slice contents against the committed artifact, and fails on unexplained drift. Pin or normalize build paths, archive metadata, UUID/signing metadata, and SDK/toolchain inputs needed for reproducible comparison; do not ignore an entire binary because a build field differs. A reviewed artifact update may write a new lock only after the rebuild comparison is understood. Include negative tests proving changed bridge source, changed FFmpeg flags, and a corrupted slice cannot pass by automatic lock refresh.

Root tool/ios_ffmpeg/build_xcframework.sh delegates to the package script during migration so there is one build implementation.

- [ ] **Step 5: Pass, verify linkage, and commit**

Run:

~~~bash
sh packages/yl_player_apple/tool/apple_ffmpeg/test_build_contract.sh
sh packages/yl_player_apple/tool/apple_ffmpeg/build_xcframework.sh --rebuild-check
swift package dump-package --package-path packages/yl_player_apple/darwin/yl_player_apple
pod spec lint packages/yl_player_apple/darwin/yl_player_apple.podspec --quick --allow-warnings
~~~

Expected: artifact provenance/rebuild, manifest, and podspec shape checks pass. --quick pod lint and dump-package are metadata checks; real Flutter linkage is proved by bootstrapped consumers in Task 3 and full package-manager consumers in the release plan.

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
- Create: tool/bootstrap_apple_consumers.sh
- Create: tool/check_apple_consumer.sh
- Create fixture templates under tool/consumer_fixtures/apple_flutter for independent iOS/macOS Flutter test hosts.

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

First implement tool/bootstrap_apple_consumers.sh: capture YL_REPO_ROOT with git rev-parse --show-toplevel while still in the active checkout, accept/validate a caller-supplied YL_REPO_ROOT when invoked from elsewhere, then create independent Flutter application hosts from tracked fixture templates into temporary directories. Pass the captured root through every subprocess; never rediscover it after changing into a temporary consumer. Add direct path dependencies/overrides for yl_player_apple and yl_player_platform_interface. Never depend on the main example or old Apple plugin registrations. Configure iOS 15/macOS 12, select SwiftPM or CocoaPods explicitly, then run Flutter pub get and platform config-only builds. This supplies the real Flutter/FlutterMacOS engine and, for SwiftPM, FlutterFramework plus the generated dependency graph. Do not handwrite a dummy FlutterFramework or copy plugin sources/frameworks into the consumer.

Implement tool/check_apple_consumer.sh --platform ios|macos --manager swiftpm|cocoapods --unit-only|--link against those generated hosts. It verifies actual package-manager selection, imports, deployment floors, framework embedding/rpaths, and test results. Retain only templates/scripts; exclude all generated app/cache outputs from Git and publication archives. The final release consumer gate reuses this bootstrap.

Copy the corresponding iOS test cases for byte buffers, packet queues, buffer budget, source routing, HLS, network source, open coordinator, track/state encoding, and reconnect policy into these hosts. Build the moved source dependency closure with unchanged internal domain models needed for characterization; keep temporary scaffolding private and remove it when Task 7 supplies the final host. Ensure each tested moved source has its full production dependency closure; temporary host glue may adapt registration but must not replace the behavior under characterization. Compile/test against yl_player_apple in the bootstrapped environment. The main example remains unchanged until Task 8. Task 1's native/Dart registration skeletons satisfy generated plugin registration in these hosts; the tests exercise real copied core implementations, then Task 7 replaces the native skeleton with the production host before full plugin behavior/linkage tests.

- [ ] **Step 4: Prove source identity and compile**

Run:

~~~bash
sh packages/yl_player_apple/tool/check_source_parity.sh --verify-identical
sh tool/bootstrap_apple_consumers.sh
sh tool/check_apple_consumer.sh --platform macos --manager swiftpm --unit-only
sh tool/check_apple_consumer.sh --platform ios --manager swiftpm --unit-only
sh tool/check_apple_consumer.sh --platform ios --manager cocoapods --unit-only
sh tool/check_apple_consumer.sh --platform macos --manager cocoapods --unit-only
~~~

Expected: copied-source hashes match and shared source tests compile/run on macOS and iOS Simulator under both actual CocoaPods and actual SwiftPM linkage. A silent fallback to the other package manager is failure. A missing generated FlutterFramework or unresolved Flutter module fails the gate; no bare-source Swift build substitutes for it.

- [ ] **Step 5: Commit**

~~~bash
git add packages/yl_player_apple/darwin/yl_player_apple/Sources packages/yl_player_apple/tool/check_source_parity.sh packages/yl_player_apple/darwin/yl_player_apple/Package.swift tool/bootstrap_apple_consumers.sh tool/check_apple_consumer.sh tool/consumer_fixtures/apple_flutter
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

Port all current iOS and macOS tests for AudioRenderer, FrameScheduler, MediaClock, VideoToolboxDecoder, AVPlayer state/failure policy, fallback lifecycle/recovery, and open/rollback. Keep the checkpointed macOS high-rate scheduling/decoder regressions and subsequent authorized submission, audio serialization, and display-binding review fixes intact.

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

Use the macOS file from 1b239e0/49f59cf plus subsequent authorized review fixes as the shared base for YlAudioRenderer, YlAvPlayerBackend, YlFallbackBackend, YlFrameScheduler, YlMediaClock, YlPlaybackBackend, YlOpenCoordinator, and YlVideoToolboxDecoder because those contain the newest verified timing/rollback/decoder hardening.

Then port every iOS-only branch identified by git diff, including YlBoundedPacketQueue use, iOS interruption/lifecycle behavior, iOS AVPlayer recovery policy, and simulator/device VideoToolbox handling. Use compile-time platform adapters only for SDK differences; do not maintain two algorithm copies.

Unify YlAvPlayerFailurePolicy and YlAvPlayerRecoveryPolicy under YlAvPlayerRecoveryPolicy. Preserve both test matrices before deleting either old name in the new package.

- [ ] **Step 4: Lock behavioral constants**

diff_behavioral_constants.sh extracts numeric constants and relevant enum cases from old and new clock/scheduler/buffer/retry/decoder files. Every difference requires an allowlist line with old file, new file, and reason import/platform abstraction. No tuning change is allowed in this plan.

- [ ] **Step 5: Run both native test matrices against the shared files**

Run both complete characterization matrices in the independent Flutter consumers while the original native scripts still verify the old baseline. The new-source gates are:

~~~bash
sh tool/check_apple_consumer.sh --platform ios --manager swiftpm --unit-only
sh tool/check_apple_consumer.sh --platform ios --manager cocoapods --unit-only
sh tool/check_apple_consumer.sh --platform macos --manager cocoapods --unit-only
sh tool/check_apple_consumer.sh --platform macos --manager swiftpm --unit-only
~~~

Also run:

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
- Produces independent schemaMajor = 2 and spiMajor = 2 handshake checks, factory HostApi, per-instance Player HostApi, and per-instance FlutterApi callbacks.
- Transport covers both iOS and macOS with an ApplePlatform enum.

- [ ] **Step 1: Write a failing generated-schema smoke test**

Construct create/options/source/load/full-state/delta/event/failure messages and assert ApplePlatform.ios and ApplePlatform.macos round-trip through the Dart codec.

- [ ] **Step 2: Declare exact enum and message set**

The Pigeon schema must declare these enums:

- ApplePlatform: ios, macos.
- AppleSourceKind: file, network, content.
- AppleStreamIntent: automatic, onDemand, live.
- AppleMediaFormat: automatic, hls, mp4, mov, matroska, webm, mpegTs, mpegPs, flv, avi.
- AppleNetworkPolicyKind: platformDefault, managed.
- AppleBufferKind: automatic, lowLatency, smoothPlayback, bounded.
- AppleDecoderPolicy: systemDefault, hardwarePreferred, hardwareRequired.
- AppleAudioPolicy: appManaged, pluginManagedMediaPlayback.
- AppleAssessmentOutcome: compatible, incompatible, requiresInspection.
- ApplePlaybackStatus: idle, loading, ready, playing, paused, buffering, completed, failed.
- AppleEngine: unknown, avPlayer, managedFallback. unknown is valid for idle/no active engine; capabilities advertise only implemented avPlayer/managedFallback routes.
- AppleTrackKind: audio, video.
- ApplePlayerOperation: seek, seekToLiveEdge, playbackSpeed, audioTrackSelection, videoConstraints, volume, stop.
- AppleDecoderMode: unknown, hardware, software.
- AppleDecoderEvidence: none, hardwareOnly, hardwareAndSoftware.
- AppleFailureCategory and AppleFailureScope matching the public enums by name.

Declare these records with the listed fields and no dynamic/Object/map payload escape hatch:

All names below are schema classes; `int` generates Swift `Int64`, `double` generates Swift `Double`, and `?` denotes nullable. Lists and map entries are non-null and decoded into immutable public collections. Every field is required unless marked nullable.

- ApplePlayerOptionsMessage: decoderPolicy: AppleDecoderPolicy, audioPolicy: AppleAudioPolicy, positionUpdateIntervalMs: int.
- AppleCreateRequest: schemaMajor: int, options: ApplePlayerOptionsMessage.
- AppleCreateReply: schemaMajor: int, spiMajor: int, channelSuffix: String, textureId: int, platform: ApplePlatform, implementationName: String, implementationVersion: String, capabilities: AppleCapabilitiesMessage, initialState: AppleStateMessage.
- AppleCapabilitiesMessage: deviceProfile: String, availableEngines: List<AppleEngine>, decoderEvidence: AppleDecoderEvidence, maxConcurrentVideoDecoders: int?, maxWidth: int?, maxHeight: int?, hardwareVideoCodecs: List<String>, supportedOperations: List<ApplePlayerOperation>.
- AppleHttpRequestMessage: headers: Map<String, String>, credentials: Map<String, String>.
- AppleNetworkPolicyMessage: kind: AppleNetworkPolicyKind; connectTimeoutMs, readTimeoutMs, maxRetries, baseRetryDelayMs, maxRetryDelayMs, maxRedirects: int?. All six are non-null for managed and null for platformDefault. There is no call/overall timeout field or guarantee.
- AppleSourceMessage: kind: AppleSourceKind, locator: String, intent: AppleStreamIntent, format: AppleMediaFormat, request: AppleHttpRequestMessage?, networkPolicy: AppleNetworkPolicyMessage?. request/networkPolicy are non-null only for network; file intent is onDemand.
- AppleVideoConstraintsMessage: maxWidth: int?, maxHeight: int?, maxBitrate: int?.
- AppleBufferStrategyMessage: kind: AppleBufferKind, minDurationMs: int?, maxDurationMs: int?, maxManagedBytes: int?. All three values are non-null only for bounded.
- AppleLoadOptionsMessage: autoplay: bool, startPositionMs: int?, bufferStrategy: AppleBufferStrategyMessage, videoConstraints: AppleVideoConstraintsMessage, decoderPolicyOverride: AppleDecoderPolicy?.
- AppleAssessRequest and AppleLoadRequest: source: AppleSourceMessage, options: AppleLoadOptionsMessage.
- AppleAssessmentReply: outcome: AppleAssessmentOutcome, candidateEngine: AppleEngine?, satisfiedRequirements: List<String>, limitations: List<String>, rejection: AppleFailureMessage?. Rejection is present exactly for incompatible. Requirement/limitation strings are validated stable IDs decoded as YlRequirementId/YlLimitationId; retain unknown valid IDs for forward compatibility, and never transport free-form source-dependent prose in these lists.
- AppleLoadReply: sessionId: String.
- AppleSessionCommand: sessionId: String.
- AppleSeekCommand: sessionId: String, positionMs: int. AppleSpeedCommand: sessionId: String, speed: double. AppleTrackCommand: sessionId: String, trackId: String. AppleVideoConstraintsCommand: sessionId: String, constraints: AppleVideoConstraintsMessage.
- AppleDvrWindowMessage: startMs: int, endMs: int. AppleTimelineMessage: positionMs: int, durationMs: int?, bufferedPositionMs: int, isSeekable: bool, isLive: bool, isAtLiveEdge: bool?, liveOffsetMs: int?, dvrWindow: AppleDvrWindowMessage?.
- AppleSizeMessage: width: double, height: double. AppleVideoGeometryMessage: encodedSize: AppleSizeMessage, displaySize: AppleSizeMessage, pixelAspectRatio: double, rotationDegrees: int. displaySize precedes unapplied rotation; pixelAspectRatio is applied exactly once when deriving display aspect ratio.
- AppleTrackMessage: id: String, kind: AppleTrackKind, label: String?, language: String?, codec: String?, bitrate: int?, width: int?, height: int?, isSelected: bool.
- AppleMetricsMessage: loadToReadyMs, loadToFirstFrameMs, rebufferCount, rebufferDurationMs, droppedVideoFrames, audioUnderruns, estimatedBitrate, managedBufferedDurationMs, managedBufferedBytes, liveOffsetMs, reconnectCount: int?.
- AppleFailureMessage: category: AppleFailureCategory, code: String, message: String, retryable: bool, scope: AppleFailureScope, diagnosticId: String.
- AppleStateMessage: sessionId: String?, revision: int, sequence: int, status: ApplePlaybackStatus, timeline: AppleTimelineMessage, geometry: AppleVideoGeometryMessage?, audioTracks: List<AppleTrackMessage>, videoTracks: List<AppleTrackMessage>, engine: AppleEngine, decoderMode: AppleDecoderMode, decoderIdentity: String?, metrics: AppleMetricsMessage, failure: AppleFailureMessage?. Idle has null sessionId; session-bearing states require a non-empty ID. A player-scoped terminal protocol failure may have null sessionId.
- AppleStateDeltaMessage: sessionId: String, previousRevision: int, revision: int, sequence: int, positionMs: int?, bufferedPositionMs: int?, hasIsAtLiveEdge: bool, isAtLiveEdge: bool?, hasLiveOffsetMs: bool, liveOffsetMs: int?, metrics: AppleMetricsDeltaMessage?.
- AppleMetricsDeltaMessage: for each of the eleven AppleMetricsMessage fields, declare an explicit `has<Field>: bool` plus a nullable int value of the same name. A true flag and null clears a measurement; false leaves it unchanged. Ordinary nullable position/bufferedPosition delta values mean unchanged because the corresponding state fields cannot be null. A metrics delta cannot change tracks, geometry, engine, decoder identity, status, or failure.
- All four event classes require sessionId: String, revision: int, sequence: int, occurredAtMs: int. AppleFirstFrameMessage adds no fields. AppleRetryScheduledMessage adds retryIndex: int, delayMs: int, failure: AppleFailureMessage. AppleEngineChangedMessage adds previousEngine: AppleEngine and engine: AppleEngine. ApplePlaybackFailedMessage adds failure: AppleFailureMessage.

Validate on both sides before creating public values: identifiers are non-empty; revisions/sequences, byte counts, positions and monotonic-epoch timestamps are nonnegative signed-64-bit integers; a delta has revision > previousRevision; counters are nonnegative and retryIndex starts at 1. Widths/heights, finite size dimensions, pixel aspect, selected bitrates, and position intervals are positive; rotation is 0/90/180/270. Public live offsets are nonnegative milliseconds; clamp a negative raw engine offset to zero before transport, and preserve null when unknown. DVR start <= end. Managed timeout values fit positive signed-32-bit milliseconds before native timer conversion; retry/redirect counts fit nonnegative signed-32-bit values; retry delays are nonnegative and baseRetryDelay <= maxRetryDelay. Request durations and bounded byte budgets fit signed-32-bit native ranges; timeline, revision, sequence, and measured counters retain signed-64-bit range. Bounded fields obey the shared validators, including minDuration <= maxDuration and byte budget 1...2147483647. Volume is finite in 0...1 and speed finite in 0.25...4; never narrow integers unchecked. All times are integer milliseconds, rates are bits/second, and memory is bytes. Public event occurredAt is Duration since the implementation-local monotonic epoch, never wall clock. Share these boundaries with Dart/SPI validators instead of introducing Apple-only defaults. The create handshake is the sole implementation metadata authority: map implementationName/implementationVersion/spiMajor into backend.implementation once; capabilities never duplicate it. schemaMajor == 2 and spiMajor == ylPlayerSpiMajor == 2 are checked independently before attach.

For managed requests, connectTimeoutMs is the response-header deadline for each HTTP attempt/hop including DNS, connection, TLS, and server wait; readTimeoutMs measures post-header body inactivity. Neither promises an overall load deadline.

- [ ] **Step 3: Declare generated APIs**

Use the same method surface as the Android schema with Apple-prefixed types:

- ApplePlayerFactoryHostApi.create.
- ApplePlayerHostApi uses the exact typed Apple equivalents of the Android schema signatures. load, play, stop, and dispose are @async; play awaits activation and teardown commands await cleanup without blocking the main actor. attach, assess, pause, seekTo, seekToLiveEdge, setPlaybackSpeed, selectAudioTrack, setVideoConstraints, and setVolume perform immediate validation/enqueueing. Use explicit Apple request/command/reply classes listed above; no inferred map/void payload substitutions.
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

Cover every enum, iOS/macOS capabilities, AVPlayer decoder unknown, managed fallback hardware/software modes, geometry, nullable metrics, safe failures, source assessment, full-state ordering, delta previousRevision, sequence duplicates, stale-session events, and disposal. Delay callback acknowledgements and deliver load reply before/after its commit-state callback: in both orders load returns only after accepting its ID reply and installing the matching authoritative full state callback. Early callbacks for that pending session are buffered then matched against the replied session ID, never discarded as stale or applied to the previous session. Verify firstFrame remains pending for prepared-only decoder output and resolves only from committed texture publication.

- [ ] **Step 2: Write creation failure cleanup tests**

Assert schema mismatch, independent SPI-major mismatch, invalid texture/state, callback setup failure, and attach failure each best-effort dispose native host and remove callback setup. Successful create exposes capabilities immediately and has no property-read side effect.

- [ ] **Step 3: Prove failure**

Run:

~~~bash
flutter test packages/yl_player_apple/test
~~~

Expected: generated DTOs exist but the platform adapter is absent.

- [ ] **Step 4: Implement typed adapter**

Create private AppleFactoryTransport and ApplePlayerTransport interfaces matching every generated host method. Decode/encode public types without map coercion. Isolate the temporary managed/bounded/hardwareRequired assessment/load rejection in one named consolidation-only adapter guard with a test; hardening Task 2 must delete that guard and replace its tests with end-to-end native routing assertions. Create callback handler before attach and remove it after native dispose.

Implement one ordered reducer ingress shared by all generated FlutterApi callbacks and load replies. AppleLoadReply carries only sessionId. Retain both that reply and the matching authoritative full state callback; apply/reconcile state by session/revision/sequence before resolving load, then drain matching buffered callbacks. State-first arrivals cannot be discarded merely because the host reply is pending. Start a private 5-second reply-to-state deadline only if the reply arrives first; expiry is protocol.mismatch, terminates the transport, and triggers best-effort native disposal. This is a transport barrier deadline, not an overall network/load deadline. Never let a later stale load reply reactivate a cancelled/replaced session.

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
- Replace temporary registration skeleton: packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/YlPlayerApplePlugin.swift
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
- load commit returns session ID and publishes an authoritative full state callback; the adapter barrier prevents returning while state is still idle/old in either delivery order;
- callbacks of different FlutterApi methods share one acknowledged FIFO; delayed acknowledgements cannot reorder first-frame/failure relative to their states;
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

Reducer begins revision/sequence at zero, emits full states for semantic changes and deltas for periodic timeline/metrics. Emit the first ready transition (or a full state with immutable monotonic loadToReady evidence) before autoplay/playing or subsequent rebuffering; buffering alone cannot complete ready. Retain ready/firstFrame milestone evidence across same-session recovery. AVPlayer maps decoder mode unknown. Managed fallback maps hardware only after VideoToolbox session creation evidence; otherwise unknown in this phase.

All callback kinds pass through one per-Player serial outbound queue. Send the next generated FlutterApi call only after the previous call's acknowledgement; a shared sequence number alone does not order distinct Pigeon channels. Full states/events remain lossless, and pending periodic updates may be coalesced only before assigning their final revision/sequence. A failed acknowledgement causes bounded cleanup/session failure, not unbounded queue growth. Dart acknowledges after applying or safely buffering the message, never while waiting for another callback on that queue.

At commit, enqueue the authoritative full state callback with the committed session ID and return only that ID in AppleLoadReply. Dart matches both halves of the load/state barrier without relying on reply-versus-callback delivery order; the reply is not a second snapshot authority. Candidate inspection/decoder output cannot publish a public texture or firstFrame. Gate firstFrame at the first committed frame submitted to the public texture; reconnect/reconfiguration does not emit it again for the same session.

- [ ] **Step 5: Replace map event emission**

Change engine emit closures to typed internal domain callbacks, then encode only at YlApplePlayerHost. Remove YlIosChannel.swift and YlMacosChannel.swift from the new package. Keep old package files untouched until cleanup.

- [ ] **Step 6: Pass both native unit gates and commit**

Run:

~~~bash
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh --unit-only
~~~

Run the independent consumer unit gates as well:

~~~bash
sh tool/check_apple_consumer.sh --platform ios --manager swiftpm --unit-only
sh tool/check_apple_consumer.sh --platform ios --manager cocoapods --unit-only
sh tool/check_apple_consumer.sh --platform macos --manager cocoapods --unit-only
sh tool/check_apple_consumer.sh --platform macos --manager swiftpm --unit-only
~~~

Expected: old native scripts still pass the baseline, and independent consumers pass all old behavior characterizations plus new registry/session/reducer tests against yl_player_apple.

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
