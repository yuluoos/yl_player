# iOS Correctness and Native Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct iOS metrics and capabilities, make fallback quality constraints truthful and persistent, emit compact versioned state deltas, and decompose fallback helpers without altering the proven media pipeline.

**Architecture:** Share pure iOS channel, capability, quality, track, and recovery policies across AVPlayer and the VideoToolbox/FFmpeg fallback. Each committed source receives a process-unique channel generation; full snapshots establish it and periodic callbacks emit only dynamic deltas for that generation.

**Tech Stack:** Swift, iOS 15+, AVFoundation/AVPlayer, VideoToolbox, AudioToolbox, FFmpeg bridge, Flutter channels, XCTest, Flutter integration tests.

**Spec:** `docs/superpowers/specs/2026-09-04-full-repository-optimization-design.md`

## Global Constraints

- Complete `docs/superpowers/plans/2026-09-04-dart-contract-and-state-semantics.md` before this plan; iOS envelopes target channel protocol version 1.
- iOS 15 remains the minimum.
- AVPlayer stays system-managed; plugin-owned fallback video decoding remains hardware-required through VideoToolbox.
- Candidate preparation, activation failure, and superseded open cancellation must preserve the current active backend and must not emit terminal state.
- Do not change the demux pump, lock ownership, decoder lifecycle, audio scheduling, or reconnect transaction ordering unless a failing regression test proves a defect.
- Full state must be emitted on listen and semantic transitions; only periodic callbacks become deltas.
- The existing HLS, MKV, network MKV, HTTP-FLV, and authenticated-HLS simulator suites must remain green.
- Do not expose URLs, query strings, credentials, or headers in diagnostics.
- Every behavior change follows red-green-refactor and ends in a focused commit.

## File Structure

- Create `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlIosChannel.swift`: process-unique channel generations, canonical capabilities, metrics maps, and versioned full/delta envelope builders.
- Create `packages/yl_player/example/ios/RunnerTests/YlIosChannelTests.swift`: codec/capability/metric/envelope tests.
- Create `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackQualityPolicy.swift`: parsed constraints and fixed-stream validation.
- Create `packages/yl_player/example/ios/RunnerTests/YlFallbackQualityPolicyTests.swift`: width, height, bitrate, and unknown-metadata tests.
- Create `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackTrackCatalog.swift`: pure audio/video track-map construction.
- Create `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackRecoveryPolicy.swift`: fallback reconnect/recovery value types moved from the monolith.
- Modify `YlAvPlayerBackend.swift`, `YlFallbackBackend.swift`, and `YlIosPlayer.swift`: use shared capability/envelope generation and persist quality constraints.
- Modify `YlFallbackModels.swift`: retain source routing models; move track/recovery helpers to their focused files.
- Modify matching Runner XCTest files when extracted type visibility changes.

---

### Task 1: Canonical iOS channel capabilities and dropped-frame metric

**Files:**
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlIosChannel.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlIosChannelTests.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlAvPlayerBackend.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackBackend.swift`

**Interfaces:**
- Produces: `YlIosChannel.capabilities(hardwareH264:hardwareHevc:)` describing
  the complete implementation and including only codecs whose
  `VTIsHardwareDecodeSupported` probe succeeds.
- Exact formats: `automatic`, `hls`, `httpFlv`, `mp4`, `mov`, `matroska`, and `flv`.
- Exact plugin-owned hardware codec identifiers: `video/avc` and `video/hevc`.
- Produces: `YlIosChannel.fallbackMetrics(...)` with key `droppedVideoFrames`; key `droppedFrames` must not be emitted.

- [ ] **Step 1: Write failing capability and metric-key tests**

```swift
func testCapabilitiesDescribeCompletePlayerWithCanonicalMimeCodecs() {
  let capabilities = YlIosChannel.capabilities(
    hardwareH264: true,
    hardwareHevc: true
  )
  XCTAssertEqual(
    capabilities["hardwareVideoCodecs"] as? [String],
    ["video/avc", "video/hevc"]
  )
  XCTAssertEqual(
    Set(capabilities["supportedFormats"] as? [String] ?? []),
    Set(["automatic", "hls", "httpFlv", "mp4", "mov", "matroska", "flv"])
  )
}

func testFallbackMetricsUseDartContractDroppedFrameKey() {
  let metrics = YlIosChannel.fallbackMetrics(
    openDurationMs: 20,
    firstFrameDurationMs: 40,
    bufferedDurationMs: 100,
    bufferedBytes: 4096,
    droppedVideoFrames: 7,
    audioUnderruns: 1,
    reconnectCount: 2
  )
  XCTAssertEqual(metrics["droppedVideoFrames"] as? Int, 7)
  XCTAssertNil(metrics["droppedFrames"] ?? nil)
}
```

- [ ] **Step 2: Run the new XCTest and verify failure**

Run through the existing native harness:

```bash
sh tool/check_native_ios.sh
```

Expected: with an iOS Simulator already booted, the Runner test target fails to
compile because `YlIosChannel` does not exist.

- [ ] **Step 3: Implement one capability and metrics source of truth**

Create:

```swift
enum YlIosChannel {
  static func capabilities(
    hardwareH264: Bool,
    hardwareHevc: Bool
  ) -> [String: Any?] {
    var codecs = [String]()
    if hardwareH264 { codecs.append("video/avc") }
    if hardwareHevc { codecs.append("video/hevc") }
    return [
      "hardwareVideoCodecs": codecs,
      "supportedFormats": [
        "automatic", "hls", "httpFlv", "mp4", "mov", "matroska", "flv",
      ],
      "maxConcurrentVideoDecoders": 1,
    ]
  }

  static func fallbackMetrics(
    openDurationMs: Int64?, firstFrameDurationMs: Int64?,
    bufferedDurationMs: Int64, bufferedBytes: Int,
    droppedVideoFrames: Int, audioUnderruns: Int, reconnectCount: Int
  ) -> [String: Any?] {
    [
      "openDurationMs": openDurationMs,
      "firstFrameDurationMs": firstFrameDurationMs,
      "bufferedDurationMs": bufferedDurationMs,
      "bufferedBytes": bufferedBytes,
      "droppedVideoFrames": droppedVideoFrames,
      "audioUnderruns": audioUnderruns,
      "reconnectCount": reconnectCount,
    ]
  }
}
```

Call `VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)` and
`VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)` when constructing the
shared capability snapshot, then use that snapshot in both backends. Use the
shared metrics builder in fallback state. AVPlayer's `isHardwareDecoding`
remains `false` and decoder name remains nil because its internal decoder
selection is opaque; capability documentation covers only formats plus
plugin-owned VideoToolbox codecs that pass the device probe.

Change `PlayerConfiguration`'s missing-value decoder-policy default from
`preferHardware` to `hardwareOnly`; keep explicit legacy input accepted and add
an XCTest assertion for both cases.

- [ ] **Step 4: Run native tests and the Dart end-to-end decoder test**

```bash
sh tool/check_native_ios.sh
flutter test packages/yl_player_platform_interface/test/channel_codec_test.dart
```

Expected: native tests and all five integration suites pass; a fallback envelope using `droppedVideoFrames` decodes to `YlPlaybackMetrics.droppedVideoFrames`.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_ios/ios packages/yl_player/example/ios/RunnerTests
git commit -m "fix(ios): align metrics and capabilities"
```

### Task 2: Truthful fixed-stream quality constraints

**Files:**
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackQualityPolicy.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlFallbackQualityPolicyTests.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackBackend.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlIosPlayer.swift`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlFallbackBackendTests.swift`

**Interfaces:**
- Produces: throwing `YlFallbackQualityConstraint.init(validating:)` with
  optional positive `maxWidth`, `maxHeight`, and `maxBitrate`.
- Produces: `YlFallbackQualityPolicy.validate(constraint:stream:) throws` where stream is `YlFallbackVideoDescriptor(width: Int, height: Int, bitrate: Int?)`.
- Error: category `decoderUnsupported`, code `decoder.quality_constraint_unsupported`, stable message without source details.
- Produces: `YlIosPlayer.lastQualityConstraint` applied to every newly committed backend.

- [ ] **Step 1: Write failing pure policy tests**

```swift
func testAcceptsConstraintSatisfiedByFixedStream() throws {
  XCTAssertNoThrow(try YlFallbackQualityPolicy.validate(
    constraint: try YlFallbackQualityConstraint(
      validating: ["maxWidth": 1920, "maxHeight": 1080]
    ),
    stream: YlFallbackVideoDescriptor(width: 1280, height: 720, bitrate: nil)
  ))
}

func testRejectsDimensionsExceededByFixedStream() {
  XCTAssertThrowsError(try YlFallbackQualityPolicy.validate(
    constraint: try YlFallbackQualityConstraint(validating: ["maxHeight": 480]),
    stream: YlFallbackVideoDescriptor(width: 1280, height: 720, bitrate: 2_000_000)
  )) { error in
    XCTAssertEqual((error as? NativePlayerError)?.code, "decoder.quality_constraint_unsupported")
  }
}

func testRejectsBitrateCeilingWhenBitrateMetadataIsUnavailable() {
  XCTAssertThrowsError(try YlFallbackQualityPolicy.validate(
    constraint: try YlFallbackQualityConstraint(validating: ["maxBitrate": 1_000_000]),
    stream: YlFallbackVideoDescriptor(width: 1280, height: 720, bitrate: nil)
  ))
}
```

Also test known bitrate below/equal/above the ceiling and invalid maps defensively reject rather than trap.

- [ ] **Step 2: Run the new policy test and verify failure**

```bash
sh tool/check_native_ios.sh
```

Expected: compilation fails because the quality policy types do not exist.

- [ ] **Step 3: Implement fixed-stream validation**

Parse each present value through `int64`, reject values outside
`1...Int32.max`, and keep absent values nil:

```swift
struct YlFallbackQualityConstraint: Equatable {
  let maxWidth: Int?
  let maxHeight: Int?
  let maxBitrate: Int?

  init(validating map: [String: Any?]) throws {
    func positive(_ key: String) throws -> Int? {
      guard let raw = map[key] else { return nil }
      guard let value = int64(raw), value > 0, value <= Int64(Int32.max) else {
        throw NativePlayerError(
          category: "source",
          code: "source.quality_constraint_invalid",
          message: "Quality constraint values must be positive native integers."
        )
      }
      return Int(value)
    }
    maxWidth = try positive("maxWidth")
    maxHeight = try positive("maxHeight")
    maxBitrate = try positive("maxBitrate")
  }
}
```

Use this exact descriptor and error boundary:

```swift
struct YlFallbackVideoDescriptor: Equatable {
  let width: Int
  let height: Int
  let bitrate: Int?
}

enum YlFallbackQualityPolicy {
  static func validate(
    constraint: YlFallbackQualityConstraint,
    stream: YlFallbackVideoDescriptor
  ) throws {
    let exceedsSize = constraint.maxWidth.map { stream.width > $0 } ?? false
      || constraint.maxHeight.map { stream.height > $0 } ?? false
    let exceedsBitrate = constraint.maxBitrate.map { maximum in
      guard let bitrate = stream.bitrate else { return true }
      return bitrate > maximum
    } ?? false
    guard !exceedsSize, !exceedsBitrate else {
      throw NativePlayerError(
        category: "decoderUnsupported",
        code: "decoder.quality_constraint_unsupported",
        message: "The fixed fallback video stream exceeds the requested quality constraint."
      )
    }
  }
}
```

The current FFmpeg bridge exposes no bitrate field, so fallback descriptors use `bitrate: nil`; a bitrate ceiling therefore rejects truthfully.

- [ ] **Step 4: Persist and apply constraints through lifecycle changes**

Replace fallback's `case "setQualityConstraint": return` with parsing, validation against the active stream, and assignment only after validation succeeds. Add `lastQualityConstraint` to `YlIosPlayer`; after a successful `setQualityConstraint` command, store the map. Pass it into each new `YlFallbackBackend` and apply it to AVPlayer before opening a newly routed AV source.

During fallback reactivation/reconnect, validate the selected candidate video descriptor before assigning `videoStream` or replacing decoder state. If validation fails, throw the stable nonterminal error and preserve the current backend/stream. Add a `YlFallbackBackendTests` case that attempts a rejected constraint and asserts the backend remains active and can subsequently pause/play.

- [ ] **Step 5: Run focused and complete native checks**

```bash
sh tool/check_native_ios.sh
```

Expected: all XCTest and integration suites pass; constraint rejection is returned to the method caller without an emitted terminal state.

- [ ] **Step 6: Commit**

```bash
git add packages/yl_player_ios/ios packages/yl_player/example/ios/RunnerTests
git commit -m "fix(ios): enforce fallback quality constraints"
```

### Task 3: Process-unique source generations and state-delta envelopes

**Files:**
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlIosChannel.swift`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlIosChannelTests.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlAvPlayerBackend.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackBackend.swift`

**Interfaces:**
- Produces: `YlIosChannelGeneration.next(): UInt64`, protected by an `NSLock`.
- Produces: `YlIosChannel.fullState(playerId:generation:state:)` and `YlIosChannel.stateDelta(playerId:generation:delta:)` using protocol version 1.
- Each backend exposes no generation publicly; it stamps its own current committed-source generation.

- [ ] **Step 1: Write failing generation/envelope tests**

```swift
func testChannelGenerationsAreStrictlyIncreasing() {
  let first = YlIosChannelGeneration.next()
  let second = YlIosChannelGeneration.next()
  XCTAssertGreaterThan(second, first)
}

func testDeltaEnvelopeContainsOnlyDynamicPayload() {
  let envelope = YlIosChannel.stateDelta(
    playerId: 7,
    generation: 9,
    delta: [
      "positionMs": 1000,
      "bufferedPositionMs": 3000,
      "isAtLiveEdge": false,
      "liveOffsetMs": 2000,
      "metrics": ["droppedVideoFrames": 2],
    ]
  )
  XCTAssertEqual(envelope["protocolVersion"] as? Int, 1)
  XCTAssertEqual(envelope["type"] as? String, "stateDelta")
  XCTAssertNil((envelope["delta"] as? [String: Any?])?["capabilities"] ?? nil)
}
```

- [ ] **Step 2: Run the channel XCTest and verify failure**

```bash
sh tool/check_native_ios.sh
```

Expected: compilation fails until the generation and envelope APIs exist.

- [ ] **Step 3: Implement generation and envelope builders**

Use a static lock/counter:

```swift
enum YlIosChannelGeneration {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var value: UInt64 = 0

  static func next() -> UInt64 {
    lock.withLock {
      value &+= 1
      return value
    }
  }
}
```

Both envelope builders include `playerId`, `protocolVersion: 1`, `generation`, and the correct `type`/payload key.

- [ ] **Step 4: Assign generations only to committed source paths**

Give AVPlayer a `channelGeneration` initialized with `next()` and replace it with a new value immediately before a validated `open` installs a new item. Give each fallback instance one generation at construction; preserve it across seek/reconnect of that same committed source. A candidate that fails before activation must not publish a full state; a superseded candidate must be disposed before any queued delta can be emitted.

Wrap all semantic `emitState` payloads with `fullState`. Add `emitStateDelta` to each backend and change only these periodic callbacks:

- AVPlayer periodic time observer: call `emitStateDelta`.
- Fallback `displayLinkTick`: call `emitStateDelta`.

Each delta contains position, buffered position, live edge/offset, and dynamic metrics only. Keep status, duration, DVR window, size, engine, decoder identity, tracks, capabilities, and error in full snapshots.

- [ ] **Step 5: Verify native and Dart generation behavior**

```bash
sh tool/check_native_ios.sh
flutter test packages/yl_player_platform_interface/test/channel_player_test.dart packages/yl_player_ios/test/yl_player_ios_test.dart
```

Expected: XCTest/integration suites pass; Dart ignores stale and pre-snapshot deltas and merges matching deltas.

- [ ] **Step 6: Commit**

```bash
git add packages/yl_player_ios/ios packages/yl_player/example/ios/RunnerTests
git commit -m "perf(ios): send compact position deltas"
```

### Task 4: Extract fallback track and recovery policies

**Files:**
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackTrackCatalog.swift`
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackRecoveryPolicy.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackModels.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackBackend.swift`
- Modify: relevant existing Runner tests for moved types only.

**Interfaces:**
- Produces: `YlFallbackTrackCatalog.audioTracks(streams:selectedIndex:codecName:)` and `videoTrack(stream:codecName:bitrate:)` returning channel maps.
- Produces: recovery value types currently embedded in `YlFallbackBackend.swift`, retaining their existing names and signatures so callers do not change behavior.

- [ ] **Step 1: Add a focused track-map characterization test**

Create a `YLFStreamInfo` video fixture and assert:

```swift
let track = YlFallbackTrackCatalog.videoTrack(
  stream: stream,
  codecName: "h264",
  bitrate: nil
)
XCTAssertEqual(track["id"] as? String, "video-2")
XCTAssertEqual(track["kind"] as? String, "video")
XCTAssertEqual(track["codec"] as? String, "video/avc")
XCTAssertEqual(track["width"] as? Int, 1280)
XCTAssertEqual(track["height"] as? Int, 720)
XCTAssertNil(track["bitrate"] ?? nil)
XCTAssertEqual(track["isSelected"] as? Bool, true)
```

Add equivalent selected/unselected audio fixtures and assert stable IDs and codec labels.

- [ ] **Step 2: Run the native suite and verify the new test fails to compile**

```bash
sh tool/check_native_ios.sh
```

Expected: compilation fails because `YlFallbackTrackCatalog` does not exist.

- [ ] **Step 3: Extract pure track construction and existing recovery types**

Move track-map construction from `rebuildTracks` into `YlFallbackTrackCatalog`, using MIME video codec names. Move pure reconnect/backoff/recovery value types and policies from `YlFallbackBackend.swift`/`YlFallbackModels.swift` into `YlFallbackRecoveryPolicy.swift` without renaming public-to-module signatures or changing constants.

Do not move locks, mutable queues, decoder objects, display links, or demux work into these pure files.

- [ ] **Step 4: Run native tests after the mechanical extraction**

```bash
sh tool/check_native_ios.sh
```

Expected: all XCTest and integration suites pass with unchanged recovery outcomes.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_ios/ios packages/yl_player/example/ios/RunnerTests
git commit -m "refactor(ios): extract fallback policies"
```

### Task 5: Extract fallback state encoding and prepared-source ownership

**Files:**
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackStateEncoder.swift`
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlPreparedFallback.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackBackend.swift`
- Modify: relevant Runner tests only when type locations change.

**Interfaces:**
- Produces: `YlFallbackStateSnapshot.fullMap` and `YlFallbackDynamicSnapshot.deltaMap`; both are immutable value snapshots assembled by the backend under its existing lock discipline.
- Produces: existing `YlPreparedFallback`, `YlPreparedOpen`, and prepared-source transfer APIs with unchanged signatures in a focused file.

- [ ] **Step 1: Record the passing lifecycle and preparation baseline**

```bash
sh tool/check_native_ios.sh
```

Expected: all native and integration checks pass before extraction.

- [ ] **Step 2: Extract immutable state mapping**

Create value structs whose computed properties return the same keys now emitted by fallback:

```swift
struct YlFallbackDynamicSnapshot {
  let positionMs: Int64
  let bufferedPositionMs: Int64
  let isAtLiveEdge: Bool
  let liveOffsetMs: Int64?
  let metrics: [String: Any?]

  var deltaMap: [String: Any?] {
    [
      "positionMs": positionMs,
      "bufferedPositionMs": bufferedPositionMs,
      "isAtLiveEdge": isAtLiveEdge,
      "liveOffsetMs": liveOffsetMs,
      "metrics": metrics,
    ]
  }
}
```

`YlFallbackStateSnapshot.fullMap` includes all public state fields and embeds
the probed capability map passed into the snapshot. The backend remains
responsible for reading live mutable state; the encoder receives values and
owns no locks.

- [ ] **Step 3: Move prepared-source types without algorithm changes**

Move `YlPreparedFallback`, `YlPreparedOpen`, and their ownership/transfer helpers into `YlPreparedFallback.swift`. Preserve cancellation checks, network byte-source ownership, `takeMedia`, `discard`, and hardware preflight order exactly.

- [ ] **Step 4: Run targeted ownership tests and the full iOS harness**

```bash
sh tool/check_native_ios.sh
```

Expected: `YlOpenedMediaTests`, `YlOpenCoordinatorTests`, fallback lifecycle tests, all other XCTest, and all integration suites pass.

- [ ] **Step 5: Verify decomposition boundaries**

Run:

```bash
rg -n "\[\"playerId\"|\[\"status\"|\[\"capabilities\"" packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackBackend.swift
rg -n "NSLock|DispatchQueue|YlVideoToolboxDecoder|YlAudioRenderer" packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackStateEncoder.swift
```

Expected: the first search finds no hand-built channel envelope; the second finds no mutable pipeline ownership in the encoder.

- [ ] **Step 6: Commit**

```bash
git add packages/yl_player_ios/ios packages/yl_player/example/ios/RunnerTests
git commit -m "refactor(ios): split fallback state and preparation"
```

### Task 6: iOS-phase verification

**Files:**
- Modify only if verification exposes a defect: iOS files changed in Tasks 1–5.

**Interfaces:**
- Produces: a clean iOS phase ready for repository-wide acceptance.

- [ ] **Step 1: Run all iOS native and integration verification**

```bash
sh tool/check_native_ios.sh
```

Expected: XCTest passes; HLS, local MKV, network MKV, HTTP-FLV reconnect, and authenticated HLS integration suites all pass. The simulator-only hardware decode test may skip only under its existing explicit hardware-unavailable condition.

- [ ] **Step 2: Run Dart foundation and whitespace checks**

```bash
sh tool/check_foundation.sh
git diff --check
```

Expected: exit 0 with no format or whitespace changes.

- [ ] **Step 3: Commit only verification-driven corrections**

```bash
git add packages/yl_player_ios packages/yl_player packages/yl_player_platform_interface
git commit -m "test(ios): close optimization regressions"
```

If no files changed, do not create an empty commit.
