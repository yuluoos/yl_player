# iOS Network MKV VOD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add bounded HTTP/HTTPS Matroska VOD input to the existing iOS FFmpeg-demux, VideoToolbox-hardware-decode, native-AAC fallback without changing the public Dart API.

**Architecture:** URLSession owns HTTP, TLS, headers, redirects, retry, and cancellation, feeding a fixed-capacity absolute-offset ring buffer. The minimized network-disabled FFmpeg bridge reads that source through custom AVIO callbacks; the existing fallback backend keeps packet/audio/frame ownership and is replaced only after an asynchronous candidate passes preflight.

**Tech Stack:** Flutter 3.44+/Dart 3.12+, Swift 5.9, Foundation URLSession, Objective-C/C, FFmpeg 9.0.1 custom AVIO, CoreMedia, VideoToolbox, AVFAudio, XCTest, Flutter integration_test.

**Spec:** `docs/superpowers/specs/2026-09-03-ios-network-mkv-vod-design.md`

## Global Constraints

- Minimum iOS version remains 15.0; Android remains API 24.
- Only HTTP/HTTPS MKV VOD is added; network MKV live, HTTP-FLV fallback, subtitles, DRM, downloads, persistent cache, and non-HTTP transports remain excluded.
- FFmpeg stays pinned to 9.0.1 with network/TLS/decoders disabled and keeps its current LGPL build contract.
- Video must be H.264 or H.265 through required-hardware VideoToolbox; audio must be AAC-LC through the existing Apple converter.
- No encoded packet, PCM, or decoded frame crosses the Dart boundary.
- The active backend is not replaced until the candidate completes network, container, codec, and hardware preflight.
- Physical-device, 30-minute, and Instruments acceptance remain deferred and must not be claimed by documentation.
- Work remains on the user-approved `main` branch; commit each green task and do not push or publish.
- Set `YL_IOS_SIMULATOR_ID` to a booted Simulator UUID before targeted XCTest commands.

---

### Task 1: Network route and deterministic buffer budgets

**Files:**
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackModels.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlSourceRouter.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlAvPlayerBackend.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlIosPlayer.swift`
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackBufferBudget.swift`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlSourceRouterTests.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlFallbackBufferBudgetTests.swift`
- Modify: `packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `YlIosSourceRoute.networkMatroska`.
- Produces: `YlNetworkConfiguration` parsed from the existing channel map.
- Produces: `YlFallbackBufferBudget.make(configuration:) throws` with `networkBytes`, `scheduledAudioBytes`, and `inFlightPacketBytes`.

- [x] **Step 1: Write failing route tests**

Replace the old remote-MKV rejection assertion and add live/header cases:

```swift
func testRemoteMkvVodRoutesToNetworkFallback() {
  let source = YlIosSourceDescriptor(
    uri: "https://media.test/movie.mkv", kind: "network",
    formatHint: "matroska", isLive: false, hasHeaders: true
  )
  XCTAssertEqual(YlSourceRouter.route(source), .networkMatroska)
}

func testAutomaticRemoteMkvRoutesToNetworkFallback() {
  let source = YlIosSourceDescriptor(
    uri: "https://media.test/movie.mkv?token=secret", kind: "network",
    formatHint: "automatic", isLive: false, hasHeaders: false
  )
  XCTAssertEqual(YlSourceRouter.route(source), .networkMatroska)
}

func testRemoteMkvLiveIsRejected() {
  let source = YlIosSourceDescriptor(
    uri: "https://media.test/live.mkv", kind: "network",
    formatHint: "matroska", isLive: true, hasHeaders: false
  )
  XCTAssertEqual(
    YlSourceRouter.route(source).rejectionCode,
    "container.network_mkv_live_unsupported"
  )
}
```

- [x] **Step 2: Write failing budget tests**

Add `YlFallbackBufferBudgetTests` to RunnerTests and assert exact values:

```swift
func testBalancedBudgetUsesSpecifiedCeilings() throws {
  let configuration = PlayerConfiguration(map: ["bufferMode": "balanced"])
  let budget = try YlFallbackBufferBudget.make(configuration: configuration)
  XCTAssertEqual(budget.networkBytes, 8 * 1024 * 1024)
  XCTAssertEqual(budget.scheduledAudioBytes, 2 * 1024 * 1024)
  XCTAssertEqual(budget.inFlightPacketBytes, 4 * 1024 * 1024)
}

func testCustomBudgetSumsExactlyToConfiguredLimit() throws {
  let total = 13 * 1024 * 1024 + 7
  let configuration = PlayerConfiguration(map: [
    "bufferMode": "custom", "maxBufferBytes": total,
  ])
  let budget = try YlFallbackBufferBudget.make(configuration: configuration)
  XCTAssertEqual(
    budget.networkBytes + budget.scheduledAudioBytes + budget.inFlightPacketBytes,
    total
  )
}

func testCustomBudgetBelowThreeMiBFails() {
  let configuration = PlayerConfiguration(map: [
    "bufferMode": "custom", "maxBufferBytes": 3 * 1024 * 1024 - 1,
  ])
  XCTAssertThrowsError(try YlFallbackBufferBudget.make(configuration: configuration)) {
    XCTAssertEqual(($0 as? NativePlayerError)?.code, "resource.network_buffer_limit")
  }
}
```

- [x] **Step 3: Run targeted XCTest and verify RED**

Run:

```bash
xcodebuild test -quiet \
  -workspace packages/yl_player/example/ios/Runner.xcworkspace \
  -scheme Runner \
  -destination "platform=iOS Simulator,id=$YL_IOS_SIMULATOR_ID" \
  -only-testing:RunnerTests/YlSourceRouterTests \
  -only-testing:RunnerTests/YlFallbackBufferBudgetTests
```

Expected: compile failures for `networkMatroska`, `maxBufferBytes`, and `YlFallbackBufferBudget`.

- [x] **Step 4: Implement route, configuration, and budgets**

Add `.networkMatroska`. Route network Matroska before the generic fallback rejection, allow its headers, reject `isLive`, and leave HLS custom-header rejection unchanged. Until Task 7 connects asynchronous preparation, translate `.networkMatroska` to the existing fallback-required command error so the staged tree remains exhaustive and buildable. Extend `PlayerConfiguration` with:

```swift
let decoderPolicy: String
let maxBufferBytes: Int?
let network: YlNetworkConfiguration
```

Parse and clamp all duration values to nonnegative `Int64`, retry counts to `0...20`, redirects to `0...20`, and delays to `0...60_000` milliseconds. Implement the exact default table and 3 MiB custom floor from the spec. For custom allocation, subtract three 1 MiB floors, use integer `70/100` and `20/100` shares, and give the remainder to `inFlightPacketBytes` so the exact sum is preserved.

- [x] **Step 5: Run targeted and complete native tests**

Run the targeted command from Step 3, then `sh tool/check_native_ios.sh`.

Expected: all route/budget tests and existing XCTest/HLS/local-MKV integration pass.

- [x] **Step 6: Commit**

```bash
git add packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios \
  packages/yl_player/example/ios/RunnerTests \
  packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat: route iOS network MKV VOD"
```

### Task 2: Absolute-offset bounded byte buffer

**Files:**
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlByteSource.swift`
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlByteRingBuffer.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlByteRingBufferTests.swift`
- Modify: `packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `YlByteSource` and `YlByteSourceError`.
- Produces: `YlByteRingBuffer(capacity:)`, nonblocking `append(_:at:)`, blocking `write(_:at:)`, `read(into:)`, `seekWithinBuffer(to:)`, `finish()`, `fail(_:)`, `cancel()`, and `shrink(to:)`.
- The buffer stores one contiguous absolute byte interval and never exceeds `capacity`.

- [ ] **Step 1: Write failing ring-buffer tests**

Cover exact capacity, partial reads, retained-window rewind, producer blocking, consumer blocking, EOF, failure, cancellation, and shrink:

```swift
func testAppendNeverExceedsExactCapacity() throws {
  let buffer = YlByteRingBuffer(capacity: 4)
  XCTAssertEqual(try buffer.append(Data([1, 2, 3, 4]), at: 0), 4)
  XCTAssertEqual(buffer.bufferedBytes, 4)
  XCTAssertEqual(try buffer.append(Data([5]), at: 4), 0)
  XCTAssertEqual(buffer.bufferedBytes, 4)
}

func testReadBlocksUntilProducerAppends() {
  let buffer = YlByteRingBuffer(capacity: 8)
  let finished = expectation(description: "read wakes")
  DispatchQueue.global().async {
    var bytes = [UInt8](repeating: 0, count: 3)
    let count = try bytes.withUnsafeMutableBytes { try buffer.read(into: $0) }
    XCTAssertEqual(count, 3)
    XCTAssertEqual(bytes, [7, 8, 9])
    finished.fulfill()
  }
  XCTAssertEqual(try buffer.append(Data([7, 8, 9]), at: 0), 3)
  wait(for: [finished], timeout: 1)
}

func testCancelWakesBlockedReader() {
  let buffer = YlByteRingBuffer(capacity: 8)
  let finished = expectation(description: "cancel wakes")
  DispatchQueue.global().async {
    var bytes = [UInt8](repeating: 0, count: 1)
    XCTAssertThrowsError(try bytes.withUnsafeMutableBytes { try buffer.read(into: $0) }) {
      XCTAssertEqual($0 as? YlByteSourceError, .cancelled)
    }
    finished.fulfill()
  }
  buffer.cancel()
  wait(for: [finished], timeout: 1)
}
```

- [ ] **Step 2: Run the test and verify RED**

Run the Task 1 XCTest command with `-only-testing:RunnerTests/YlByteRingBufferTests`.

Expected: compile failure because the buffer and protocol do not exist.

- [ ] **Step 3: Implement the buffer with one NSCondition**

Use one `NSCondition` to guard capacity, absolute `startOffset`, `readOffset`, byte storage, terminal error, EOF, and cancellation. `append` accepts only the current contiguous end offset and returns zero when full. `write` copies a large input incrementally and waits for consumer capacity instead of retaining a second full copy. `read` waits while empty and nonterminal, evicts bytes strictly before the retained rewind window when needed, and returns zero only after `finish` and drain. `seekWithinBuffer` succeeds only for `startOffset...endOffset`. Every terminal operation broadcasts exactly once and is idempotent.

- [ ] **Step 4: Run targeted tests and a 1,000-operation concurrency loop**

Add a deterministic test that alternates 1,000 producer chunks and consumer reads, then asserts byte equality, `bufferedBytes <= capacity` at every observation, and completion under five seconds. Run the targeted XCTest command.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlByteSource.swift \
  packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlByteRingBuffer.swift \
  packages/yl_player/example/ios/RunnerTests/YlByteRingBufferTests.swift \
  packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat: add bounded iOS network byte buffer"
```

### Task 3: FFmpeg custom AVIO bridge

**Files:**
- Modify: `packages/yl_player_ios/ios/native/YlFFmpegBridge/include/YlFFmpegBridge.h`
- Modify: `packages/yl_player_ios/ios/native/YlFFmpegBridge/YlFFmpegBridge.m`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlFFmpegBridgeTests.swift`
- Modify generated artifact: `packages/yl_player_ios/ios/yl_player_ios/Frameworks/YlFFmpegBridge.xcframework/**`
- Modify: `tool/ios_ffmpeg/test_build_contract.sh`

**Interfaces:**
- Produces: `YLFReadCallback`, `YLFSeekCallback`, `YLFCancelCallback`, and `ylf_open_callbacks` exactly as specified in the design.
- Adds bridge results `YLFResultCallbackFailed`, `YLFResultCallbackSeekUnsupported`, and `YLFResultCallbackCancelled`.
- Existing local open and packet interfaces remain source-compatible.

- [ ] **Step 1: Write failing callback-open tests**

In `YlFFmpegBridgeTests`, retain fixture bytes in a test box passed through `Unmanaged`, implement noncapturing read/seek/cancel thunks, and add:

```swift
func testCallbackInputReadsAndSeeksRealMkv() throws {
  let box = CallbackFixture(bytes: try Data(contentsOf: fixture("h264_aac")))
  var context: YLFMediaContextRef?
  var info = YLFMediaInfo()
  XCTAssertEqual(
    ylf_open_callbacks(box.opaque, fixtureRead, fixtureSeek, fixtureCancel,
                       &context, &info),
    YLFResultOK
  )
  defer { ylf_close(&context) }
  XCTAssertEqual(info.stream_count, 2)
  XCTAssertEqual(ylf_seek(context, 900_000), YLFResultOK)
  var packet: YLFPacketRef?
  XCTAssertEqual(ylf_read_packet(context, &packet), YLFResultOK)
  ylf_packet_release(&packet)
}
```

Also assert that close invokes cancel, a callback error maps distinctly, non-Matroska bytes return `YLFResultUnsupportedContainer`, and retained packets return the outstanding counter to zero.

- [ ] **Step 2: Run targeted XCTest and verify RED**

Run only `RunnerTests/YlFFmpegBridgeTests`.

Expected: compile failure because callback types and `ylf_open_callbacks` are absent.

- [ ] **Step 3: Implement shared open finalization and AVIO ownership**

Refactor common stream discovery into a private helper used by local and callback input. For callback input:

- allocate a 64 KiB `av_malloc` buffer and `avio_alloc_context`;
- implement FFmpeg read callback mapping positive counts, zero EOF, cancellation, and I/O errors;
- implement `SEEK_SET`, `SEEK_CUR`, `SEEK_END`, `AVSEEK_SIZE`, and mask `AVSEEK_FORCE`;
- set `format->pb`, `AVFMT_FLAG_CUSTOM_IO`, and the existing interrupt callback;
- call `av_probe_input_buffer2`/`avformat_open_input` with Matroska demux constrained;
- cancel before closing and free AVIO buffer/context exactly once.

Do not add FFmpeg network protocols or decoders.

- [ ] **Step 4: Rebuild the XCFramework and update the contract test**

Run:

```bash
sh tool/ios_ffmpeg/build_xcframework.sh
sh tool/ios_ffmpeg/test_build_contract.sh
```

Extend the contract test to assert the callback symbols in both device and Simulator slices and to continue rejecting network/GPL/nonfree/decoder flags.

- [ ] **Step 5: Run bridge tests and full XCTest**

Run the targeted bridge test, then `sh tool/check_native_ios.sh`.

Expected: all callback/local bridge tests pass and outstanding packets return to zero.

- [ ] **Step 6: Commit**

```bash
git add packages/yl_player_ios/ios/native/YlFFmpegBridge \
  packages/yl_player_ios/ios/yl_player_ios/Frameworks/YlFFmpegBridge.xcframework \
  packages/yl_player/example/ios/RunnerTests/YlFFmpegBridgeTests.swift \
  tool/ios_ffmpeg/test_build_contract.sh
git commit -m "feat: add FFmpeg callback media input"
```

### Task 4: HTTP policy, headers, redirects, and response validation

**Files:**
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlNetworkRequestPolicy.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlNetworkRequestPolicyTests.swift`
- Modify: `packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `YlNetworkRequestRecipe(url:headers:configuration:)`.
- Produces: `YlNetworkRequestPolicy.request(offset:validator:)`, `redirectRequest(from:response:to:)`, and `validate(response:requestedOffset:)`.
- Produces: `YlNetworkResponseMetadata` containing `responseStart`, `resourceLength`, `supportsRandomAccess`, `etag`, and `lastModified`.

- [ ] **Step 1: Write failing policy tests**

Assert generated `Range: bytes=0-`, caller Range override, 206 Content-Range validation, offset-zero 200 sequential mode, nonzero 200 rejection, exact-length 416 EOF, redirect count, scheme validation, and header security:

```swift
func testCrossOriginRedirectStripsCredentials() throws {
  let policy = makePolicy(headers: [
    "Authorization": "Bearer secret", "Cookie": "sid=secret",
    "Proxy-Authorization": "Basic secret", "User-Agent": "TVBox",
  ])
  let redirected = try policy.redirectRequest(
    from: URL(string: "https://a.test/movie.mkv")!,
    response: httpResponse(status: 302),
    to: URL(string: "https://cdn.test/movie.mkv")!
  )
  XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"))
  XCTAssertNil(redirected.value(forHTTPHeaderField: "Cookie"))
  XCTAssertNil(redirected.value(forHTTPHeaderField: "Proxy-Authorization"))
  XCTAssertEqual(redirected.value(forHTTPHeaderField: "User-Agent"), "TVBox")
}
```

- [ ] **Step 2: Run targeted XCTest and verify RED**

Expected: compile failure for the policy types.

- [ ] **Step 3: Implement pure request/response policy**

Keep this file free of URLSession task ownership so every security rule is pure-testable. Normalize header comparisons case-insensitively, remove URL query/fragment from diagnostics, allow only HTTP/HTTPS redirects, enforce `maxRedirects`, construct `If-Range`, parse Content-Range without integer overflow, and map errors to the exact stable codes in the spec.

- [ ] **Step 4: Run policy and router tests**

Run only `YlNetworkRequestPolicyTests` and `YlSourceRouterTests`.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlNetworkRequestPolicy.swift \
  packages/yl_player/example/ios/RunnerTests/YlNetworkRequestPolicyTests.swift \
  packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat: define secure iOS MKV HTTP policy"
```

### Task 5: URLSession-backed byte source with retry and cancellation

**Files:**
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlNetworkByteSource.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlNetworkByteSourceTests.swift`
- Modify: `packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `YlNetworkByteSource: NSObject, YlByteSource, URLSessionDataDelegate, URLSessionTaskDelegate`.
- Consumes: `YlByteRingBuffer`, `YlNetworkRequestPolicy`, and `YlNetworkConfiguration`.
- Produces retry callback `(attempt: Int, delayMs: Int64, error: NativePlayerError) -> Void`.

- [ ] **Step 1: Write a deterministic URLProtocol harness and failing tests**

The harness records requests and scripts response headers, chunks, delays, and failures. Tests must cover:

```swift
func testPartialFailureResumesAtExactOffsetWhenRangeWasConfirmed() throws {
  let source = makeSource(scripts: [
    .response(status: 206, headers: ["Content-Range": "bytes 0-5/12"],
              chunks: [Data([0, 1, 2, 3, 4, 5])], failure: .networkConnectionLost),
    .response(status: 206, headers: ["Content-Range": "bytes 6-11/12"],
              chunks: [Data([6, 7, 8, 9, 10, 11])]),
  ])
  var output = [UInt8](repeating: 0, count: 12)
  let count = try output.withUnsafeMutableBytes { try source.read(into: $0) }
  XCTAssertEqual(count, 12)
  XCTAssertEqual(output, Array(0...11))
  XCTAssertEqual(recordedRequests[1].value(forHTTPHeaderField: "Range"), "bytes=6-")
}
```

Also test sequential 200 EOF, no retry after partial sequential failure, read timeout reset after each chunk, retry exhaustion, 408/429/5xx eligibility, cancellation waking a blocked read, validator change rejection, capacity never exceeded, and sensitive-data-free diagnostics.

- [ ] **Step 2: Run targeted XCTest and verify RED**

Expected: compile failure because `YlNetworkByteSource` is absent.

- [ ] **Step 3: Implement the URLSession state machine**

Use a private serial delegate queue distinct from the FFmpeg worker. Guard active task, attempt, requested offset, response metadata, validator, terminal state, and timer generation with one lock. Feed chunks through blocking `YlByteRingBuffer.write`, which copies each callback chunk incrementally without exceeding the ring ceiling; the serial delegate queue naturally applies backpressure while full. Use generation-tagged `DispatchSourceTimer` instances for connect/read deadlines and retry delay. Every callback verifies source generation before mutation.

On transient failure, reconnect only at the exact contiguous end offset and only after a 206 established random access. Emit retry before scheduling. On cancel, cancel task/timers/session, broadcast the ring, and prevent future retries. Make `cancel` idempotent.

- [ ] **Step 4: Run targeted tests under Thread Sanitizer configuration**

Run the normal targeted XCTest command. Then run the same test class with `-enableThreadSanitizer YES` and assert zero races, hangs, or timeout failures.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlNetworkByteSource.swift \
  packages/yl_player/example/ios/RunnerTests/YlNetworkByteSourceTests.swift \
  packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat: stream bounded network MKV bytes"
```

### Task 6: Unified media-input ownership and network preflight

**Files:**
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlOpenedMedia.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackBackend.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlAudioRenderer.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlOpenedMediaTests.swift`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlFallbackBackendTests.swift`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlAudioRendererTests.swift`
- Modify: `packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `YlFallbackSourceRecipe.local(path:)` and `.network(request:)`.
- Produces: `YlOpenedMedia` that owns `YLFMediaContextRef` plus optional `YlByteSource`, closes the context before releasing the source, and exposes `seek(toMediaTimeUs:)`.
- Changes: `YlPreparedFallback` owns/takes `YlOpenedMedia` and retains its source recipe for lifecycle rebuild.

- [ ] **Step 1: Write failing ownership and budget tests**

Use a callback fixture byte source to assert network open returns the same stream metadata as local open, callback source outlives the C context, close cancels exactly once, and 100 open/read/close cycles leave the bridge packet counter at zero. Add audio tests proving `maxScheduledBytes` comes from `YlFallbackBufferBudget` and oversized PCM returns `.wouldExceedBytes` before scheduling.

- [ ] **Step 2: Run targeted tests and verify RED**

Run `YlOpenedMediaTests`, `YlFallbackBackendTests`, and `YlAudioRendererTests`.

Expected: compile failures for the recipe/opened-media APIs and failed budget injection assertion.

- [ ] **Step 3: Implement Swift callback thunks and opened-media lifetime**

Use a retained Swift box owned by `YlOpenedMedia`; pass it unretained to noncapturing C-compatible thunks. The read thunk maps `YlByteSourceError.cancelled` distinctly and never lets Swift errors cross C. The seek thunk handles `AVSEEK_SIZE`, cached-window seeks, and range seeks. `close()` first calls `ylf_close`, which invokes the source cancellation callback while the box is alive, then releases the box.

Refactor local open through the same `YlOpenedMedia` owner without changing local behavior. Inject budget ceilings into `YlAudioRenderer`; reject an in-flight compressed packet larger than `inFlightPacketBytes` before video/audio conversion.

- [ ] **Step 4: Run targeted tests and all fallback XCTest**

Expected: ownership, 100-cycle, audio budget, local fallback, seek, and lifecycle tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios \
  packages/yl_player/example/ios/RunnerTests \
  packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat: unify local and network MKV media ownership"
```

### Task 7: Asynchronous atomic open and stale-generation cancellation

**Files:**
- Create: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlOpenCoordinator.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlIosPlayer.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlPlayerIosPlugin.swift`
- Create: `packages/yl_player/example/ios/RunnerTests/YlOpenCoordinatorTests.swift`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlFallbackBackendTests.swift`
- Modify: `packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `YlPreparedOpen` cases `.avPlayer(source:)` and `.fallback(source:prepared:)`, with `discard()` releasing candidate resources.
- Produces: `YlOpenCancellationToken` with `isCancelled`, `onCancel(_:)`, `throwIfCancelled()`, and idempotent `cancel()`.
- Produces: `YlOpenCoordinator.begin(prepare:commit:completion:) -> UInt64`, `cancelCurrent()`, monotonic generation, one serial preparation queue, and exactly-once main-queue completion. `prepare` receives `YlOpenCancellationToken`; `commit` receives `YlPreparedOpen`; completion is `Result<Void, NativePlayerError>`.
- Changes: plugin `open` keeps `FlutterResult` pending and performs peer deactivation/backend commit only after candidate success.
- All non-open commands retain the current synchronous channel behavior.

- [ ] **Step 1: Write failing coordinator tests**

Assert preparation is not on main, successful candidates commit on main, second open cancels first, dispose completes a pending open with `network.cancelled`, late completions cannot replace a backend, candidate failure preserves the active backend, and every Flutter-style completion is called once.

```swift
func testSecondOpenCancelsFirstAndOnlyNewestCommits() {
  let first = BlockingCandidate()
  let second = ImmediateCandidate(id: 2)
  coordinator.begin(prepare: { first.wait() }, commit: recordCommit, completion: recordFirst)
  coordinator.begin(prepare: { second }, commit: recordCommit, completion: recordSecond)
  first.release()
  waitForCompletions()
  XCTAssertEqual(committedIds, [2])
  XCTAssertEqual(first.cancelCount, 1)
  XCTAssertEqual(firstCompletionCount, 1)
  XCTAssertEqual(secondCompletionCount, 1)
}
```

- [ ] **Step 2: Run targeted tests and verify RED**

Expected: compile failure for `YlOpenCoordinator` and old synchronous open behavior.

- [ ] **Step 3: Implement coordinator and asynchronous plugin flow**

Move preparation off the main thread for network fallback. Return to main to revalidate player/generation, deactivate peers, activate/replace the candidate, and resolve the method result. Cancellation caused by replacement/dispose returns `network.cancelled` to that invocation but does not emit persistent error state. Keep AVPlayer and local-MKV opens behavior-compatible; they may use immediate candidates on the same commit path.

- [ ] **Step 4: Run coordinator, backend, and Dart adapter tests**

Run targeted XCTest plus `flutter test packages/yl_player_ios` from repository root.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios \
  packages/yl_player/example/ios/RunnerTests \
  packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat: prepare iOS network MKV asynchronously"
```

### Task 8: Network seek, retry events, and lifecycle rebuild

**Files:**
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlFallbackBackend.swift`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlNetworkByteSource.swift`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlFallbackLifecycleTests.swift`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlFallbackBackendTests.swift`
- Modify: `packages/yl_player/example/ios/RunnerTests/YlNetworkByteSourceTests.swift`

**Interfaces:**
- Consumes: `YlFallbackSourceRecipe` to rebuild local or network media.
- Emits existing state/event schema with `isSeekable`, `bufferedPositionMs`, `retry`, and stable network errors.
- Preserves ordered seek transaction and independent video/audio post-seek gates.

- [ ] **Step 1: Write failing lifecycle tests**

Assert Range-capable network seek issues a new request and follows the existing transaction order; sequential source publishes `isSeekable=false` and rejected seek preserves position/backend; background cancels the active task and drops buffers; foreground Range rebuild starts at saved media time; sequential rebuild starts at byte zero paused; memory warning shrinks the cache to 2 MiB; retry event payload contains attempt/delay but no sensitive URL/header data.

- [ ] **Step 2: Run targeted tests and verify RED**

Expected: state/sequence assertions fail because backend rebuild is local-only and network retry events are not connected.

- [ ] **Step 3: Generalize backend rebuild and seek**

Replace `sourcePath` reopening with `sourceRecipe.open`. Use the opened media's random-access property for state. Map public sequential seek to `network.range_not_supported` before pausing or clearing anything. On Range seek, keep the exact existing transaction and make the AVIO byte seek occur inside `ylf_seek`. Connect retry callback to a generation-checked event envelope. On background/memory warning, cancel network work before releasing context/decoder/audio; restore normal budget only on foreground reconstruction.

- [ ] **Step 4: Run all network/fallback XCTest and native gate**

Run targeted classes, then `sh tool/check_native_ios.sh`.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios \
  packages/yl_player/example/ios/RunnerTests
git commit -m "feat: complete iOS network MKV lifecycle"
```

### Task 9: Flutter loopback network-MKV integration

**Files:**
- Create: `packages/yl_player/example/integration_test/ios_network_mkv_playback_test.dart`
- Create: `packages/yl_player/example/integration_test/support/range_media_server.dart`
- Modify: `packages/yl_player/example/ios/Runner/Info.plist`
- Modify: `tool/check_native_ios.sh`
- Modify: `packages/yl_player/.pubignore`

**Interfaces:**
- Produces a loopback HTTP fixture server supporting scripted 206, 200, redirects, statuses, disconnects, and request recording.
- Adds the network-MKV suite to the one-command native gate.

- [ ] **Step 1: Write the failing integration tests**

Create tests that copy existing bundled MKV bytes into the server and assert:

```dart
testWidgets('HTTP range MKV uses the native fallback', (tester) async {
  final server = await RangeMediaServer.start(asset: 'h264_aac.mkv');
  addTearDown(server.close);
  final controller = YlPlayerController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(MaterialApp(home: YlPlayerView(controller: controller)));
  try {
    await controller.open(YlMediaSource.network(
      server.mediaUri,
      formatHint: YlFormatHint.matroska,
      headers: const {'X-Yl-Test': 'network-mkv'},
    ));
  } on YlPlayerError catch (error) {
    expect(error.code, 'decoder.video_hardware_unavailable');
    expect(error.category, YlPlayerErrorCategory.decoderUnsupported);
    return;
  }
  await controller.play();
  await controller.events.whereType<YlFirstFrameEvent>().first.timeout(
    const Duration(seconds: 15),
  );
  expect(controller.state.engine, YlPlaybackEngine.nativeFallback);
  expect(controller.state.isHardwareDecoding, isTrue);
  expect(server.requests.first.headers.value('x-yl-test'), 'network-mkv');
});
```

On a Simulator runtime that provides hardware decode, continue with seek and two-track selection. Otherwise require the exact hardware-unavailable category/code. Add sequential-server state/seek and failed-candidate-preserves-HLS tests.

- [ ] **Step 2: Run integration and verify RED**

Run:

```bash
cd packages/yl_player/example
flutter test integration_test/ios_network_mkv_playback_test.dart \
  -d "$YL_IOS_SIMULATOR_ID"
```

Expected: network Matroska open fails because the route/backend is not yet connected, or ATS rejects loopback before the scoped exception is added.

- [ ] **Step 3: Implement the deterministic loopback server and scoped ATS rule**

Implement byte-range parsing and exact `Content-Range` responses in Dart. Bind only to loopback and add only `NSAllowsLocalNetworking=true` for integration use; do not add arbitrary-load exceptions. Exclude fixture/test-server material from publication archives.

- [ ] **Step 4: Add the test to the native gate and run GREEN**

Append the network suite to `tool/check_native_ios.sh`, run it, and require XCTest plus HLS/local-MKV/network-MKV suites to pass.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player/example/integration_test \
  packages/yl_player/example/ios/Runner/Info.plist \
  packages/yl_player/.pubignore tool/check_native_ios.sh
git commit -m "test: cover iOS network MKV VOD"
```

### Task 10: Automated release truth and publication validation

**Files:**
- Modify: `packages/yl_player/README.md`
- Modify: `packages/yl_player/CHANGELOG.md`
- Modify: `packages/yl_player_ios/README.md`
- Modify: `packages/yl_player_ios/CHANGELOG.md`
- Modify: `docs/verification/ios-mkv-device-matrix.md`
- Modify: `docs/superpowers/plans/2026-09-03-ios-network-mkv-vod.md`

**Interfaces:**
- Documents experimental automated support without claiming deferred device performance.
- Produces a clean, publishable four-package tree; no real publication occurs.

- [ ] **Step 1: Run the final automated gate**

Run:

```bash
sh tool/check_foundation.sh
sh tool/check_native_ios.sh
cd packages/yl_player/example
flutter build apk --debug
flutter build ios --simulator --debug
```

Expected: all commands exit zero; HLS, local MKV, and network MKV integrations pass without routing network MKV to AVPlayer.

- [ ] **Step 2: Add measured automated truth to documentation**

Document only these claims: experimental HTTP/HTTPS MKV VOD, local/remote
H.264/H.265 + AAC codec boundary, required hardware decode, 4/8/16 MiB network
cache profiles, custom managed-media budget, Range-dependent seek, credential
redirect policy, no persistent cache, and deferred physical-device evidence.
Keep live MKV, HTTP-FLV fallback, subtitles, DRM, and non-AAC audio unsupported.

- [ ] **Step 3: Commit documentation**

```bash
git add packages/yl_player packages/yl_player_ios docs
git commit -m "docs: describe experimental iOS network MKV VOD"
```

- [ ] **Step 4: Run clean publication checks**

Run:

```bash
dart pub -C packages/yl_player_platform_interface publish --dry-run
dart pub -C packages/yl_player_android publish --dry-run
dart pub -C packages/yl_player_ios publish --dry-run
dart pub -C packages/yl_player publish --dry-run
git diff --check
git status --short
```

Expected: four zero-warning dry runs, no diff errors, and a clean worktree. Do not push or run a real publication command.
