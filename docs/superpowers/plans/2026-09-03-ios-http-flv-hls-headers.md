# iOS HTTP-FLV and Authenticated HLS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add iOS HTTP-FLV live playback for H.264/H.265 with AAC/MP3 and make HLS custom headers apply safely to every HLS resource.

**Architecture:** Keep unheadered HLS on the existing direct AVPlayer path. Route header-bearing HLS through an AVAssetResourceLoader backed by URLSession and a manifest rewriter, while routing HTTP-FLV through the existing bounded FFmpeg-demux/VideoToolbox/native-audio fallback generalized for sequential live media and whole-pipeline reconnects.

**Tech Stack:** Flutter/Dart, Swift 5, AVFoundation, AVAssetResourceLoader, URLSession, VideoToolbox, AudioToolbox/AVFAudio, Objective-C, minimized FFmpeg 9.0.1, XCTest, Flutter integration_test.

**Spec:** `docs/superpowers/specs/2026-09-03-ios-http-flv-hls-headers-design.md`

## Global Constraints

- Minimum deployment target remains iOS 15.0.
- Do not change the public Dart API or method-channel schema.
- Video decode remains required-hardware VideoToolbox; do not enable FFmpeg video decoders.
- FFmpeg networking, TLS, audio decoders, GPL, and nonfree components remain disabled.
- HTTP-FLV supports H.264/H.265 video with AAC/MP3 audio, is live, and is never seekable.
- Sensitive HLS headers (`Authorization`, `Cookie`, `Proxy-Authorization`) are same-origin only; non-sensitive headers propagate to all rewritten HLS resources.
- Preserve existing Android behavior and all unheadered AVPlayer, local MKV, and network MKV behavior.
- Every production behavior must be introduced by a failing test, then the minimum passing implementation.

---

### Task 1: Extend the FFmpeg contract and bridge metadata for FLV/MP3

**Files:**
- Modify: `packages/yl_player_ios/tool/ios_ffmpeg/test_build_contract.sh`
- Modify: `packages/yl_player_ios/tool/ios_ffmpeg/build_xcframework.sh`
- Modify: `tool/ios_ffmpeg/generate_test_media.sh`
- Modify: `packages/yl_player_ios/ios/native/YlFFmpegBridge/include/YlFFmpegBridge.h`
- Modify: `packages/yl_player_ios/ios/native/YlFFmpegBridge/YlFFmpegBridge.m`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlFFmpegBridgeTests.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/Fixtures/h264_aac.flv`
- Create: `packages/yl_player/example/ios/RunnerTests/Fixtures/h264_mp3.flv`
- Create: `packages/yl_player/example/ios/RunnerTests/Fixtures/hevc_aac.flv`
- Modify: `packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: existing opaque `YLFMediaContextRef`, `YLFStreamInfo`, and callback AVIO API.
- Produces: `YLFCodecMP3 = 4`; an XCFramework containing `flv` demux and `mpegaudio` parser support; deterministic FLV fixtures.

- [ ] **Step 1: Add failing build-contract assertions**

```sh
require_line "--enable-demuxer=matroska,flv"
require_line "--enable-parser=aac,h264,hevc,mpegaudio"
reject_text "--enable-decoder=mp3"
reject_text "--enable-protocol=http"
reject_text "--enable-protocol=https"
```

- [ ] **Step 2: Run the contract and verify RED**

Run: `sh packages/yl_player_ios/tool/ios_ffmpeg/test_build_contract.sh`

Expected: FAIL because the current contract contains only the Matroska demuxer and lacks `mpegaudio`.

- [ ] **Step 3: Extend deterministic fixture generation and bridge tests**

Add two-second H.264/AAC and H.264/MP3 FLV commands. Generate HEVC/AAC as
Enhanced FLV by selecting `libx265` and `-f flv` without overriding the codec
tag; fixture generation must fail if any command fails. Generalize the test
fixture helper to accept an extension and assert:

```swift
XCTAssertEqual(video.codec, Int32(YLFCodecH264))
XCTAssertEqual(mp3.codec, Int32(YLFCodecMP3))
XCTAssertTrue(ylf_packet_is_keyframe(firstVideoKeyframe))
```

Container-level seeking is not asserted for a local FLV fixture because the
public non-seekable guarantee belongs to the sequential HTTP live source. The
HEVC fixture test accepts bridge metadata and format-description creation;
hardware decode is tested later.

- [ ] **Step 4: Run the bridge test and verify RED**

Run: `xcodebuild test -workspace packages/yl_player/example/ios/Runner.xcworkspace -scheme Runner -destination "platform=iOS Simulator,id=$YL_IOS_SIMULATOR_ID" -only-testing:RunnerTests/YlFFmpegBridgeTests`

Expected: FAIL because FLV is not bundled in the bridge and MP3 maps to unsupported.

- [ ] **Step 5: Implement the minimum bridge/build changes**

Change the configure allowlist to:

```bash
--enable-demuxer=matroska,flv
--enable-parser=aac,h264,hevc,mpegaudio
```

Add the public codec value and mapping:

```objc
typedef enum YLFCodec {
  YLFCodecUnknown = 0,
  YLFCodecH264 = 1,
  YLFCodecHEVC = 2,
  YLFCodecAAC = 3,
  YLFCodecMP3 = 4,
} YLFCodec;

case AV_CODEC_ID_MP3:
  return YLFCodecMP3;
```

Rebuild the checked-in XCFramework with the pinned archive/signature workflow and add the fixtures to the RunnerTests resources build phase.

- [ ] **Step 6: Verify GREEN**

Run:

```sh
sh packages/yl_player_ios/tool/ios_ffmpeg/test_build_contract.sh
xcodebuild test -workspace packages/yl_player/example/ios/Runner.xcworkspace -scheme Runner -destination "platform=iOS Simulator,id=$YL_IOS_SIMULATOR_ID" -only-testing:RunnerTests/YlFFmpegBridgeTests
```

Expected: both commands exit 0 and `ylf_debug_outstanding_packet_count()` returns zero after each fixture.

- [ ] **Step 7: Commit**

```sh
git add packages/yl_player_ios/tool/ios_ffmpeg packages/yl_player_ios/ios/native/YlFFmpegBridge packages/yl_player_ios/ios/yl_player_ios/Frameworks/YlFFmpegBridge.xcframework tool/ios_ffmpeg/generate_test_media.sh packages/yl_player/example/ios/RunnerTests/Fixtures packages/yl_player/example/ios/RunnerTests/YlFFmpegBridgeTests.swift packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat(ios): add FLV demux and MP3 metadata"
```

### Task 2: Add deterministic iOS routing and container-aware fallback models

**Files:**
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackModels.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlSourceRouter.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlOpenedMedia.swift`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlSourceRouterTests.swift`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlOpenedMediaTests.swift`

**Interfaces:**
- Consumes: `YlIosSourceDescriptor` and the callback byte-source bridge.
- Produces: `YlIosSourceRoute.networkFlv`, `YlIosSourceRoute.headeredHls`, `YlFallbackContainer`, and format-specific open errors.

- [ ] **Step 1: Write failing route tests**

```swift
XCTAssertEqual(YlSourceRouter.route(.init(
  uri: "https://media.test/live.flv?token=1", kind: "network",
  formatHint: "automatic", isLive: true, hasHeaders: true
)), .networkFlv)

XCTAssertEqual(YlSourceRouter.route(.init(
  uri: "https://media.test/master.m3u8", kind: "network",
  formatHint: "hls", isLive: true, hasHeaders: true
)), .headeredHls)
```

Also assert that headers on progressive MP4 remain rejected and network MKV live remains rejected.

- [ ] **Step 2: Run route tests and verify RED**

Run: `xcodebuild test -workspace packages/yl_player/example/ios/Runner.xcworkspace -scheme Runner -destination "platform=iOS Simulator,id=$YL_IOS_SIMULATOR_ID" -only-testing:RunnerTests/YlSourceRouterTests`

Expected: compile failure because the new enum cases do not exist.

- [ ] **Step 3: Add container-aware models and routes**

```swift
enum YlFallbackContainer: Equatable {
  case matroska
  case flv
}

enum YlIosSourceRoute: Equatable {
  case avPlayer
  case headeredHls
  case localMatroska
  case networkMatroska
  case networkFlv
  case reject(category: String, code: String, message: String)
}
```

Store the container on the source recipe with these exact cases:

```swift
enum YlFallbackSourceRecipe {
  case local(path: String, container: YlFallbackContainer)
  case network(request: YlNetworkRequestRecipe, container: YlFallbackContainer)

  var container: YlFallbackContainer { get }
}
```

Make `YlOpenedMedia.openError` accept that container and choose
`container.flv_open_failed`/`container.flv_malformed` for FLV while retaining
every MKV code.

- [ ] **Step 4: Verify GREEN and regression safety**

Run:

```sh
xcodebuild test -workspace packages/yl_player/example/ios/Runner.xcworkspace -scheme Runner -destination "platform=iOS Simulator,id=$YL_IOS_SIMULATOR_ID" -only-testing:RunnerTests/YlSourceRouterTests
xcodebuild test -workspace packages/yl_player/example/ios/Runner.xcworkspace -scheme Runner -destination "platform=iOS Simulator,id=$YL_IOS_SIMULATOR_ID" -only-testing:RunnerTests/YlOpenedMediaTests
```

Expected: both suites pass.

- [ ] **Step 5: Commit**

```sh
git add packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackModels.swift packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlSourceRouter.swift packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlOpenedMedia.swift packages/yl_player/example/ios/RunnerTests/YlSourceRouterTests.swift packages/yl_player/example/ios/RunnerTests/YlOpenedMediaTests.swift
git commit -m "feat(ios): route HTTP-FLV and authenticated HLS"
```

### Task 3: Add a sequential-live URLSession byte source

**Files:**
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlNetworkRequestPolicy.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlNetworkByteSource.swift`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlNetworkRequestPolicyTests.swift`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlNetworkByteSourceTests.swift`

**Interfaces:**
- Consumes: `YlNetworkRequestRecipe` and `YlByteSource`.
- Produces: `YlNetworkInputMode.randomAccessVOD` and `.sequentialLive`; live requests without Range and terminal failures handed to the backend for whole-stream reconstruction.

- [ ] **Step 1: Write failing live-mode tests**

Add an explicit mode:

```swift
enum YlNetworkInputMode: Equatable {
  case randomAccessVOD
  case sequentialLive
}
```

Tests must assert that `.sequentialLive`:

```swift
XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
XCTAssertFalse(source.supportsRandomAccess)
XCTAssertThrowsError(try source.seek(to: 1))
```

Also prove that a chunked 200 response without Content-Length remains readable until task completion and that a partial live transport failure is surfaced immediately without an in-context Range retry.

- [ ] **Step 2: Run focused network tests and verify RED**

Run: `xcodebuild test -workspace packages/yl_player/example/ios/Runner.xcworkspace -scheme Runner -destination "platform=iOS Simulator,id=$YL_IOS_SIMULATOR_ID" -only-testing:RunnerTests/YlNetworkRequestPolicyTests -only-testing:RunnerTests/YlNetworkByteSourceTests`

Expected: compile failure because `YlNetworkInputMode` and the mode parameter do not exist.

- [ ] **Step 3: Implement mode-specific request and retry behavior**

Extend the recipe:

```swift
struct YlNetworkRequestRecipe {
  let url: URL
  let headers: [String: String]
  let configuration: YlNetworkConfiguration
  let mode: YlNetworkInputMode

  init(url: URL, headers: [String: String],
       configuration: YlNetworkConfiguration,
       mode: YlNetworkInputMode = .randomAccessVOD)
}
```

For `.randomAccessVOD`, preserve exact current behavior. For `.sequentialLive`, issue a plain GET, report no length unless supplied by the response, reject all nonzero seeks with `network.range_not_supported`, never resume a partially consumed connection in the same ring, and preserve timeout/cancellation error typing.

- [ ] **Step 4: Verify GREEN**

Run the focused command from Step 2.

Expected: all network policy and byte-source tests pass with no regressions in Range VOD.

- [ ] **Step 5: Commit**

```sh
git add packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlNetworkRequestPolicy.swift packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlNetworkByteSource.swift packages/yl_player/example/ios/RunnerTests/YlNetworkRequestPolicyTests.swift packages/yl_player/example/ios/RunnerTests/YlNetworkByteSourceTests.swift
git commit -m "feat(ios): add sequential live network input"
```

### Task 4: Generalize native audio conversion for AAC and MP3

**Files:**
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlAudioRenderer.swift`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlAudioRendererTests.swift`

**Interfaces:**
- Consumes: `YlAudioStreamConfiguration` and `YlCompressedAudioPacket`.
- Produces: `YlAudioCodec.mp3` and `YlAppleCompressedAudioConverter` for AAC/MP3.

- [ ] **Step 1: Write failing MP3 conversion tests**

Rename the fixture-facing converter in tests to the wished-for API and add:

```swift
let stream = YlAudioStreamConfiguration(
  codec: .mp3,
  sampleRate: 48_000,
  channelCount: 1,
  magicCookie: Data(),
  generation: 1
)
let converter = YlAppleCompressedAudioConverter()
try converter.configure(stream: stream)
let converted = try converter.convert(packet: fixtureMP3Packet)
XCTAssertGreaterThan((converted.payload as! AVAudioPCMBuffer).frameLength, 0)
```

Add separate assertions that malformed AAC maps to `decoder.audio_aac_unsupported`, malformed MP3 maps to `decoder.audio_mp3_unsupported`, and conversion failure remains `decoder.audio_failed` with codec-specific text.

- [ ] **Step 2: Run audio tests and verify RED**

Run: `xcodebuild test -workspace packages/yl_player/example/ios/Runner.xcworkspace -scheme Runner -destination "platform=iOS Simulator,id=$YL_IOS_SIMULATOR_ID" -only-testing:RunnerTests/YlAudioRendererTests`

Expected: compile failure because `.mp3` and `YlAppleCompressedAudioConverter` do not exist.

- [ ] **Step 3: Implement codec-aware Apple conversion**

```swift
enum YlAudioCodec: Equatable {
  case aac
  case mp3
  case unsupported
}

let formatID: AudioFormatID = stream.codec == .aac
  ? kAudioFormatMPEG4AAC
  : kAudioFormatMPEGLayer3
let framesPerPacket: UInt32 = stream.codec == .aac ? 1024 : 1152
```

Require and set a magic cookie only for AAC. Retain the existing compressed-buffer ownership, output format, byte/duration ceilings, generation checks, and audio clock behavior.

- [ ] **Step 4: Verify GREEN**

Run the focused command from Step 2.

Expected: AAC and MP3 fixture packets both produce non-empty Float32 PCM, and all existing renderer tests pass.

- [ ] **Step 5: Commit**

```sh
git add packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlAudioRenderer.swift packages/yl_player/example/ios/RunnerTests/YlAudioRendererTests.swift
git commit -m "feat(ios): decode FLV MP3 with AudioToolbox"
```

### Task 5: Generalize fallback preparation and playback for HTTP-FLV

**Files:**
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackBackend.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlIosPlayer.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlAvPlayerBackend.swift`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlFallbackBackendTests.swift`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlFallbackLifecycleTests.swift`

**Interfaces:**
- Consumes: `.networkFlv`, sequential-live byte source, MP3 codec metadata, and existing fallback queues/decoder/clock.
- Produces: prepared and active FLV fallback with `isLive=true`, `isSeekable=false`, keyframe-gated startup, and `supportedFormats` containing `httpFlv`/`flv`.

- [ ] **Step 1: Write failing preparation/state tests**

Use the FLV fixtures through an injected byte source/session and assert:

```swift
XCTAssertEqual(prepared.container, .flv)
XCTAssertFalse(prepared.isSeekable)
XCTAssertEqual(prepared.audioStreams.first?.codec, Int32(YLFCodecMP3))
XCTAssertEqual(backend.stateEnvelope["isLive"] as? Bool, true)
XCTAssertEqual(backend.stateEnvelope["durationMs"] as? Int64, nil)
```

Add a policy-level keyframe gate test proving non-key video is dropped until the first keyframe and reset re-arms the gate.

- [ ] **Step 2: Run fallback tests and verify RED**

Run: `xcodebuild test -workspace packages/yl_player/example/ios/Runner.xcworkspace -scheme Runner -destination "platform=iOS Simulator,id=$YL_IOS_SIMULATOR_ID" -only-testing:RunnerTests/YlFallbackBackendTests -only-testing:RunnerTests/YlFallbackLifecycleTests`

Expected: failure because fallback preparation assumes Matroska/AAC and reports VOD state.

- [ ] **Step 3: Implement container-aware preparation**

Introduce a small policy object rather than scattering conditionals:

```swift
struct YlFallbackMediaPolicy: Equatable {
  let container: YlFallbackContainer
  let isLive: Bool
  let isSeekable: Bool
  let requiresInitialVideoKeyframe: Bool
}
```

Create `.network(request:, container:)` recipes, select AAC or MP3 audio, copy a cookie only for AAC, construct `YlAudioStreamConfiguration` from bridge metadata, and retain all Matroska behavior unchanged.

- [ ] **Step 4: Wire `.networkFlv` through asynchronous open**

In `YlIosPlayer.beginOpen`, route `.networkFlv` through `prepareFallback`. Keep candidate preparation off the main thread and commit through `YlBackendSlot.replace`. Update AVPlayer validation exhaustiveness without allowing FLV onto AVPlayer.

- [ ] **Step 5: Implement live state and keyframe gating**

Add a focused gate:

```swift
struct YlInitialKeyframeGate {
  private(set) var isOpen = false
  mutating func accepts(isVideo: Bool, isKeyframe: Bool) -> Bool {
    if isOpen || !isVideo { return isOpen }
    if isKeyframe { isOpen = true }
    return isOpen
  }
  mutating func reset() { isOpen = false }
}
```

Do not expose seek for FLV. Emit live state, no finite duration, and `engine: nativeFallback`. Add `httpFlv` and `flv` to iOS capabilities.

- [ ] **Step 6: Verify GREEN**

Run the focused command from Step 2 plus `flutter test packages/yl_player_ios/test`.

Expected: all pass, including existing local/network MKV preparation.

- [ ] **Step 7: Commit**

```sh
git add packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackBackend.swift packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlIosPlayer.swift packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlAvPlayerBackend.swift packages/yl_player/example/ios/RunnerTests/YlFallbackBackendTests.swift packages/yl_player/example/ios/RunnerTests/YlFallbackLifecycleTests.swift packages/yl_player_ios/test
git commit -m "feat(ios): play HTTP-FLV through native fallback"
```

### Task 6: Add bounded whole-pipeline live reconnection

**Files:**
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlLiveReconnectController.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackBackend.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlLiveReconnectControllerTests.swift`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlFallbackLifecycleTests.swift`
- Modify: `packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `YlNetworkConfiguration`, source recipe, generation, fallback teardown/rebuild hooks.
- Produces: bounded retry decisions and reconnect events that rebuild the FLV demux/decode/audio pipeline from byte zero.

- [ ] **Step 1: Write failing retry-controller tests**

```swift
let controller = YlLiveReconnectController(configuration: .init(map: [
  "maxRetries": 2,
  "baseRetryDelayMs": 10,
  "maxRetryDelayMs": 15,
]))
XCTAssertEqual(controller.nextDelayMs(), 10)
XCTAssertEqual(controller.nextDelayMs(), 15)
XCTAssertNil(controller.nextDelayMs())
controller.markFirstFrame()
XCTAssertEqual(controller.attempt, 0)
```

Add lifecycle tests proving stale reconnect callbacks cannot replace a newer source and dispose cancels pending retry work.

- [ ] **Step 2: Run tests and verify RED**

Run: `xcodebuild test -workspace packages/yl_player/example/ios/Runner.xcworkspace -scheme Runner -destination "platform=iOS Simulator,id=$YL_IOS_SIMULATOR_ID" -only-testing:RunnerTests/YlLiveReconnectControllerTests -only-testing:RunnerTests/YlFallbackLifecycleTests`

Expected: compile failure because the controller does not exist.

- [ ] **Step 3: Implement retry decisions and fallback hooks**

```swift
final class YlLiveReconnectController {
  private(set) var attempt = 0
  func nextDelayMs() -> Int64?
  func markFirstFrame()
  func cancel()
}
```

The backend transport-failure path must enter buffering, increment generation, cancel/join input, clear packet/frame/PCM queues and clocks, schedule one reconnect, prepare a new context from byte zero, rebuild codec objects if configuration changed, re-arm the initial-keyframe gate, and resume only if the generation is still current. Emit `YlFallbackRetryEvent` for each attempt and `network.retry_exhausted` after the configured count.

- [ ] **Step 4: Verify GREEN**

Run the focused command from Step 2.

Expected: retry delays, reset-after-first-frame, stale suppression, cancellation, and terminal exhaustion all pass.

- [ ] **Step 5: Commit**

```sh
git add packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlLiveReconnectController.swift packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackBackend.swift packages/yl_player/example/ios/RunnerTests/YlLiveReconnectControllerTests.swift packages/yl_player/example/ios/RunnerTests/YlFallbackLifecycleTests.swift packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat(ios): reconnect HTTP-FLV live streams"
```

### Task 7: Implement HLS URL rewriting and header security policy

**Files:**
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlHlsURLCodec.swift`
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlHlsManifestRewriter.swift`
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlHlsHeaderPolicy.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlHlsManifestRewriterTests.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlHlsHeaderPolicyTests.swift`
- Modify: `packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `YlHlsURLCodec.encode(_:)`, `decode(_:)`; `YlHlsManifestRewriter.rewrite(data:baseURL:)`; `YlHlsHeaderPolicy.headers(for:)`.

- [ ] **Step 1: Write failing URL/manifest tests**

Use a manifest containing a relative variant, absolute segment, query-only URL, `EXT-X-KEY`, `EXT-X-MAP`, `EXT-X-MEDIA`, `EXT-X-I-FRAME-STREAM-INF`, `EXT-X-SESSION-KEY`, `EXT-X-PART`, `EXT-X-PRELOAD-HINT`, and `EXT-X-RENDITION-REPORT`. Assert every HTTP/HTTPS URI round-trips through the internal scheme and resolves against the manifest URL. Assert CRLF input stays CRLF and malformed UTF-8 returns `container.hls_manifest_invalid`.

- [ ] **Step 2: Write failing header-policy tests**

```swift
let policy = YlHlsHeaderPolicy(
  originURL: URL(string: "https://media.test:443/master.m3u8")!,
  headers: ["Authorization": "Bearer secret", "X-Client": "tv"]
)
XCTAssertEqual(policy.headers(for: URL(string: "https://MEDIA.test/seg.ts")!)["Authorization"], "Bearer secret")
XCTAssertNil(policy.headers(for: URL(string: "https://cdn.test/seg.ts")!)["Authorization"])
XCTAssertEqual(policy.headers(for: URL(string: "https://cdn.test/seg.ts")!)["X-Client"], "tv")
```

- [ ] **Step 3: Run the two suites and verify RED**

Run: `xcodebuild test -workspace packages/yl_player/example/ios/Runner.xcworkspace -scheme Runner -destination "platform=iOS Simulator,id=$YL_IOS_SIMULATOR_ID" -only-testing:RunnerTests/YlHlsManifestRewriterTests -only-testing:RunnerTests/YlHlsHeaderPolicyTests`

Expected: compile failure because the three production types do not exist.

- [ ] **Step 4: Implement pure URL, rewrite, and header policies**

Use a reversible URL-safe base64 payload in a fixed scheme such as `ylhls`. Rewrite non-comment URI lines and quoted `URI=` attributes only; reject decoded destinations whose scheme is not HTTP/HTTPS. Same-origin comparison must normalize scheme/host case and default ports. Match sensitive names case-insensitively.

```swift
static let sensitive = Set([
  "authorization", "cookie", "proxy-authorization",
])
```

- [ ] **Step 5: Verify GREEN**

Run the focused command from Step 3.

Expected: both suites pass without network access.

- [ ] **Step 6: Commit**

```sh
git add packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlHlsURLCodec.swift packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlHlsManifestRewriter.swift packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlHlsHeaderPolicy.swift packages/yl_player/example/ios/RunnerTests/YlHlsManifestRewriterTests.swift packages/yl_player/example/ios/RunnerTests/YlHlsHeaderPolicyTests.swift packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat(ios): rewrite authenticated HLS resources safely"
```

### Task 8: Add the AVAssetResourceLoader-backed HLS path

**Files:**
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlHlsResourceLoader.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlOpenCoordinator.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlAvPlayerBackend.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlIosPlayer.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlHlsResourceLoaderTests.swift`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlOpenCoordinatorTests.swift`
- Modify: `packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: HLS URL codec, manifest rewriter, header policy, network configuration, and `.headeredHls` route.
- Produces: `YlHlsResourceLoader`, `YlPreparedHlsAsset`, cancellation, redirect filtering, byte-range responses, and AVPlayer ownership.

- [ ] **Step 1: Write failing loader request tests**

Use a scripted `URLProtocol` and an adapter around resource-loading requests to verify:

- top-level and child requests contain expected headers;
- playlist responses are rewritten before bytes are supplied;
- media/key bytes are unchanged;
- requested offset/length creates a package-owned `Range` header;
- 200/206 metadata fills content type, content length, and byte-range support;
- 4xx, malformed manifests, timeout, redirect limit, and cancellation finish once with stable errors;
- cross-origin redirects strip sensitive headers;
- dispose cancels every task and ignores late callbacks.

- [ ] **Step 2: Run loader tests and verify RED**

Run: `xcodebuild test -workspace packages/yl_player/example/ios/Runner.xcworkspace -scheme Runner -destination "platform=iOS Simulator,id=$YL_IOS_SIMULATOR_ID" -only-testing:RunnerTests/YlHlsResourceLoaderTests -only-testing:RunnerTests/YlOpenCoordinatorTests`

Expected: compile failure because the loader and prepared asset do not exist.

- [ ] **Step 3: Implement a testable loader core**

```swift
final class YlHlsResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
  init(originURL: URL, headers: [String: String],
       configuration: YlNetworkConfiguration,
       sessionConfiguration: URLSessionConfiguration = .ephemeral)
  func encodedAssetURL() throws -> URL
  func cancelAll()
}

struct YlPreparedHlsAsset {
  let asset: AVURLAsset
  let loader: YlHlsResourceLoader
}
```

Keep one task record per loading request, stream non-manifest bytes, buffer
manifests only up to an explicit 2 MiB ceiling before rewrite, sanitize URL
diagnostics, and finish each request exactly once. Before candidate commit,
preflight the top-level manifest on the open coordinator's background queue,
rewrite it, and retain it as the loader's first cached response; a failed
preflight therefore cannot replace the active backend. Do not use
`AVURLAssetHTTPHeaderFieldsKey`.

- [ ] **Step 4: Integrate loader ownership with AVPlayer**

Add `YlPreparedOpen.headeredHls(source:prepared:)`. For `.headeredHls`,
construct an `AVURLAsset` from `encodedAssetURL()`, set the loader delegate
before creating `AVPlayerItem`, and retain the loader until item
replacement/dispose. Commit the prepared asset through the existing open
coordinator only after top-level preflight succeeds. For `.avPlayer`, keep
`AVURLAsset(url:)` unchanged.

- [ ] **Step 5: Verify GREEN**

Run the focused command from Step 2 and the existing `YlSourceRouterTests`.

Expected: all pass and the direct unheadered HLS path creates no resource loader.

- [ ] **Step 6: Commit**

```sh
git add packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlHlsResourceLoader.swift packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlOpenCoordinator.swift packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlAvPlayerBackend.swift packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlIosPlayer.swift packages/yl_player/example/ios/RunnerTests/YlHlsResourceLoaderTests.swift packages/yl_player/example/ios/RunnerTests/YlOpenCoordinatorTests.swift packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat(ios): load HLS with custom headers"
```

### Task 9: Add end-to-end gates, capability assertions, and documentation

**Files:**
- Create: `packages/yl_player/example/integration_test/ios_http_flv_playback_test.dart`
- Create: `packages/yl_player/example/integration_test/ios_hls_headers_playback_test.dart`
- Create: `packages/yl_player/example/integration_test/support/live_flv_server.dart`
- Create: `packages/yl_player/example/integration_test/support/authenticated_hls_server.dart`
- Modify: `packages/yl_player/example/pubspec.yaml`
- Modify: `packages/yl_player_ios/test/yl_player_ios_test.dart`
- Modify: `packages/yl_player_ios/README.md`
- Modify: `packages/yl_player/README.md`
- Modify: `packages/yl_player_ios/CHANGELOG.md`
- Modify: `packages/yl_player/CHANGELOG.md`
- Modify: `packages/yl_player_ios/THIRD_PARTY_NOTICES.md`
- Modify: `tool/check_native_ios.sh`

**Interfaces:**
- Consumes: completed FLV and authenticated-HLS implementations.
- Produces: deterministic integration servers/tests, final support documentation, and one complete iOS verification entrypoint.

- [ ] **Step 1: Write failing Dart capability and integration tests**

Assert iOS capabilities include both hints:

```dart
expect(capabilities.supportedFormats, contains(YlFormatHint.httpFlv));
expect(capabilities.supportedFormats, contains(YlFormatHint.flv));
```

The FLV server must stream fixture bytes in small chunks, optionally close once after a complete FLV header, and record connection count. The test requires first frame, `nativeFallback`, `isLive == true`, `isSeekable == false`, a retry event after forced disconnect, and playback after reconnect.

The HLS server must expose a master, child playlist, fMP4 or TS media, initialization section where applicable, and AES key endpoint. Record headers for every path and serve one child resource from a second loopback origin. Require a first frame and assert sensitive headers are present only on same-origin requests while `X-Client` reaches both origins.

- [ ] **Step 2: Run the new integration tests and verify RED**

Run:

```sh
cd packages/yl_player/example
flutter test integration_test/ios_http_flv_playback_test.dart -d "$YL_IOS_SIMULATOR_ID"
flutter test integration_test/ios_hls_headers_playback_test.dart -d "$YL_IOS_SIMULATOR_ID"
```

Expected: failure before first frame or capability mismatch until all native paths are wired.

- [ ] **Step 3: Complete capability mapping and documentation**

Update both READMEs and changelogs with the exact H.264/H.265 + AAC/MP3 boundary, required hardware decode, non-seekable live semantics, bounded reconnects, HLS header origin policy, ATS behavior, and the physical-device acceptance caveat. Update third-party notices with the changed FFmpeg configure allowlist.

- [ ] **Step 4: Extend the native gate**

Append both integration files to `tool/check_native_ios.sh` after the existing HLS/MKV suites. Keep the simulator boot recovery logic intact.

- [ ] **Step 5: Run focused integrations and verify GREEN**

Run the two commands from Step 2.

Expected: both exit 0; the FLV test receives a post-reconnect first frame and the HLS server records the approved header matrix.

- [ ] **Step 6: Run the complete automated gate**

Run:

```sh
sh packages/yl_player_ios/tool/ios_ffmpeg/test_build_contract.sh
flutter test
flutter analyze
sh tool/check_native_ios.sh
```

Expected: all commands exit 0 with zero test failures and zero analyzer issues.

- [ ] **Step 7: Record physical-device acceptance boundary**

Create or extend the iOS verification matrix to record device model, iOS version, H.264/AAC, H.264/MP3, H.265/AAC, forced reconnect, memory warning, and 30-minute results. Do not describe HTTP-FLV as stable until those rows pass on target hardware.

- [ ] **Step 8: Commit**

```sh
git add packages/yl_player/example/integration_test packages/yl_player/example/pubspec.yaml packages/yl_player_ios/test/yl_player_ios_test.dart packages/yl_player_ios/README.md packages/yl_player/README.md packages/yl_player_ios/CHANGELOG.md packages/yl_player/CHANGELOG.md packages/yl_player_ios/THIRD_PARTY_NOTICES.md tool/check_native_ios.sh docs/verification
git commit -m "test(ios): verify HTTP-FLV and authenticated HLS"
```
