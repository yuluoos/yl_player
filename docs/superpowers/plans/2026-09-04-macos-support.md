# yl_player macOS Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a first-party macOS 12+ playback implementation with AVPlayer and hardware-only FFmpeg/VideoToolbox fallback parity for the existing `yl_player` Dart API.

**Architecture:** Add an endorsed `yl_player_macos` federated package instead of changing the iOS package. The native plugin uses AVPlayer for compatible media and a bounded libavformat, VideoToolbox, and Apple-native audio pipeline for MKV and HTTP-FLV, with all decoded media remaining native.

**Tech Stack:** Flutter 3.44+, Dart 3.12+, Swift, FlutterMacOS, AVFoundation, CoreVideo, VideoToolbox, AudioToolbox/AVFAudio, Network.framework, FFmpeg 9.0.1, CocoaPods/Xcode.

**Spec:** `docs/superpowers/specs/2026-09-04-macos-support-design.md`

## Global Constraints

- Minimum runtime is macOS 12.0.
- Build and link both `arm64` and `x86_64`; runtime integration executes on the available Apple Silicon Mac.
- Preserve the existing public Dart API and shared channel protocol.
- Keep video decoding hardware-only; never add a software video-decoding fallback.
- Keep decoded video and audio data out of Flutter channels.
- Preserve current Android and iOS behavior and test coverage.
- Keep subtitle, DRM, download/cache, background-audio, PiP, casting, playlist, and controls work out of scope.
- Strip `Authorization`, `Cookie`, and `Proxy-Authorization` on cross-origin redirects.
- Record Intel as build/link verified but not Intel-hardware runtime tested.

---

### Task 1: Endorsed Dart macOS package

**Files:**
- Create: `packages/yl_player_macos/pubspec.yaml`
- Create: `packages/yl_player_macos/analysis_options.yaml`
- Create: `packages/yl_player_macos/lib/yl_player_macos.dart`
- Create: `packages/yl_player_macos/test/yl_player_macos_test.dart`
- Create: `packages/yl_player_macos/LICENSE`
- Create: `packages/yl_player_macos/CHANGELOG.md`
- Modify: `pubspec.yaml`
- Modify: `packages/yl_player/pubspec.yaml`

**Interfaces:**
- Consumes: `createYlChannelPlayer`, `YlPlayerPlatform`, and `YlPlayerConfiguration` from `yl_player_platform_interface`.
- Produces: `YlPlayerMacos.registerWith()` and `YlPlayerMacos.createPlayer(YlPlayerConfiguration)`.

- [ ] **Step 1: Write the failing Dart registration and channel tests**

Create tests that use a real mock binary messenger boundary and hand-written responses:

```dart
const methods = MethodChannel('yl_player_macos_test/methods');

test('registerWith installs the macOS implementation', () {
  YlPlayerMacos.registerWith();
  expect(YlPlayerPlatform.instance, isA<YlPlayerMacos>());
});

test('creates a macOS texture player through the shared protocol', () async {
  final platform = YlPlayerMacos(
    methodChannel: methods,
    nativeEvents: nativeEvents.stream,
  );
  final player = await platform.createPlayer(const YlPlayerConfiguration());
  expect(player.textureId.value, 42);
  expect((calls.single.arguments as Map)['configuration'], containsPair('decoderPolicy', 'hardwareOnly'));
  await player.dispose();
});
```

- [ ] **Step 2: Run the tests and verify RED**

Run: `flutter test packages/yl_player_macos/test`

Expected: compilation fails because `package:yl_player_macos/yl_player_macos.dart` and `YlPlayerMacos` do not exist.

- [ ] **Step 3: Add package metadata and the Dart adapter**

Implement the adapter with the platform-specific channel names and shared codec:

```dart
final class YlPlayerMacos extends YlPlayerPlatform {
  factory YlPlayerMacos({
    MethodChannel methodChannel = const MethodChannel(
      'dev.ylplayer.yl_player_macos/methods',
    ),
    EventChannel eventChannel = const EventChannel(
      'dev.ylplayer.yl_player_macos/events',
    ),
    Stream<Object?>? nativeEvents,
  }) => YlPlayerMacos._(
    methodChannel,
    nativeEvents ?? eventChannel.receiveBroadcastStream(),
  );

  YlPlayerMacos._(this._methodChannel, this._nativeEvents);

  final MethodChannel _methodChannel;
  final Stream<Object?> _nativeEvents;

  static void registerWith() => YlPlayerPlatform.instance = YlPlayerMacos();

  @override
  Future<YlPlatformPlayer> createPlayer(YlPlayerConfiguration configuration) =>
      createYlChannelPlayer(
        configuration: configuration,
        methods: _methodChannel,
        nativeEvents: _nativeEvents,
        platform: 'macos',
        initialEngine: YlPlaybackEngine.avPlayer,
      );
}
```

Add `packages/yl_player_macos` to the root workspace and endorse it under `flutter.plugin.platforms.macos.default_package` in `packages/yl_player/pubspec.yaml`.

- [ ] **Step 4: Run the Dart package and foundation tests**

Run: `flutter test packages/yl_player_macos/test`

Expected: all macOS adapter tests pass.

Run: `flutter test packages/yl_player/test packages/yl_player_platform_interface/test`

Expected: existing public API and contract tests pass.

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml packages/yl_player/pubspec.yaml packages/yl_player_macos
git commit -m "feat(macos): add endorsed platform package"
```

### Task 2: Native channel contract and lifecycle shell

**Files:**
- Create: `packages/yl_player_macos/macos/yl_player_macos.podspec`
- Create: `packages/yl_player_macos/macos/Classes/YlMacosChannel.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlMacosLifecyclePolicy.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlPlayerMacosPlugin.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlMacosPlayer.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlPlaybackBackend.swift`
- Create: `packages/yl_player/example/macos/**`
- Create: `packages/yl_player/example/macos/RunnerTests/YlMacosChannelTests.swift`
- Create: `packages/yl_player/example/macos/RunnerTests/YlMacosLifecyclePolicyTests.swift`
- Create: `tool/check_native_macos.sh`

**Interfaces:**
- Consumes: method names `create`, `command`, `dispose` and versioned event maps from the shared Dart channel codec.
- Produces: `NativePlayerError`, `PlayerConfiguration`, `YlMacosChannelGeneration.next()`, `YlMacosLifecyclePolicy`, `YlPlayerMacosPlugin`, and the internal `YlPlaybackBackend` contract.

- [ ] **Step 1: Generate the native test harness and write failing contract tests**

Generate the standard Flutter macOS runner under
`packages/yl_player/example/macos`, set its deployment target to macOS 12, add
the `RunnerTests` unit-test target, and create `tool/check_native_macos.sh` with
an `--unit-only` mode that invokes that target. This is test infrastructure;
do not add player behavior in this step.

Add literal-map tests that catch incorrect protocol mapping:

```swift
func testConfigurationDefaultsToHardwareOnly() {
  let configuration = PlayerConfiguration(map: [:])
  XCTAssertEqual(configuration.decoderPolicy, "hardwareOnly")
  XCTAssertEqual(configuration.bufferMode, "automatic")
}

func testLifecycleTerminationDisposesAllPlayers() {
  XCTAssertEqual(
    YlMacosLifecyclePolicy.action(for: .willTerminate),
    .disposeAll
  )
}

func testLifecycleResignActivePreservesPlayback() {
  XCTAssertEqual(
    YlMacosLifecyclePolicy.action(for: .didResignActive),
    .preserve
  )
}
```

- [ ] **Step 2: Run native tests and verify RED**

Run: `sh tool/check_native_macos.sh --unit-only`

Expected: the test target compiles far enough to fail because
`PlayerConfiguration` and `YlMacosLifecyclePolicy` are absent.

- [ ] **Step 3: Implement the channel primitives and lifecycle policy**

Port the iOS value conversion and error mapping into macOS-named types. Define the lifecycle API explicitly:

```swift
enum YlMacosLifecycleEvent { case didResignActive, didBecomeActive, willTerminate }
enum YlMacosLifecycleAction: Equatable { case preserve, emitState, disposeAll }

enum YlMacosLifecyclePolicy {
  static func action(for event: YlMacosLifecycleEvent) -> YlMacosLifecycleAction {
    switch event {
    case .didResignActive: return .preserve
    case .didBecomeActive: return .emitState
    case .willTerminate: return .disposeAll
    }
  }
}
```

Register `dev.ylplayer.yl_player_macos/methods` and `/events` through `FlutterMacOS`. The plugin owns an `[Int64: YlMacosPlayer]` map, returns `{playerId, textureId}`, enforces one active decoder, and makes disposal idempotent.

- [ ] **Step 4: Run native contract tests and verify GREEN**

Run: `sh tool/check_native_macos.sh --unit-only`

Expected: channel and lifecycle tests pass with zero failures.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_macos/macos packages/yl_player/example/macos tool/check_native_macos.sh
git commit -m "feat(macos): add native plugin channel shell"
```

### Task 3: Reproducible universal macOS FFmpeg bridge

**Files:**
- Create: `packages/yl_player_macos/tool/macos_ffmpeg/ffmpeg-9.0.1.lock`
- Create: `packages/yl_player_macos/tool/macos_ffmpeg/FFMPEG_RELEASE_KEY.asc`
- Create: `packages/yl_player_macos/tool/macos_ffmpeg/test_build_contract.sh`
- Create: `packages/yl_player_macos/tool/macos_ffmpeg/build_xcframework.sh`
- Create: `packages/yl_player_macos/macos/native/YlFFmpegBridge/include/YlFFmpegBridge.h`
- Create: `packages/yl_player_macos/macos/native/YlFFmpegBridge/module.modulemap`
- Create: `packages/yl_player_macos/macos/native/YlFFmpegBridge/YlFFmpegBridge.m`
- Create: `packages/yl_player_macos/macos/Frameworks/YlFFmpegBridge.xcframework/**`
- Create: `packages/yl_player_macos/LICENSES/FFmpeg-LGPL-2.1-or-later.txt`
- Create: `packages/yl_player_macos/THIRD_PARTY_NOTICES.md`
- Modify: `packages/yl_player_macos/macos/yl_player_macos.podspec`

**Interfaces:**
- Consumes: the existing C bridge ABI declared in `packages/yl_player_ios/ios/native/YlFFmpegBridge/include/YlFFmpegBridge.h`.
- Produces: the same exported `ylf_*` C functions in a macOS 12 universal XCFramework.

- [ ] **Step 1: Write the failing executable build-contract test**

The test runs `build_xcframework.sh --print-contract`, checks behavior rather than source text, and asserts these literal outputs:

```text
MACOS_DEPLOYMENT_TARGET=12.0
MACOS_ARCHITECTURES=macos-arm64,macos-x86_64
FFMPEG_X86_64_FLAGS=--disable-x86asm
```

It also executes `lipo -archs` on the shipped framework and requires both `arm64` and `x86_64`, then compiles and runs a small program that calls `ylf_ffmpeg_version()` and `ylf_build_configuration()`.

- [ ] **Step 2: Run the contract test and verify RED**

Run: `sh packages/yl_player_macos/tool/macos_ffmpeg/test_build_contract.sh`

Expected: fails because the build script and macOS framework do not exist.

- [ ] **Step 3: Implement the pinned universal build**

Reuse the verified FFmpeg version, archive digest, signing key, bridge ABI, and minimal configure flags. Build separate macOS slices:

```bash
build_slice arm64 aarch64 "-mmacosx-version-min=12.0"
build_slice x86_64 x86_64 "-mmacosx-version-min=12.0"
lipo -create "$arm_binary" "$intel_binary" -output "$universal_binary"
xcodebuild -create-xcframework -framework "$universal_framework" -output "$output"
```

Link CoreFoundation, CoreMedia, Foundation, and Security. Add the vendored XCFramework and required Apple frameworks to the podspec without changing the iOS artifact.

- [ ] **Step 4: Build and verify GREEN**

Run: `sh packages/yl_player_macos/tool/macos_ffmpeg/build_xcframework.sh`

Expected: creates the universal macOS XCFramework.

Run: `sh packages/yl_player_macos/tool/macos_ffmpeg/test_build_contract.sh`

Expected: pin, signature metadata, ABI smoke program, deployment target, licenses, and both architectures pass.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_macos
git commit -m "build(macos): add universal FFmpeg bridge"
```

### Task 4: AVPlayer playback backend

**Files:**
- Create: `packages/yl_player_macos/macos/Classes/YlAvPlayerBackend.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlOpenCoordinator.swift`
- Modify: `packages/yl_player_macos/macos/Classes/YlMacosPlayer.swift`
- Modify: `packages/yl_player_macos/macos/Classes/YlPlayerMacosPlugin.swift`
- Create: `packages/yl_player/example/macos/RunnerTests/YlMacosAvPlayerStateTests.swift`
- Create: `packages/yl_player/example/macos/RunnerTests/YlMacosOpenCoordinatorTests.swift`
- Create: `packages/yl_player/example/integration_test/macos_hls_playback_test.dart`

**Interfaces:**
- Consumes: `YlPlaybackBackend`, `NativePlayerError`, configuration maps, the plugin texture registry, and versioned state/event encoding.
- Produces: `YlAvPlayerBackend`, `YlOpenCoordinator`, and AVPlayer handling for open/play/pause/seek/live edge/speed/volume/audio track/quality commands.

- [ ] **Step 1: Write failing coordinator and state tests**

Cover superseded-open cancellation and pending play intent with observable results:

```swift
func testSecondOpenCancelsFirstCompletion() async {
  let coordinator = YlOpenCoordinator()
  // First prepare blocks; second completes and commits.
  // Assert first error code is network.cancelled and only second commits.
}

func testPlayIntentReportsBufferingUntilRateStarts() {
  let state = YlAvPlayerStatePolicy.status(
    wantsToPlay: true,
    itemReady: true,
    rate: 0,
    waiting: true
  )
  XCTAssertEqual(state, "buffering")
}
```

Add an integration test that opens the deterministic HLS fixture, waits for ready and first frame, plays until position advances, pauses, and disposes.

- [ ] **Step 2: Run tests and verify RED**

Run: `sh tool/check_native_macos.sh --unit-only`

Expected: missing AVPlayer state policy and open coordinator failures.

- [ ] **Step 3: Implement AVPlayer and texture rendering**

Use `AVPlayerItemVideoOutput` with BGRA pixel buffers and a display-link/timer tick that calls `textures.textureFrameAvailable(textureId)` only when a new frame is available. Implement the backend contract:

```swift
protocol YlPlaybackBackend: AnyObject {
  var isActive: Bool { get }
  func activate() throws
  func quiesceForReplacement()
  func deactivate()
  func command(name: String, arguments: [String: Any?]) throws
  func emitState()
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>?
  func dispose()
}
```

Observe AVPlayer item status, time control status, duration, loaded ranges, tracks, completion, and errors. Emit one first-frame event per source generation and compact position deltas no more frequently than the existing Apple implementation.

- [ ] **Step 4: Verify unit and HLS integration GREEN**

Run: `sh tool/check_native_macos.sh --unit-only`

Expected: coordinator and AVPlayer state tests pass.

Run: `flutter test packages/yl_player/example/integration_test/macos_hls_playback_test.dart -d macos`

Expected: ready, first frame, position advancement, pause, and clean disposal pass.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_macos/macos packages/yl_player/example/macos packages/yl_player/example/integration_test/macos_hls_playback_test.dart
git commit -m "feat(macos): add AVPlayer playback path"
```

### Task 5: Bounded source routing and network layer

**Files:**
- Create: `packages/yl_player_macos/macos/Classes/YlFallbackModels.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlSourceRouter.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlByteSource.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlByteRingBuffer.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlNetworkRequestPolicy.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlNetworkByteSource.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlHlsHeaderPolicy.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlHlsURLCodec.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlHlsManifestRewriter.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlHlsResourceLoader.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlHlsMediaProxy.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlLiveReconnectController.swift`
- Create: `packages/yl_player/example/macos/RunnerTests/YlMacosNetworkTests.swift`
- Create: `packages/yl_player/example/macos/RunnerTests/YlMacosHlsTests.swift`

**Interfaces:**
- Consumes: source/configuration maps and `NativePlayerError`.
- Produces: `YlMacosSourceDescriptor`, `YlMacosSourceRoute`, `YlByteSource`, `YlNetworkRequestRecipe`, header policies, HLS preparation, and bounded retry behavior.

- [ ] **Step 1: Write failing routing, credential, range, cancellation, and HLS tests**

Use literal cases including:

```swift
func testCrossOriginRedirectStripsCredentials() {
  let headers = YlNetworkRequestPolicy.redirectHeaders(
    originalURL: URL(string: "https://a.test/live")!,
    redirectedURL: URL(string: "https://b.test/live")!,
    headers: [
      "Authorization": "Bearer secret",
      "Cookie": "sid=secret",
      "Proxy-Authorization": "Basic secret",
      "User-Agent": "yl-test",
    ]
  )
  XCTAssertEqual(headers, ["User-Agent": "yl-test"])
}
```

Also require local MKV → `.localMatroska`, network MKV → `.networkMatroska`, HTTP-FLV → `.networkFlv`, headered HLS → `.headeredHls`, and unsupported headered progressive media → structured rejection.

- [ ] **Step 2: Run tests and verify RED**

Run: `sh tool/check_native_macos.sh --unit-only`

Expected: routing and request-policy types are missing.

- [ ] **Step 3: Port the platform-neutral policies and adapt macOS-only imports**

Port the proven iOS ring buffer, request recipe, retry controller, HLS URL codec, manifest rewriting, resource-loader, and loopback proxy behavior. Rename public internal source types to `YlMacos*`, import `UniformTypeIdentifiers` rather than `MobileCoreServices`, and preserve the three-header cross-origin deny list.

The byte source must enforce both configured byte capacity and deadlines, return cancellation promptly, validate response ranges, and never reuse old-generation callbacks.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `sh tool/check_native_macos.sh --unit-only`

Expected: all routing, credential, byte-source, retry, and HLS tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_macos/macos/Classes packages/yl_player/example/macos/RunnerTests
git commit -m "feat(macos): add bounded network and source routing"
```

### Task 6: FFmpeg, VideoToolbox, and native-audio fallback

**Files:**
- Create: `packages/yl_player_macos/macos/Classes/YlBoundedPacketQueue.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlFallbackBufferBudget.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlFallbackQualityPolicy.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlFallbackRecoveryPolicy.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlFallbackStateEncoder.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlFallbackTrackCatalog.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlFrameScheduler.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlMediaClock.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlOpenedMedia.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlPreparedFallback.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlVideoToolboxDecoder.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlAudioRenderer.swift`
- Create: `packages/yl_player_macos/macos/Classes/YlFallbackBackend.swift`
- Modify: `packages/yl_player_macos/macos/Classes/YlMacosPlayer.swift`
- Create: `packages/yl_player/example/macos/RunnerTests/YlMacosFallbackTests.swift`
- Create: `packages/yl_player/example/integration_test/macos_mkv_playback_test.dart`
- Create: `packages/yl_player/example/integration_test/macos_network_mkv_playback_test.dart`
- Create: `packages/yl_player/example/integration_test/macos_http_flv_playback_test.dart`
- Create: `packages/yl_player/example/integration_test/macos_hls_headers_playback_test.dart`

**Interfaces:**
- Consumes: the macOS FFmpeg C ABI, bounded sources, source routes, `FlutterTextureRegistry`, and the backend slot in `YlMacosPlayer`.
- Produces: hardware-decoded MKV/HTTP-FLV video, AAC/MP3 native audio, fallback state/events/metrics, seeking, reconnect, audio-track selection, and quality constraints.

- [ ] **Step 1: Write failing pure fallback tests**

Cover exact queue byte/duration rejection, late-frame drops, seek generation gates, AAC/MP3 catalog selection, quality rejection, reconnect exhaustion, and state-delta generation. Example:

```swift
func testQualityConstraintRejectsOversizedVideoBeforeDecoderCreation() {
  let result = YlFallbackQualityPolicy.evaluate(
    width: 3840,
    height: 2160,
    bitrate: 12_000_000,
    constraint: .init(maxWidth: 1920, maxHeight: 1080, maxBitrate: 8_000_000)
  )
  XCTAssertEqual(result?.code, "decoder.quality_constraint_exceeded")
}
```

- [ ] **Step 2: Run unit tests and verify RED**

Run: `sh tool/check_native_macos.sh --unit-only`

Expected: fallback policies and backend types are absent.

- [ ] **Step 3: Implement tested fallback policies and media ownership**

Port the iOS algorithms into macOS-focused files. Keep every queue duration- and byte-bounded. `YlOpenedMedia` owns the FFmpeg context and packets; `YlPreparedFallback` transfers ownership exactly once; dispose and failed preparation release all outstanding packets.

Use `VTDecompressionSession` for H.264/HEVC and convert AAC/MP3 with `AVAudioConverter`. Schedule PCM through the macOS-supported Apple audio output path. Remove all `AVAudioSession` activation calls and UIKit notifications.

- [ ] **Step 4: Integrate fallback routing into `YlMacosPlayer`**

The player prepares off the main thread, commits atomically, keeps AVPlayer as the initial backend, permits one eligible fallback switch, restores the last quality constraint, ignores stale generations, and forwards texture frames from the active backend.

Unsupported VideoToolbox configurations must return:

```swift
NativePlayerError(
  category: "decoderUnsupported",
  code: "decoder.hardware_unsupported",
  message: "The selected stream cannot be decoded by VideoToolbox."
)
```

- [ ] **Step 5: Run unit and integration tests and verify GREEN**

Run: `sh tool/check_native_macos.sh --unit-only`

Expected: all fallback policy, ownership, decoder, audio, and backend tests pass.

Run: `flutter test packages/yl_player/example/integration_test/macos_mkv_playback_test.dart -d macos`

Run: `flutter test packages/yl_player/example/integration_test/macos_network_mkv_playback_test.dart -d macos`

Run: `flutter test packages/yl_player/example/integration_test/macos_http_flv_playback_test.dart -d macos`

Run: `flutter test packages/yl_player/example/integration_test/macos_hls_headers_playback_test.dart -d macos`

Expected: all four fallback scenarios reach ready/first-frame/progress and dispose cleanly; network scenarios also prove the requested seek/reconnect/header behavior.

- [ ] **Step 6: Commit**

```bash
git add packages/yl_player_macos/macos packages/yl_player/example/macos packages/yl_player/example/integration_test
git commit -m "feat(macos): add hardware fallback playback"
```

### Task 7: macOS example, universal application build, and CI

**Files:**
- Modify: `packages/yl_player/example/macos/**`
- Modify: `tool/check_native_macos.sh`
- Modify: `tool/check_foundation.sh`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: the complete `yl_player_macos` plugin and deterministic media fixtures.
- Produces: a runnable macOS example, a repeatable native/integration verification entrypoint, and hosted macOS CI coverage.

- [ ] **Step 1: Run the incomplete verification script and observe the missing universal build path**

Extend `tool/check_native_macos.sh` so it first builds/tests the plugin, then builds the example for macOS, and finally checks actual binary architectures with `lipo -archs`. Execute the new `--build-only` path before implementing its build logic.

Run: `sh tool/check_native_macos.sh --build-only`

Expected: exits nonzero because the script reports that its universal build
verification has not been implemented.

- [ ] **Step 2: Constrain the generated macOS runner**

Confirm the generated runner uses `MACOSX_DEPLOYMENT_TARGET = 12.0`, enable outgoing client network access, and retain only entitlements required by the playback fixtures. Do not add blanket ATS exceptions or unrelated permissions.

- [ ] **Step 3: Complete the verification script**

The default script performs:

```sh
flutter build macos --debug
xcodebuild test -workspace packages/yl_player/example/macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
flutter test packages/yl_player/example/integration_test/macos_hls_playback_test.dart -d macos
flutter test packages/yl_player/example/integration_test/macos_mkv_playback_test.dart -d macos
flutter test packages/yl_player/example/integration_test/macos_network_mkv_playback_test.dart -d macos
flutter test packages/yl_player/example/integration_test/macos_http_flv_playback_test.dart -d macos
flutter test packages/yl_player/example/integration_test/macos_hls_headers_playback_test.dart -d macos
```

The build-only mode builds `arm64` and `x86_64` configurations and verifies the plugin, FFmpeg framework, and final executable contain the requested architecture. If `/usr/bin/arch -x86_64 /usr/bin/true` succeeds, add a Rosetta smoke launch and report it separately.

- [ ] **Step 4: Add foundation and hosted CI coverage**

Add the macOS Dart package test and FFmpeg contract test to `tool/check_foundation.sh`. Add a `macos-native-integration` job on a macOS runner that runs `sh tool/check_native_macos.sh`, with a 60-minute timeout and read-only repository permission.

- [ ] **Step 5: Verify application and CI entrypoints GREEN**

Run: `sh tool/check_native_macos.sh`

Expected: native unit tests, universal build checks, five integration scenarios, and disposal checks pass.

Run: `sh tool/check_foundation.sh`

Expected: all Dart/platform tests, analysis, formatting, and both Apple FFmpeg contracts pass.

- [ ] **Step 6: Commit**

```bash
git add packages/yl_player/example/macos tool/check_native_macos.sh tool/check_foundation.sh .github/workflows/ci.yml
git commit -m "ci(macos): verify native playback paths"
```

### Task 8: Documentation and final repository acceptance

**Files:**
- Create: `packages/yl_player_macos/README.md`
- Create: `docs/verification/macos-device-matrix.md`
- Modify: `packages/yl_player/README.md`
- Modify: `packages/yl_player/CHANGELOG.md`
- Modify: `docs/verification/full-repository-optimization.md`

**Interfaces:**
- Consumes: verified implementation behavior and test output from Tasks 1–7.
- Produces: public capability documentation and an evidence-based acceptance record.

- [ ] **Step 1: Document only verified macOS guarantees**

Record macOS 12+, HLS/AVFoundation, MKV, HTTP-FLV, AAC/MP3 fallback audio, hardware-only VideoToolbox, headers, lifecycle, and exclusions. State exactly:

```text
Apple Silicon runtime: verified.
Intel build and link: verified.
Intel physical-device runtime: not verified; no Intel Mac was available.
```

Include reproducible FFmpeg build and LGPL notice instructions in the platform README.

- [ ] **Step 2: Run final verification-before-completion suite**

Run: `sh tool/check_foundation.sh`

Run: `sh tool/check_native_macos.sh`

Run: `sh tool/check_native_ios.sh`

Run from `packages/yl_player_android/example/android`: `./gradlew testDebugUnitTest --warning-mode all`

Run: `git diff --check`

Expected: every command exits 0. Record test counts, architecture output, Rosetta availability, warnings, and explicit skips in `docs/verification/full-repository-optimization.md`.

- [ ] **Step 3: Commit**

```bash
git add packages/yl_player_macos/README.md packages/yl_player/README.md packages/yl_player/CHANGELOG.md docs/verification
git commit -m "docs(macos): record support and verification"
```
