# iOS Local MKV Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Play local H.264/H.265 + AAC Matroska files on iOS 15+ through a
bounded FFmpeg-demux, VideoToolbox-hardware-decode, native-audio fallback while
leaving the public Dart API unchanged.

**Architecture:** `YlIosPlayer` validates and routes a source to either the
existing AVPlayer backend or a new fallback backend. A minimized, reproducibly
built dynamic `YlFFmpegBridge.xcframework` owns Matroska demux and opaque packet
lifetimes; Swift owns bounded queues, VideoToolbox, AVAudioEngine, clocking,
Flutter Texture, state, and lifecycle. Every async operation carries a source
generation and only one backend may hold decode/audio resources.

**Tech Stack:** Flutter 3.44+/Dart 3.12+, Swift 5.9, Objective-C/C, FFmpeg 9.0.1
(`libavformat`, packet/parser support only), CoreMedia, VideoToolbox,
AudioToolbox, AVFAudio, XCTest, CocoaPods, Swift Package Manager.

**Spec:** `docs/superpowers/specs/2026-09-03-ios-native-fallback-design.md`

## Global Constraints

- Minimum iOS version is 15.0; Android minimum remains API 24.
- The first slice accepts local `.mkv`/`YlFormatHint.matroska` only.
- Supported video is H.264 or H.265 through required-hardware VideoToolbox.
- Supported audio is AAC-LC through Apple audio conversion; no FFmpeg software
  video decoder, subtitles, DRM, network fallback, or non-AAC audio.
- Dart messages contain commands/state/events only—never packets, PCM, or
  pixel buffers.
- Queue duration and byte ceilings are hard limits; decoded video holds at most
  three frames.
- Rejected `open` must leave the currently playing source intact.
- No README claim of iOS MKV support until physical-device acceptance passes.
- Work remains on the user-selected `main` branch; commit after each green task
  and do not push or publish without a separate request.

---

### Task 1: Native XCTest harness and deterministic source router

**Files:**
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackModels.swift`
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlSourceRouter.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlSourceRouterTests.swift`
- Modify: `packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Package.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlPlayerIosPlugin.swift`

**Interfaces:**
- Produces:
  `YlIosSourceDescriptor(uri:kind:formatHint:isLive:hasHeaders:)` and
  `YlSourceRouter.route(_:) -> YlIosSourceRoute`.
- `YlIosSourceRoute` cases are `.avPlayer`, `.localMatroska`, and
  `.reject(category:code:message:)`.
- `YlIosSourceRoute.rejectionCode: String?` returns the code for `.reject` and
  nil for playable routes.
- Later tasks consume `.localMatroska`; Task 1 still returns the existing
  `container.native_fallback_required` result for that route at the command
  boundary.

- [x] **Step 1: Add the failing router tests**

```swift
@testable import yl_player_ios
import XCTest

final class YlSourceRouterTests: XCTestCase {
  func testLocalMkvRoutesToFallback() {
    let source = YlIosSourceDescriptor(
      uri: "file:///tmp/movie.mkv", kind: "file", formatHint: "automatic",
      isLive: false, hasHeaders: false
    )
    XCTAssertEqual(YlSourceRouter.route(source), .localMatroska)
  }

  func testRemoteMkvStaysRejected() {
    let source = YlIosSourceDescriptor(
      uri: "https://media.test/movie.mkv", kind: "network",
      formatHint: "matroska", isLive: false, hasHeaders: false
    )
    XCTAssertEqual(
      YlSourceRouter.route(source).rejectionCode,
      "container.native_fallback_required"
    )
  }

  func testHlsRemainsOnAvPlayer() {
    let source = YlIosSourceDescriptor(
      uri: "https://media.test/live.m3u8", kind: "network",
      formatHint: "hls", isLive: true, hasHeaders: false
    )
    XCTAssertEqual(YlSourceRouter.route(source), .avPlayer)
  }
}
```

- [x] **Step 2: Add the test file to RunnerTests and verify RED**

Add the Swift file to the existing `RunnerTests` target's Sources build phase
and keep the plugin Swift package compatible with Flutter's generated iOS 13
aggregator while the application and podspec enforce the real iOS 15 runtime
floor. Then run:

```bash
xcodebuild test \
  -workspace packages/yl_player/example/ios/Runner.xcworkspace \
  -scheme Runner \
  -destination 'platform=iOS Simulator,id=431A3ACD-A229-4F82-AC46-9B9481AC0ADE'
```

Expected: compile failure because the descriptor/router types do not exist.

- [x] **Step 3: Implement the value-only router**

Implement the exact extension precedence: explicit `matroska` + local kind, or
automatic + local `.mkv`, yields `.localMatroska`; known fallback formats over
network yield the fallback-required error; custom headers yield
`container.headers_require_fallback`; HLS/MP4/MOV yield `.avPlayer`; malformed
URI yields `source.invalid_uri`.

- [x] **Step 4: Replace duplicated format checks in `validateOpen`**

Build `YlIosSourceDescriptor` from the channel map, call the router before any
deactivation, and translate `.localMatroska` to the existing fallback-required
error until Task 7 supplies the backend.

- [x] **Step 5: Run the router tests and existing HLS integration**

Run the XCTest command above, then run this command from
`packages/yl_player/example` so Flutter selects the example app's plugin
registrant:

```bash
flutter test integration_test/hls_playback_test.dart \
  -d 431A3ACD-A229-4F82-AC46-9B9481AC0ADE
```

Expected: router tests pass and Flutter reports `+2: All tests passed!`.

- [x] **Step 6: Commit**

```bash
git add packages/yl_player_ios/ios/yl_player_ios packages/yl_player/example/ios
git commit -m "refactor: add deterministic iOS source routing"
```

### Task 2: Reproducible minimized FFmpeg bridge artifact

**Files:**
- Create: `tool/ios_ffmpeg/ffmpeg-9.0.1.lock`
- Create: `tool/ios_ffmpeg/test_build_contract.sh`
- Create: `tool/ios_ffmpeg/build_xcframework.sh`
- Create: `tool/ios_ffmpeg/FFMPEG_RELEASE_KEY.asc`
- Create: `packages/yl_player_ios/ios/native/YlFFmpegBridge/include/YlFFmpegBridge.h`
- Create: `packages/yl_player_ios/ios/native/YlFFmpegBridge/YlFFmpegBridge.m`
- Create: `packages/yl_player_ios/ios/native/YlFFmpegBridge/module.modulemap`
- Create: `packages/yl_player_ios/ios/yl_player_ios/Frameworks/YlFFmpegBridge.xcframework/**`
- Create: `packages/yl_player_ios/THIRD_PARTY_NOTICES.md`
- Create: `packages/yl_player_ios/LICENSES/FFmpeg-LGPL-2.1-or-later.txt`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Package.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios.podspec`
- Modify: `packages/yl_player_ios/.gitignore`

**Interfaces:**
- Produces one importable module, `YlFFmpegBridge`, for arm64 device and
  arm64/x86_64 Simulator.
- The bridge exports `ylf_build_configuration()` so tests can prove the shipped
  artifact and lock manifest agree.

- [x] **Step 1: Write the failing build-contract test**

The shell test sources this exact lock data and rejects forbidden flags:

```text
FFMPEG_VERSION=9.0.1
FFMPEG_URL=https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz
FFMPEG_SHA256=cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635
IOS_DEPLOYMENT_TARGET=15.0
```

It asserts the official release-tarball signing-key fingerprint is
`FCF986EA15E6E293A5644F10B4322F04D67658D8`, and that the build script contains `--disable-network`,
`--disable-programs`, `--disable-avdevice`, `--disable-avfilter`,
`--disable-swscale`, `--disable-swresample`,
`--enable-demuxer=matroska`, and `--enable-protocol=file`; and fails if it finds
`--enable-gpl`, `--enable-nonfree`, `--enable-decoder=h264`, or
`--enable-decoder=hevc`.

- [x] **Step 2: Run the contract test to verify RED**

```bash
sh tool/ios_ffmpeg/test_build_contract.sh
```

Expected: failure because the lock/build script and artifact are absent.

- [x] **Step 3: Implement the pinned build script**

Use `set -euo pipefail`, an explicit temporary/build root, detached-signature
verification with the pinned official key, SHA-256 validation, and these core
configure flags for each SDK/architecture:

```bash
--disable-everything --disable-autodetect --disable-network
--disable-programs --disable-doc --disable-avdevice --disable-avfilter
--disable-swscale --disable-swresample
--disable-encoders --disable-decoders --disable-muxers
--enable-avutil --enable-avcodec --enable-avformat
--enable-demuxer=matroska --enable-protocol=file
--enable-parser=aac,h264,hevc --enable-pic --enable-static --disable-shared
--disable-symver --disable-gpl --disable-nonfree
```

Compile FFmpeg static archives separately for iphoneos-arm64,
iphonesimulator-arm64, and iphonesimulator-x86_64. Link those archives plus the
Objective-C bridge into a dynamic framework with hidden FFmpeg symbols, merge
Simulator architectures with `lipo`, and assemble the final artifact with
`xcodebuild -create-xcframework`.

Use `--disable-x86asm` only for the Intel Simulator slice so the reproducible
build does not depend on a host-installed NASM. Device arm64 keeps FFmpeg's ARM
assembly and NEON optimizations.

- [x] **Step 4: Add the binary to both package managers**

Add a local `.binaryTarget(name: "YlFFmpegBridge", path:
"Frameworks/YlFFmpegBridge.xcframework")` and make `yl_player_ios` depend on it.
Set CocoaPods `vendored_frameworks` to the same path and link AVFoundation,
AudioToolbox, CoreMedia, VideoToolbox, and AVFAudio.

- [x] **Step 5: Add notices and replacement instructions**

Record the official source URL/checksum, full configure line, archive signature
URL, rebuild command, and dynamic-framework replacement procedure in
`THIRD_PARTY_NOTICES.md`. Include the unmodified LGPL text and state that a
distribution legal review remains required.

- [x] **Step 6: Build and verify GREEN**

```bash
sh tool/ios_ffmpeg/build_xcframework.sh
sh tool/ios_ffmpeg/test_build_contract.sh
flutter build ios --simulator --debug
```

Expected: the contract test passes and the example links the same bridge through
SPM/CocoaPods metadata without undefined FFmpeg symbols.

- [x] **Step 7: Commit**

```bash
git add tool/ios_ffmpeg packages/yl_player_ios
git commit -m "build: add reproducible iOS FFmpeg bridge"
```

### Task 3: Local Matroska demux and opaque packet ownership

**Files:**
- Modify: `packages/yl_player_ios/ios/native/YlFFmpegBridge/include/YlFFmpegBridge.h`
- Modify: `packages/yl_player_ios/ios/native/YlFFmpegBridge/YlFFmpegBridge.m`
- Create: `packages/yl_player/example/ios/RunnerTests/Fixtures/h264_aac.mkv`
- Create: `packages/yl_player/example/ios/RunnerTests/Fixtures/two_audio_tracks.mkv`
- Create: `packages/yl_player/example/ios/RunnerTests/YlFFmpegBridgeTests.swift`
- Modify: `packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj`
- Create: `tool/ios_ffmpeg/generate_test_media.sh`

**Interfaces:**
- Produces opaque `YLFMediaContextRef` and `YLFPacketRef` handles.
- Produces `YLFMediaInfo`, `YLFStreamInfo`, `ylf_open_local`,
  `ylf_copy_stream_info`, `ylf_read_packet`, `ylf_packet_*` accessors,
  `ylf_seek`, `ylf_packet_release`, and `ylf_close`.
- All timestamps are signed microseconds; unknown is `INT64_MIN`.

- [x] **Step 1: Generate deterministic redistribution-safe fixtures**

Use the installed host FFmpeg with generated color bars/sine audio:

```bash
ffmpeg -y -f lavfi -i testsrc2=size=320x180:rate=24 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 -t 2 \
  -c:v libx264 -pix_fmt yuv420p -g 24 -c:a aac -b:a 96k \
  packages/yl_player/example/ios/RunnerTests/Fixtures/h264_aac.mkv
```

The script also generates a two-AAC-track variant with 440 Hz and 880 Hz inputs,
explicit `-map 0:v -map 1:a -map 2:a`, and language metadata `eng`/`zho`.

- [x] **Step 2: Write failing bridge tests**

Tests assert: one H.264 video + one AAC stream, 320×180 dimensions, sequential
packet reads covering the fixture duration with stream indices and keyframe flags, EOF, seek back to zero, two
audio tracks in the second fixture, and outstanding packet count returns to zero
after every release/close path.

- [x] **Step 3: Run XCTest to verify RED**

Run the Task 1 XCTest command. Expected: linker/compile failure because demux
exports do not exist.

- [x] **Step 4: Implement open, metadata, read, seek, and close**

Open file URLs only, allocate one `AVFormatContext`, call stream discovery,
allow only Matroska, translate codec IDs to `YLFCodecH264`, `YLFCodecHEVC`,
`YLFCodecAAC`, or `YLFCodecUnsupported`, rescale packet timestamps with
`av_rescale_q`, and refcount every packet returned to Swift. `ylf_close` cancels
reads, frees retained packets, and closes the format context exactly once.

- [x] **Step 5: Run tests and leak counters to verify GREEN**

Run XCTest normally, then repeat with Address Sanitizer:

```bash
xcodebuild test \
  -workspace packages/yl_player/example/ios/Runner.xcworkspace \
  -scheme Runner \
  -destination 'platform=iOS Simulator,id=431A3ACD-A229-4F82-AC46-9B9481AC0ADE'
xcodebuild test \
  -workspace packages/yl_player/example/ios/Runner.xcworkspace \
  -scheme Runner \
  -destination 'platform=iOS Simulator,id=431A3ACD-A229-4F82-AC46-9B9481AC0ADE' \
  -enableAddressSanitizer YES
```

Expected: all metadata, seek, EOF, and packet-balance assertions pass with zero
sanitizer findings.

- [x] **Step 6: Rebuild the XCFramework and commit**

```bash
sh tool/ios_ffmpeg/build_xcframework.sh
git add tool/ios_ffmpeg packages/yl_player_ios packages/yl_player/example/ios
git commit -m "feat: add bounded local Matroska demux bridge"
```

### Task 4: Bounded packet queues and generation-safe frame scheduler

**Files:**
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlBoundedPacketQueue.swift`
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFrameScheduler.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlBoundedPacketQueueTests.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlFrameSchedulerTests.swift`
- Modify: `packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- `YlPacketEnvelope` contains opaque packet, kind, PTS/DTS/duration, byte count,
  keyframe, and source generation.
- `YlBoundedPacketQueue.push(_:) -> YlQueuePushResult` returns `.accepted`,
  `.wouldExceedDuration`, `.wouldExceedBytes`, or `.cancelled`.
- `YlFrameScheduler.enqueue(_:)`, `frame(at:generation:)`, `flush(generation:)`,
  and `dispose()` own at most three retained pixel buffers.

- [ ] **Step 1: Write failing queue and scheduler tests**

Cover exact-boundary acceptance, one-byte rejection, one-microsecond rejection,
producer wake after pop, cancellation wake, generation flush releasing all
objects, PTS ordering, newest-due-frame selection, and late-frame drop count.
Use deinit counters around fake packet/frame owners to assert ownership.

- [ ] **Step 2: Run XCTest to verify RED**

Expected: compile failure because queue/scheduler types are absent.

- [ ] **Step 3: Implement the minimal synchronized primitives**

Use `NSCondition` for packet queues and `os_unfair_lock` or `NSLock` for the
three-frame store. Never execute release callbacks while holding a lock. Byte
and duration checks are performed before ownership transfers.

- [ ] **Step 4: Run focused and complete XCTest suites**

Expected: all boundary, wakeup, ordering, drop, and deinit-count assertions pass.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_ios/ios/yl_player_ios packages/yl_player/example/ios
git commit -m "feat: add bounded fallback media queues"
```

### Task 5: Required-hardware VideoToolbox decoder

**Files:**
- Modify: `packages/yl_player_ios/ios/native/YlFFmpegBridge/include/YlFFmpegBridge.h`
- Modify: `packages/yl_player_ios/ios/native/YlFFmpegBridge/YlFFmpegBridge.m`
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlVideoToolboxDecoder.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlVideoToolboxDecoderTests.swift`
- Modify: `packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- Bridge adds `ylf_copy_video_format_description` and
  `ylf_create_video_sample_buffer`; returned Core Foundation objects follow the
  Create Rule.
- `YlVideoToolboxDecoding` exposes `decode(sample:generation:)`, `flush()`, and
  `dispose()` and calls `onFrame(YlVideoFrame)` or `onError(NativePlayerError)`.
- `YlVideoFrame` contains retained `CVPixelBuffer`, PTS, duration, keyframe, and
  generation.

- [ ] **Step 1: Write failing format and decoder tests**

Assert H.264 extradata creates a format description, malformed extradata maps to
`decoder.video_configuration_invalid`, unsupported codec maps to
`decoder.video_hardware_unavailable`, old-generation output is released, and
dispose is idempotent. Inject a `YlVTSessionFactory` fake for deterministic error
and callback tests.

- [ ] **Step 2: Run XCTest to verify RED**

Expected: compile failure because the bridge exports, factory, and decoder are
absent.

- [ ] **Step 3: Implement CoreMedia packet wrapping**

Parse AVCDecoderConfigurationRecord/HEVCDecoderConfigurationRecord parameter
sets, create the matching video format description, and build timed compressed
sample buffers. The CMBlockBuffer release callback releases the owning opaque
packet exactly once.

- [ ] **Step 4: Implement required-hardware decoding**

Create `VTDecompressionSession` with BGRA IOSurface-compatible output and
`kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true`.
Translate creation/decode OSStatus failures to stable errors and query
`kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder` before
reporting hardware decode.

- [ ] **Step 5: Run unit and fixture decode tests**

Decode through the first frame of `h264_aac.mkv` on Simulator when available;
otherwise assert the exact hardware-unavailable error. Packet/frame ownership
must return to zero in either branch.

- [ ] **Step 6: Rebuild and commit**

```bash
sh tool/ios_ffmpeg/build_xcframework.sh
git add packages/yl_player_ios tool/ios_ffmpeg packages/yl_player/example/ios
git commit -m "feat: add iOS hardware video fallback decoder"
```

### Task 6: AAC renderer and audio-master clock

**Files:**
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlAudioRenderer.swift`
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlMediaClock.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlAudioRendererTests.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlMediaClockTests.swift`
- Modify: `packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- `YlAudioRendering` exposes `configure(stream:)`, `enqueue(packet:)`, `play()`,
  `pause()`, `seek(to:)`, `setVolume(_:)`, `setRate(_:)`, `flush()`, and
  `dispose()`.
- `YlMediaClock.position(atHostTime:)` uses rendered audio sample time when audio
  exists and a monotonic PTS anchor for video-only media.
- Scheduled PCM is capped by both duration and bytes before conversion accepts
  another packet.

- [ ] **Step 1: Write failing converter/clock tests**

With injected audio-engine/player-node clocks, assert AAC configuration failure,
500 ms balanced scheduling cap, underrun count, pause stability, seek re-anchor,
0.25/1/4× position progression, volume clamp, and stale-generation completion
suppression.

- [ ] **Step 2: Run XCTest to verify RED**

Expected: compile failure because renderer and clock types are absent.

- [ ] **Step 3: Implement AAC conversion and AVAudioEngine graph**

Build `AVAudioCompressedBuffer` from the opaque AAC packet and codec cookie,
convert to interleaved Float32 `AVAudioPCMBuffer`, and schedule it through:

```text
AVAudioPlayerNode -> AVAudioUnitTimePitch -> AVAudioEngine.mainMixerNode
```

Configure the existing playback `AVAudioSession`, apply volume on the player
node and rate on the time-pitch node, and count an underrun whenever playback is
requested with no scheduled buffer.

- [ ] **Step 4: Implement the media clock and verify GREEN**

Anchor media PTS to `playerTime(forNodeTime:)` rendered sample time. On pause,
freeze the last position; on seek/flush, invalidate completion generations and
establish a new anchor from the first scheduled post-seek sample.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_ios/ios/yl_player_ios packages/yl_player/example/ios
git commit -m "feat: add native AAC fallback rendering"
```

### Task 7: Fallback backend, router integration, and Flutter Texture

**Files:**
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlPlaybackBackend.swift`
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackBackend.swift`
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlIosPlayer.swift`
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlAvPlayerBackend.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlFallbackBackendTests.swift`
- Modify: `packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlPlayerIosPlugin.swift`

**Interfaces:**
- `YlPlaybackBackend` exposes the existing complete command surface, state
  callback, event callback, pixel-buffer copy, activate/deactivate, and dispose.
- `YlIosPlayer` is the sole `FlutterTexture` and owns `activeBackend`,
  `sourceGeneration`, texture ID, routing, and one-switch maximum.
- `YlFallbackBackend` composes bridge context, packet queues, VT decoder, audio
  renderer, media clock, frame scheduler, demux queue, and display link.

- [ ] **Step 1: Write failing orchestration tests**

Inject fake demux/video/audio components and assert local MKV selects fallback,
state engine is `nativeFallback`, first frame is emitted once, rejected open
preserves the prior backend, a second open cancels old callbacks, only one
backend is active, and dispose releases every component once from opening,
playing, paused, error, and partial-construction states.

- [ ] **Step 2: Run XCTest to verify RED**

Expected: compile failure because backend/router session protocols are absent.

- [ ] **Step 3: Extract the current AVPlayer code without behavior changes**

Move current AVPlayer ownership from the plugin file into
`YlAvPlayerBackend.swift`. Keep existing HLS behavior, KVO generation checks,
header rejection, quality/audio selection, display link, and lifecycle logic
byte-for-byte where practical. `YlPlayerIosPlugin` retains registry/channel and
application notification responsibilities only.

- [ ] **Step 4: Implement fallback orchestration**

Open and validate bridge metadata before replacing the active backend. Start the
demux worker only after queues/decoder/audio are configured. Backpressure waits
on the bounded queue conditions. Display-link ticks ask the media clock for a
position, select the due frame, store it for Flutter, and call
`textureFrameAvailable` without transferring pixels through Dart.

- [ ] **Step 5: Map state, tracks, errors, and metrics**

Publish duration, position, buffered duration/bytes, dimensions, AAC tracks,
open/first-frame durations, dropped frames, audio underruns, decoder name
`VideoToolbox`, hardware flag, and engine. Emit one fallback-routing event and
stable error codes from the spec.

- [ ] **Step 6: Run native tests and existing Flutter suites**

Run XCTest, `sh tool/check_foundation.sh`, iOS Simulator build, and the existing
HLS integration. Expected: all prior AVPlayer and Dart behavior remains green.

- [ ] **Step 7: Commit**

```bash
git add packages/yl_player_ios packages/yl_player tool
git commit -m "feat: route local MKV to iOS native fallback"
```

### Task 8: Seek, audio-track switching, lifecycle reconstruction, and HEVC

**Files:**
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackBackend.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlVideoToolboxDecoder.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlAudioRenderer.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlFallbackLifecycleTests.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/Fixtures/hevc_aac.mkv`
- Modify: `packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- Seek and lifecycle reconstruction reuse the existing backend command surface.
- Internal `pipelineGeneration` increments on seek, deactivate, open, and
  dispose independently of the player source generation.

- [ ] **Step 1: Add HEVC fixture generation and failing lifecycle tests**

Generate a 2-second 320×180 HEVC/AAC MKV with `libx265`, then test seek flush
order, suppression before target PTS, audio-only flush on track switch,
background release, resume reconstruction, memory-warning release, repeated
deactivate/activate, and H.265 configuration/hardware-unavailable mapping.

- [ ] **Step 2: Run XCTest to verify RED**

Expected: behavior assertions fail because seek/reconstruction and HEVC format
creation are not complete.

- [ ] **Step 3: Implement seek as an ordered transaction**

Pause clocks, increment generation, cancel demux waiters, clear queues/frame
store/PCM, call bridge seek to the preceding video keyframe, flush audio,
invalidate/recreate VT, restart demux, suppress decoded frames before target,
and anchor clocks from the first accepted post-seek sample.

- [ ] **Step 4: Implement track switching and lifecycle reconstruction**

Persist selected audio stream ID, quality/rate/volume, position, and live intent.
Track switch replaces only audio converter/queue state. Deactivate closes demux,
VT, audio engine buffers, display link, and all queues; activate reopens the file
and seeks before honoring a pending play.

- [ ] **Step 5: Implement HEVC configuration and run GREEN tests**

Create the HEVC format description from hvcC parameter sets and require hardware
exactly as H.264. Tests accept decoded output only when hardware is reported;
otherwise they require `decoder.video_hardware_unavailable`.

- [ ] **Step 6: Commit**

```bash
git add packages/yl_player_ios tool/ios_ffmpeg packages/yl_player/example/ios
git commit -m "feat: complete iOS MKV fallback lifecycle"
```

### Task 9: Flutter MKV integration tests and package publication boundaries

**Files:**
- Create: `packages/yl_player/example/assets/test_media/h264_aac.mkv`
- Create: `packages/yl_player/example/assets/test_media/two_audio_tracks.mkv`
- Modify: `packages/yl_player/example/pubspec.yaml`
- Create: `packages/yl_player/example/integration_test/ios_mkv_playback_test.dart`
- Create: `packages/yl_player/.pubignore`
- Create: `packages/yl_player_ios/.pubignore`
- Modify: `tool/check_foundation.sh`

**Interfaces:**
- Uses only public `YlPlayerController`, `YlMediaSource.file`, events, tracks,
  state, and metrics.
- Test media remains excluded from the published Dart archive.

- [ ] **Step 1: Write the failing public integration tests**

Copy bundled fixture bytes to `Directory.systemTemp`, open with
`YlMediaSource.file(..., formatHint: YlFormatHint.matroska)`, and assert fallback
engine, texture ID, first frame, H.264 hardware flag, positive position, pause,
seek near one second, volume/speed, two audio tracks and selection, then
idempotent dispose. Add a malformed/unsupported fixture case proving the prior
HLS source remains active.

- [ ] **Step 2: Run on Simulator to verify RED**

```bash
flutter test integration_test/ios_mkv_playback_test.dart \
  -d 431A3ACD-A229-4F82-AC46-9B9481AC0ADE
```

Expected: failure at fallback routing/first frame before final wiring.

- [ ] **Step 3: Complete only the wiring needed for GREEN**

Add fixture assets to the example bundle, copy them to a real file URL in test
setup, fix state/event serialization gaps exposed by the test, and add an
explicit `tool/check_native_ios.sh` for XCTest + HLS + MKV integration. Keep
network integration out of the offline foundation gate.

- [ ] **Step 4: Add publication exclusions and verify archives**

Exclude test media, FFmpeg build intermediates, native test products, and source
archives while retaining the checked-in XCFramework, notices, licenses, and
rebuild scripts. Run all four `dart pub publish --dry-run`; each must report zero
warnings and the iOS archive must contain every XCFramework slice.

- [ ] **Step 5: Run GREEN integration and commit**

```bash
sh tool/check_native_ios.sh
git add packages/yl_player packages/yl_player_ios tool
git commit -m "test: cover iOS local MKV playback"
```

### Task 10: Physical-device, memory, compatibility, and release truth

**Files:**
- Create: `docs/verification/ios-mkv-device-matrix.md`
- Modify: `packages/yl_player/README.md`
- Modify: `packages/yl_player/CHANGELOG.md`
- Modify: `packages/yl_player_ios/README.md`
- Modify: `packages/yl_player_ios/CHANGELOG.md`
- Modify: `docs/superpowers/plans/2026-09-03-yl-player-native-main-paths.md`

**Interfaces:**
- Produces the evidence required to change documentation from
  fallback-required to local-MKV development support.

- [ ] **Step 1: Run the complete automated gate on the final tree**

```bash
sh tool/check_foundation.sh
sh tool/check_native_ios.sh
flutter build apk --debug
flutter build ios --simulator --debug
```

Expected: every command exits zero; HLS remains `+2`, and MKV integration passes
without falling back to AVPlayer.

- [ ] **Step 2: Run the physical-device matrix**

On at least one iOS 15-capable device and one current iOS device, record device,
OS, codec/profile/resolution, decoder property, first-frame time, average/max
memory, seek result, audio sync, background/resume, and 30-minute playback. H.264
1080p30 must play with hardware reported; H.265 must either play with hardware
reported or return the exact hardware-unavailable code.

- [ ] **Step 3: Run repeated lifecycle and memory evidence**

Run 100 open/play/seek/dispose cycles and capture Instruments/memgraph evidence.
The bridge outstanding-packet counter returns to zero each cycle; VT sessions,
textures, display links, packet bytes, frame count, and scheduled PCM do not grow
monotonically.

- [ ] **Step 4: Update documentation to the measured truth**

Only after Steps 1–3 pass, document local MKV H.264/AAC support, conditional HEVC
hardware support, iOS 15 floor, local-only limitation, excluded codecs, binary
license/rebuild instructions, and measured devices. Keep HTTP-FLV/custom-header
sources marked unsupported.

- [ ] **Step 5: Commit verified documentation, then run clean publication checks**

```bash
git add docs packages
git commit -m "docs: record iOS MKV fallback verification"
dart pub -C packages/yl_player_platform_interface publish --dry-run
dart pub -C packages/yl_player_android publish --dry-run
dart pub -C packages/yl_player_ios publish --dry-run
dart pub -C packages/yl_player publish --dry-run
git diff --check
git status --short
```

Expected: four zero-warning dry runs and a clean worktree after the commit. Do
not push or execute a real publication command.
