# Player v0.2 View Cleanup and Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the display-geometry-aware player view, remove every v0.1 API/transport/package remnant, publish complete migration and support documentation, validate CocoaPods/SwiftPM/Gradle consumers, and make the four-package v0.2 tree release-ready.

**Architecture:** yl_player remains a thin application package over the handwritten SPI. YlPlayerView renders only the current committed session's texture using authoritative display geometry and the controller's correlated first-frame cache. The final workspace contains yl_player, yl_player_platform_interface, yl_player_android, and yl_player_apple; endorsed implementations own all generated transport code.

**Tech Stack:** Flutter widget tests and integration tests, Dart/Flutter package tooling, Gradle, CocoaPods, Swift Package Manager, Xcode, GitHub Actions.

**Spec:** docs/superpowers/specs/2026-09-06-player-v2-architecture-design.md

## Global Constraints

- Complete the Dart/SPI, Android, Apple consolidation, and Apple hardening plans first.
- Begin only from a fully green migration checkpoint.
- YlPlayerView contains no controls, gestures, autoplay, playlist, application state, subtitles, or error UI.
- Default rendering is BoxFit.contain, centered alignment, black background, and placeholder until the current session's first frame.
- A first frame from a replaced session can never reveal the current texture.
- Removing yl_player_ios, yl_player_macos, and the legacy adapter is an approved breaking v0.2 change. Use exact tracked paths and verify git status before deletion.
- Do not publish or push. This plan performs local/CI dry-runs only.
- Package archives contain required licenses and the combined Apple artifact but no build caches, test media not used by package consumers, secret logs, or generated temporary files.
- Physical-device/endurance/profile claims remain explicitly unverified until evidence exists.

---

## File and Responsibility Map

- View:
  - Rewrite packages/yl_player/lib/src/player_view.dart.
  - Extend controller with a read-only current-session first-frame presentation flag.
  - Rewrite packages/yl_player/test/player_view_test.dart.
- Cleanup:
  - Delete packages/yl_player_ios.
  - Delete packages/yl_player_macos.
  - Delete legacy channel adapter/codec/entrypoint from yl_player_platform_interface.
  - Remove old workspace/default-package/dependency/test references.
- Documentation:
  - Rewrite package READMEs/CHANGELOGs.
  - Create docs/migration-to-0.2.md, docs/platform-support.md, docs/policies.md, and docs/diagnostics.md.
- Consumer/release tooling:
  - Create tool/consumer_fixtures/android, apple_cocoapods, and apple_swiftpm.
  - Create tool/check_consumers.sh, check_publication.sh, and check_player_v2.sh.
  - Update .github/workflows/ci.yml.

---

### Task 1: Implement geometry-aware, first-frame-safe texture rendering

**Files:**
- Modify: packages/yl_player/lib/src/player_controller.dart
- Rewrite: packages/yl_player/lib/src/player_view.dart
- Rewrite: packages/yl_player/test/player_view_test.dart
- Modify: packages/yl_player/test/player_controller_test.dart

**Interfaces:**
- YlPlayerController exposes bool get isCurrentFramePresented, derived only from correlated current-session events.
- YlPlayerView options are controller, placeholder, fit, alignment, backgroundColor, and filterQuality.
- Defaults are BoxFit.contain, Alignment.center, Color(0xFF000000), and FilterQuality.low.

- [ ] **Step 1: Write failing first-frame correlation tests**

Cover:

~~~dart
testWidgets('keeps placeholder until current session first frame', (tester) async {
  final controller = await createControllerWithCommittedSession('s2');
  await tester.pumpWidget(
    SizedBox(
      width: 320,
      height: 180,
      child: YlPlayerView(
        controller: controller,
        placeholder: const Text('waiting'),
      ),
    ),
  );
  expect(find.text('waiting'), findsOneWidget);
  expect(find.byType(Texture), findsNothing);

  fakeBackend.emitFirstFrame(const YlPlaybackSessionId('s1'));
  await tester.pump();
  expect(find.text('waiting'), findsOneWidget);

  fakeBackend.emitFirstFrame(const YlPlaybackSessionId('s2'));
  await tester.pump();
  expect(find.text('waiting'), findsNothing);
  expect(find.byType(Texture), findsOneWidget);
});
~~~

Also test reset on replacement/stop, first frame arriving before the view mounts, and disposal.

- [ ] **Step 2: Write failing geometry/fit tests**

For a 1920x1080 display geometry inside 300x300, assert contain lays out 300x168.75 centered with black bars; cover fills/crops; Alignment.topLeft changes placement; 90-degree rotation uses swapped display aspect; custom background and filter quality reach the widgets; null geometry retains placeholder even if a malformed first-frame event arrives.

Assert the subtree contains no GestureDetector, Listener, IconButton, Slider, or platform view.

- [ ] **Step 3: Prove current view fails**

Run:

~~~bash
flutter test packages/yl_player/test/player_view_test.dart packages/yl_player/test/player_controller_test.dart
~~~

Expected: current Texture is shown as soon as textureId exists and has no geometry/fit/background semantics.

- [ ] **Step 4: Add a correlated controller presentation cache**

Reset isCurrentFramePresented to false when state.sessionId changes or becomes null. Set it true only for YlFirstFrameEvent whose sessionId equals current state.sessionId and whose revision is not older than current state revision. Notify listeners once when it changes. Cache survives view mount/unmount but clears on stop, replacement, failed current session, and dispose.

- [ ] **Step 5: Implement view layout**

Build a ColoredBox, ClipRect, and FittedBox. The FittedBox child is a SizedBox using the pre-rotation displaySize dimensions and is wrapped in RotatedBox whenever rotationDegrees is nonzero. The geometry contract guarantees rotationDegrees is only an unapplied clockwise texture rotation, so Flutter never rotates pixels that native already oriented. Texture appears only when textureId, valid geometry, and isCurrentFramePresented are all present. Otherwise render the supplied placeholder centered over the background; absent placeholder renders SizedBox.expand.

Do not infer aspect from encoded size when display geometry is available.

- [ ] **Step 6: Pass and commit**

Run:

~~~bash
dart format packages/yl_player/lib packages/yl_player/test
flutter test packages/yl_player/test/player_view_test.dart packages/yl_player/test/player_controller_test.dart
flutter analyze packages/yl_player
~~~

Expected: all pass.

~~~bash
git add packages/yl_player/lib packages/yl_player/test
git commit -m "feat: render authoritative video geometry"
~~~

### Task 2: Remove legacy Dart transport and v0.1 public symbols

**Files:**
- Delete:
  - packages/yl_player_platform_interface/lib/yl_player_legacy_transport.dart
  - packages/yl_player_platform_interface/lib/src/channel/channel_codec.dart
  - packages/yl_player_platform_interface/lib/src/channel/channel_player.dart
  - packages/yl_player_platform_interface/test/channel_codec_test.dart
  - packages/yl_player_platform_interface/test/channel_player_test.dart
- Remove any retained v0.1 model files and exports.
- Modify:
  - packages/yl_player_platform_interface/lib/yl_player_platform_interface.dart
  - packages/yl_player/lib/yl_player.dart
  - packages/yl_player_platform_interface/pubspec.yaml
  - packages/yl_player/pubspec.yaml
  - tool/check_foundation.sh

**Interfaces:**
- Platform interface contains only domain values, handwritten SPI, validation, safe diagnostics boundary, and conformance kit.
- App barrel contains only application-facing types.

- [ ] **Step 1: Add failing forbidden-surface checks**

Create tool/check_public_surface.sh. It fails on:

- YlPlayerConfiguration, YlBufferMode, YlFormatHint, YlPlayerError, YlTracksChangedEvent, YlFallbackEvent, isHardwareDecoding, platformDiagnostic;
- MethodChannel, EventChannel, BasicMessageChannel, PlatformException, or FlutterError in yl_player_platform_interface production sources;
- wildcard export of yl_player_platform_interface from yl_player;
- public import of any generated Pigeon library from yl_player or platform interface.

Run:

~~~bash
sh tool/check_public_surface.sh
~~~

Expected: it fails while the temporary legacy adapter remains.

- [ ] **Step 2: Delete the exact temporary files**

Remove only the listed tracked channel files and their barrel. Remove imports from foundation checks and pubspec dependencies that existed solely for Flutter channels. Keep Flutter foundation dependency needed for ValueListenable/Listenable.

- [ ] **Step 3: Remove old names without aliases**

Delete deprecated typedefs, forwarding constructors, and enum aliases. The 0.2 migration guide in Task 4 is the compatibility mechanism; runtime and source shims are not.

- [ ] **Step 4: Verify imports and public API**

Run:

~~~bash
sh tool/check_public_surface.sh
flutter test packages/yl_player_platform_interface/test
flutter test packages/yl_player/test
flutter analyze packages/yl_player_platform_interface packages/yl_player
~~~

Expected: all pass and forbidden names are absent.

- [ ] **Step 5: Commit**

~~~bash
git add packages/yl_player_platform_interface packages/yl_player tool/check_public_surface.sh tool/check_foundation.sh
git commit -m "refactor!: remove legacy player transport"
~~~

### Task 3: Delete old Apple packages and normalize the four-package workspace

**Files:**
- Delete exact tracked directories:
  - packages/yl_player_ios
  - packages/yl_player_macos
- Modify:
  - pubspec.yaml
  - pubspec.lock
  - packages/yl_player/pubspec.yaml
  - tool/check_foundation.sh
  - tool/check_native_ios.sh
  - tool/check_native_macos.sh
  - .github/workflows/ci.yml
- Remove stale generated project/plugin references under packages/yl_player/example.

**Interfaces:**
- Workspace contains exactly yl_player, yl_player/example, yl_player_platform_interface, yl_player_android, yl_player_android/example, and yl_player_apple.
- Endorsement maps Android to yl_player_android and iOS/macOS to yl_player_apple.

- [ ] **Step 1: Prove nothing imports old packages**

Run:

~~~bash
rg -n 'yl_player_ios|yl_player_macos|YlPlayerIos|YlPlayerMacos|YlPlayerIosPlugin|YlPlayerMacosPlugin' . --glob '!docs/superpowers/**' --glob '!docs/migration-to-0.2.md' --glob '!.git/**'
~~~

Expected before deletion: matches only old package contents, root workspace entries, old historical docs, and migration references. Any production/example/tool match outside those areas must be migrated first.

- [ ] **Step 2: Verify deletion targets**

Run:

~~~bash
git status --short packages/yl_player_ios packages/yl_player_macos
git ls-files packages/yl_player_ios packages/yl_player_macos
~~~

Expected: no uncommitted changes inside either deletion target and a bounded tracked-file list. Stop if either directory is dirty.

- [ ] **Step 3: Delete tracked packages and update workspace**

Use git rm only on the two exact package directories. Remove their workspace entries and test invocations. Regenerate pubspec.lock with flutter pub get. Regenerate iOS/macOS plugin registration/config-only projects and verify only YlPlayerApplePlugin remains.

- [ ] **Step 4: Run full gates**

Run:

~~~bash
flutter pub get
sh tool/check_foundation.sh
sh tool/check_native_ios.sh
sh tool/check_native_macos.sh
~~~

Expected: all pass without old directories.

- [ ] **Step 5: Commit and report deletion**

~~~bash
git add pubspec.yaml pubspec.lock packages/yl_player tool .github/workflows/ci.yml
git commit -m "refactor!: replace split apple packages"
~~~

Record in the commit/body and migration guide that tracked sources were removed but remain recoverable from Git history.

### Task 4: Write complete API, policy, support, and migration documentation

**Files:**
- Create:
  - README.md
- Rewrite:
  - packages/yl_player/README.md
  - packages/yl_player_platform_interface/README.md
  - packages/yl_player_android/README.md
  - packages/yl_player_apple/README.md
  - packages/yl_player/CHANGELOG.md
  - packages/yl_player_platform_interface/CHANGELOG.md
  - packages/yl_player_android/CHANGELOG.md
  - packages/yl_player_apple/CHANGELOG.md
- Create:
  - docs/migration-to-0.2.md
  - docs/platform-support.md
  - docs/policies.md
  - docs/diagnostics.md
- Modify: CONTEXT.md only if implementation terminology changed.

**Interfaces:**
- Documentation is source-accurate and contains runnable v0.2 examples.
- Migration guide maps every removed v0.1 application symbol to its v0.2 replacement.

- [ ] **Step 1: Add documentation compile tests**

Create packages/yl_player/test/documentation_examples_test.dart with the Dart snippets from the README represented as compiled helper functions. It must cover create, assess, load, ready, play, firstFrame, seek, stale-session handling, stop, and dispose.

- [ ] **Step 2: Write exact migration mapping**

Include this table and expand constructor argument differences:

| v0.1 | v0.2 |
|---|---|
| YlPlayerController(...) | await YlPlayerController.create(...) |
| YlPlayerConfiguration | YlPlayerOptions plus per-load YlLoadOptions |
| controller.open(source) | final session = await player.load(source) |
| controller.play/pause/seekTo | session.play/pause/seekTo |
| controller.seekToLiveEdge | session.seekToLiveEdge |
| controller.setPlaybackSpeed | session.setPlaybackSpeed |
| controller.selectAudioTrack | session.selectAudioTrack |
| controller.setQualityConstraint | session.setVideoConstraints |
| YlMediaSource.file/network/content | YlFileSource/YlNetworkSource/YlAndroidContentSource |
| bool isLive | YlStreamIntent |
| YlFormatHint.httpFlv or flv | YlMediaFormat.flv |
| YlBufferMode/custom fields | YlBufferStrategy |
| YlDecoderPolicy.hardwareOnly | YlDecoderPolicy.hardwareRequired |
| YlPlayerError | YlFailure plus YlPlayerException |
| isHardwareDecoding | YlDecoderMode |
| YlVideoSize | YlVideoGeometry |
| yl_player_ios/yl_player_macos | yl_player_apple |

State explicitly that no compatibility shim is provided.

- [ ] **Step 3: Document policy semantics and support matrix**

docs/policies.md must explain:

- platformDefault versus managed networking;
- ordinary headers versus same-origin credentials;
- automatic/lowLatency/smooth goals versus bounded package-owned budget;
- exact bounded memory exclusions;
- systemDefault/hardwarePreferred/hardwareRequired and positive evidence;
- appManaged versus pluginManagedMediaPlayback ownership.

docs/platform-support.md lists route/policy outcomes by Android Media3, Apple AVPlayer, and Apple managed fallback as supported, rejected, or inspection-dependent. It distinguishes automated evidence from physical evidence.

- [ ] **Step 4: Document diagnostics**

Explain stable failure categories/codes/scopes, diagnostic ID correlation, safe logging, and prohibited secret content. Do not document implementation methods that expose raw diagnostics because none should exist.

- [ ] **Step 5: Compile docs and commit**

Run:

~~~bash
flutter test packages/yl_player/test/documentation_examples_test.dart
rg -n 'YlPlayerConfiguration|YlMediaSource\.network|YlMediaSource\.file|YlPlayerError|hardwareOnly|httpFlv' README.md packages/*/README.md docs --glob '!docs/superpowers/**'
~~~

Expected: examples compile and old names appear only in the migration mapping.

~~~bash
git add README.md packages docs CONTEXT.md
git commit -m "docs: publish player v0.2 migration contract"
~~~

### Task 5: Add independent Android, CocoaPods, and SwiftPM consumer gates

**Files:**
- Create:
  - tool/consumer_fixtures/android/settings.gradle.kts
  - tool/consumer_fixtures/android/build.gradle.kts
  - tool/consumer_fixtures/android/app/build.gradle.kts
  - tool/consumer_fixtures/android/app/src/main/AndroidManifest.xml
  - tool/consumer_fixtures/apple_cocoapods/Podfile
  - tool/consumer_fixtures/apple_cocoapods/Runner.xcodeproj/project.pbxproj
  - tool/consumer_fixtures/apple_swiftpm/Package.swift
  - tool/consumer_fixtures/apple_swiftpm/Sources/Consumer/main.swift
  - tool/check_consumers.sh
- Modify:
  - packages/yl_player_apple/darwin/yl_player_apple.podspec
  - packages/yl_player_apple/darwin/yl_player_apple/Package.swift
  - .github/workflows/ci.yml

**Interfaces:**
- Consumer fixtures prove native package consumption independently of the plugin's main example.
- Android consumes the plugin AAR/Gradle project; CocoaPods consumes the local podspec for both iOS and macOS; SwiftPM resolves the local package and links the bridge for iOS Simulator and macOS.

- [ ] **Step 1: Add failing consumer script**

tool/check_consumers.sh must run:

- Android assembleDebug with compileSdk 36/minSdk 24 and a small Kotlin reference to YlPlayerAndroidPlugin.
- pod install plus xcodebuild for a minimal iOS Simulator consumer.
- pod install plus xcodebuild for a minimal macOS consumer.
- swift package resolve/dump-package and xcodebuild of an iOS Simulator scheme generated by the fixture.
- swift build for the macOS consumer.

Run:

~~~bash
sh tool/check_consumers.sh
~~~

Expected: failure because fixtures do not exist.

- [ ] **Step 2: Create minimal consumers**

Fixtures import/register only public plugin entry types and link YlFFmpegBridge. They do not copy plugin sources or frameworks. Keep platform floors iOS 15/macOS 12 and Java 17/minSdk 24.

- [ ] **Step 3: Prove both Apple package managers**

For each Apple consumer, inspect the linked binary with nm and otool/lipo:

- YlPlayerApplePlugin symbol present;
- YlFFmpegBridge symbol present;
- iOS Simulator has requested host architecture;
- macOS build contains arm64 and x86_64 in release fixture;
- minimum OS values are correct.

- [ ] **Step 4: Add CI consumer job**

Run Android consumer on Ubuntu and Apple consumers on macos-15. Cache package-manager artifacts but never commit Pods, DerivedData, .gradle, or .build directories.

- [ ] **Step 5: Pass and commit**

Run:

~~~bash
sh tool/check_consumers.sh
git status --short
~~~

Expected: all consumers build and no generated cache is untracked.

~~~bash
git add tool/consumer_fixtures tool/check_consumers.sh packages/yl_player_apple/darwin .github/workflows/ci.yml
git commit -m "test: add independent plugin consumers"
~~~

### Task 6: Add transport/performance invariants and publication dry-runs

**Files:**
- Create:
  - packages/yl_player_android/test/transport_invariants_test.dart
  - packages/yl_player_apple/test/transport_invariants_test.dart
  - packages/yl_player/example/integration_test/state_update_cadence_test.dart
  - tool/check_publication.sh
  - tool/check_player_v2.sh
- Modify:
  - packages/yl_player/pubspec.yaml
  - packages/yl_player_platform_interface/pubspec.yaml
  - packages/yl_player_android/pubspec.yaml
  - packages/yl_player_apple/pubspec.yaml
  - packages/yl_player/CHANGELOG.md
  - packages/yl_player_platform_interface/CHANGELOG.md
  - packages/yl_player_android/CHANGELOG.md
  - packages/yl_player_apple/CHANGELOG.md
  - .gitignore
  - .github/workflows/ci.yml

**Interfaces:**
- Periodic typed messages contain no static capabilities/tracks/geometry/decoder data or media payload.
- Observable update cadence remains at the configured interval within integration tolerance.
- Four packages pass publish dry-run.

- [ ] **Step 1: Write transport invariant tests**

Reflect over or construct generated delta messages and assert they have only session/order/timeline/common-metric fields. Serialize a maximal delta with StandardMessageCodec and assert it remains below 768 bytes. Scan Pigeon schemas for byte arrays/media payload fields and fail if present.

- [ ] **Step 2: Write cadence integration**

Configure positionUpdateInterval to 250 ms, play a repository fixture for 5 seconds, and assert at least 12 and at most 28 distinct timeline revisions after Ready. Assert no capabilities/track/geometry equality changes during those deltas and no stale-session state after replacement.

- [ ] **Step 3: Create publication gate**

tool/check_publication.sh runs from each publishable package:

~~~bash
dart pub publish --dry-run
~~~

It fails on path dependencies, missing README/CHANGELOG/LICENSE, uncommitted generated Pigeon drift, missing combined artifact contract, package archive build/cache files, or versions other than the synchronized 0.2.0-dev.1 set.

Set version 0.2.0-dev.1 in the four publishable pubspecs and update their inter-package constraints to ^0.2.0-dev.1 before running the gate. The example packages remain publish_to: none and are not version-synchronized release artifacts.

- [ ] **Step 4: Create one full v0.2 gate**

tool/check_player_v2.sh runs in this order:

1. Android and Apple Pigeon drift checks.
2. Combined FFmpeg artifact contract.
3. Foundation.
4. Android JVM and optional emulator integration when YL_ANDROID_DEVICE_ID is set.
5. iOS Simulator native/integration.
6. macOS native/universal/Rosetta/integration.
7. Consumer fixtures.
8. Public-surface scan.
9. Publication dry-run.
10. dart format, flutter analyze, git diff --check.

It supports --no-device only for local planning; CI release gate supplies all automated devices.

- [ ] **Step 5: Pass and commit**

Run:

~~~bash
flutter test packages/yl_player_android/test/transport_invariants_test.dart
flutter test packages/yl_player_apple/test/transport_invariants_test.dart
sh tool/check_publication.sh
git diff --check
~~~

Expected: all pass.

~~~bash
git add packages tool .gitignore .github/workflows/ci.yml
git commit -m "build: add player v0.2 release gates"
~~~

### Task 7: Final acceptance and release evidence

**Files:**
- Modify:
  - docs/verification/player-v2-migration.md
  - docs/platform-support.md
  - packages/*/CHANGELOG.md
- Modify only defects found by acceptance checks.

- [ ] **Step 1: Verify repository topology and forbidden names**

Run:

~~~bash
find packages -mindepth 1 -maxdepth 1 -type d -print | sort
rg -n 'yl_player_ios|yl_player_macos|yl_player_legacy_transport|YlPlayerConfiguration|YlPlayerError|YlTracksChangedEvent|YlFallbackEvent|httpFlv|hardwareOnly' . --glob '!.git/**' --glob '!docs/superpowers/**' --glob '!docs/migration-to-0.2.md'
~~~

Expected: only four publishable package directories plus example subpackages; forbidden names have no production/build/tool references.

- [ ] **Step 2: Verify architecture and security boundaries**

Run:

~~~bash
sh tool/check_public_surface.sh
rg -n 'MethodChannel|EventChannel|FlutterMethodChannel|FlutterEventChannel' packages --glob '!**/*.g.dart' --glob '!**/*.g.kt' --glob '!**/*.g.swift'
rg -n 'stackTraceToString|callStackSymbols|platformDiagnostic|absoluteString.*error|localizedDescription.*message' packages
~~~

Expected: no handwritten transport and no raw diagnostic transport. Any centralized safe logger match must be manually verified and documented.

- [ ] **Step 3: Run the full automated gate**

Run:

~~~bash
sh tool/check_player_v2.sh
~~~

Expected: every automated gate passes. Record exact elapsed time, test counts, simulator/emulator/runtime versions, architecture slices, artifact checksum, and package dry-run sizes.

- [ ] **Step 4: Audit every acceptance criterion**

Mark each design-spec acceptance criterion pass/fail with a direct test/file/gate reference. Do not mark physical Android TV, physical iOS decoder performance, Intel Mac native runtime, soak/reconnect endurance, Instruments, or memgraph complete unless those runs actually occurred.

- [ ] **Step 5: Inspect working tree and commit evidence**

Run:

~~~bash
git status --short
git diff --check
git log --oneline --decorate -20
~~~

Expected: only final evidence/document corrections are dirty.

~~~bash
git add docs packages/*/CHANGELOG.md
git commit -m "docs: record player v0.2 acceptance"
~~~

- [ ] **Step 6: Stop before publication**

Report the final commit, full gate outcome, package dry-run status, and deferred evidence. Do not tag, publish, push, or create a release without a new explicit user request.
