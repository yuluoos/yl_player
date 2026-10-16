# P03 格式与受控解码续做 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 延续当前会话自行实施方式；任务间不启动实现子代理，全部工程改动后做一次独立复核。

**Goal:** 补齐 P03 已确认格式的实际播放链与必要依赖，实现真实解码身份和可执行的软件预算，完成当前环境验证并明确外部验收边界。

**Architecture:** 原生硬件优先，软件候选复用现有网络、音频、时钟和像素输出。裁剪 FFmpeg/dav1d 只增加有测试素材的模块。软件资源接口与测量准入独立于媒体加载；所有候选/当前资源共同计量，未测设备不自动准入。

**Tech Stack:** Dart/Flutter、Swift/CoreMedia/VideoToolbox、FFmpeg C/Objective-C、dav1d、Kotlin/Media3/MediaCodec/JNI、Python 证据工具。

**Spec:** [2026-10-14-p03-completion-design.md](../specs/2026-10-14-p03-completion-design.md)，2026-10-14 用户已批准；原始要求见 [P03](2026-09-26-remaining-03-formats-decoding.md)。

设计提交 `cfa09ed`；实现前重新记录 HEAD 与工作区。本文是待审阅的执行计划，复核通过不等于已实现。

## Global Constraints

- Android API 24、iOS 15、macOS 12 部署下限不变；只用系统 API 与固定开源依赖，不用商业 SDK。
- 保留 PD-01/02/03、固定画质与独立 caps、完整 FEL；不以降位深、降动态范围、丢 film grain 或换低档掩盖解码失败。
- managed 的 deadline/凭据/取消/重试和 bounded 的字节账本真实执行；不能执行时明确拒绝。
- 每次创建及重建验证实际解码身份。`hardwareRequired` 不创建软件候选，unknown 不算 hardware。
- 工程完成、受控实播、设备准入、物理输出分别记录；没有合格数据的生产软件档位保持关闭。
- 原生平台一次一个；避开另一会话长播放、弱网 ABR、P05，不修改 `tool/playback_benchmark/`。
- 显式文件清单暂存，本地 commit，不 push。共享 checkout 上有其他改动则保留；不得全仓 reset/clean。
- 不再让目录匹配测试把已知失败计成支持；原有效失败、损坏拒绝和未测行都保留。

## Review Focus

1. 非零 Vorbis delay、首块 overlap、尾裁剪与回零 seek 组合：不能重复丢样本或把预解码音频提前播放（Task 1）。
2. 已知错误扩展名、无索引 PS、截断包和长时间戳 wrap：探测不依赖后缀，seek 不能只恢复 position（Task 2/7）。
3. 候选与当前 decoder 共存、多播放器争用及迟到回调：资源不漏记，旧帧不进入当前输出（Task 3/5）。
4. 高位深、superframe/隐藏帧、film grain、配置在中途变化：不因首个包可解而接受未经计量的新配置（Task 4/5）。
5. OS/依赖版本变化、未知热状态、进程被其他工作占用：旧测量不能自动准入新组合，不能把外层线程计量冒充全部 decode CPU（Task 3/8）。

## 文件边界与通用验证

以下目录缩写仅用于正文；Files 块使用完整仓库相对路径：Apple shared 为 `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared`；canonical XCTest 为 `tool/consumer_fixtures/apple_flutter/RunnerTests`。

新增 Apple 单元测试先放 canonical，再将新文件同步到 example 的 iOS/macOS RunnerTests，更新 `new-tests-manifest.json` 和 `main_example_tests.py` 的测试清单。不得整目录覆盖已有三份 macOS 历史差异。通过测试发现检查确认新方法实际进入 XCTest；编译通过不算执行。

Apple 定向 XCTest：优先 XcodeBuildMCP `session_show_defaults` 后调用测试工具，传入 `-only-testing:RunnerTests/<ClassName>`，两个平台串行。工具不提供当前 macOS 工作流时可用下列已存在脚本执行完整 native 单测；结果日志与 xcresult 都保留：

```sh
sh tool/check_native_macos.sh --unit-only
YL_IOS_SIMULATOR_ID=D121C2CF-D823-48F7-816E-092BCB8A780C sh tool/check_native_ios.sh --unit-only
```

脚本的失败先区分测试失败与既有生成文件/测试镜像差异，不能改掉断言使其通过。涉及原生构建的写缓存/SDK/设备操作依照沙箱机制申请执行；不改共享 SDK。

## Task 1: Vorbis delay 与参考样本

**Files:**
- Modify: `packages/yl_player_apple/darwin/native/YlFFmpegBridge/YlVorbisBridge.inc`
- Modify: `packages/yl_player_apple/darwin/native/YlFFmpegBridge/YlFFmpegBridge.m`
- Modify: `packages/yl_player_apple/darwin/native/YlFFmpegBridge/include/YlFFmpegBridge.h`
- Modify: `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Audio/YlVorbisAudioConverter.swift`
- Modify: `packages/yl_player_apple/tool/apple_ffmpeg/test_vorbis.m`, `test_vorbis.sh`
- Create: `tool/consumer_fixtures/apple_flutter/RunnerTests/YlVorbisDelayTests.swift`
- Modify: `packages/yl_player/example/integration_test/format_matrix_test.dart`

**Interfaces:** Consume existing `ylf_stream_vorbis_preroll_us`, `ylf_packet_audio_trim` and `ylf_vorbis_decode`. Preserve their ABI; header comments must state which layer owns overlap/delay/DiscardPadding. Produce delay-aware PCM/timestamps with the existing `YlScheduledAudioBuffer` output type.

- [x] Extend the real bridge test to select the Vorbis stream by codec rather than assuming index 0; add the existing WebM/Vorbis and `mkv-avc-vorbis-codec-delay.mkv` fixtures. Write the first failing assertion before changing production:

```c
CHECK(ylf_stream_vorbis_preroll_us(context, audio_index) >= 200000);
CHECK(ylf_packet_audio_trim(packet, &skip, &discard) == YLFResultOK);
```

- [x] Run `sh packages/yl_player_apple/tool/apple_ffmpeg/test_vorbis.sh` with its documented `YL_TEST_FFMPEG_BUILD` and `YL_TEST_VORBIS_REFERENCE` pointing to freshly verified retained source/reference builds. Expected RED: the nonzero-delay stream returns -1/rejects trim, while the zero-delay controls pass. Keep source and current-artifact results separate.
- [x] Verify the pinned demuxer's timestamp subtraction and first overlap behavior against Xiph. Extend reference assertions to compare every returned PCM block, the first audible sample time, total frames, tail trim and seek at 0/1.25/2 s. The expected relationship is:

```text
presentation timestamp = already-demuxed packet timestamp + actual leading PCM trim
container CodecDelay is not subtracted a second time
negative/preroll PCM is decoded but not presented
```

  Test 44.1/48 kHz mono/stereo, valid nonzero delay, overflow/excessive delay, malformed header and leading/tail trim across block boundaries. If a leading trim spans blocks, account for the remainder rather than requiring it to fit the first priming block.
- [x] Implement the smallest accepted timestamp profile. Keep first-overlap discard in decoder and explicit container trim in one owner. Remove “zero CodecDelay” messages only for validated rows. Extend actual Swift converter/seek/cold-switch tests so a double delay causes missing PCM/timestamp assertion failures.
- [x] Expected GREEN: source bridge/reference comparisons and `YlVorbisDelayTests` pass; later candidate artifact tests must pass identically. Run the WebM/Vorbis file/http/renamed tests using `--plain-name webm-vp9-vorbis` with strict support. Record current artifact rejection until Task 2 installs the candidate; don't claim a source-only bridge changed product playback.
- [x] Combine the bridge changes with Task 2's minimal demux candidate to avoid rebuilding the same five slices twice; commit after artifact and real playback validation, not after source-only tests.

## Task 2: MPEG-PS、内容探测和旧系统路由

**Files:**
- Modify: `tool/media_matrix/generate.py`, `cases.json`, `catalog.py`, `test_catalog.py`
- Modify: `packages/yl_player/example/assets/test_media/format_matrix/` (explicit new fixture, catalog/probe/hash files only)
- Modify: `packages/yl_player_apple/tool/apple_ffmpeg/build_xcframework.sh`, `test_build_contract.sh`, `test_video_metadata.sh`
- Modify: `packages/yl_player_apple/darwin/native/YlFFmpegBridge/YlFFmpegBridge.m`
- Modify: `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/SourceRouting/YlSourceInspector.swift`, `YlEngineRouter.swift`
- Modify: `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Dependencies/YlFallbackContainer.swift`
- Modify: `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/FFmpeg/YlPreparedFallback.swift`
- Create: `tool/consumer_fixtures/apple_flutter/RunnerTests/YlProgramStreamTests.swift`
- Modify: route dispatch/exhaustive enum consumers found by `rg 'case \.mpegTs|\.transportStream' packages/yl_player_apple/darwin`

**Interfaces:** Add `.mpegPs` to the internal fallback container and the corresponding internal route; public `YlSourceFormat.mpegPs` already exists. Existing `ylf_open_callbacks` remains the only network demux input. Preserve zero-based presentation/seek API.

- [x] Generate one owned PS/AVC/MP3 clip from the established four color/tone markers using explicit `-f mpeg -c:v libx264 -g 24 -bf 0 -c:a mp3`; independently probe codec IDs and decode markers before adding its exact bytes/hash. If muxing fails, retain failure and produce the combination with another open-source muxer rather than replacing the test with MPEG-2 success. Original MPEG-2 row stays diagnostic.
  Add a catalog field `supportRequirement` with `required` for REQ-10 combinations and `diagnostic` for the original MPEG-2 probe, matching the pre-existing README's explicit exclusion of MPEG-2 video. The validator pins that distinction: required H.264/HEVC/VP9/AV1 cases cannot be relabelled to evade strict acceptance. Diagnostic rows still run and retain their original failure outcome, but are neither required-support successes nor silently omitted rows.
- [x] Add signature/route tests and execute RED:

```swift
XCTAssertEqual(YlSourceInspector.format(Data([0, 0, 1, 0xba, 0x44, 0, 4, 0, 4, 1, 0, 0])), .mpegPs)
XCTAssertEqual(YlSourceInspector.format(Data([0, 0, 1])), .automatic)
```

  The final signature validator must check a complete pack header, not accept arbitrary start-code prefixes. Cover MPEG-1 and MPEG-2 pack syntax, marker-bit errors, truncated lengths and excessive stuffing.
- [x] Extend content inspection to wrong *known* extensions as well as `.bin`, retaining managed credentials/deadlines. Inspect bounded bytes before committing a container route. Reuse owned MP4/sample playback when the lower OS cannot honor MIME; preserve a precise unsupported result where a route is not implemented.
- [x] Enable only `mpeg` demux and parser modules required by the owned clip; use PS clock origin, wrap handling and existing finite seek scanning. Add actual file/custom-AVIO tests for no index, nonzero origin, seek failure, cancellation and truncated packet. Expected output after seek is the fixture's target color/PCM, not merely advanced position.
- [x] Build and independently rebuild one candidate including Task 1:

```sh
YL_KEEP_FFMPEG_BUILD=1 sh packages/yl_player_apple/tool/apple_ffmpeg/build_xcframework.sh --build-candidate /private/tmp/yl-p03-container-candidate
sh packages/yl_player_apple/tool/apple_ffmpeg/build_xcframework.sh --rebuild-check /private/tmp/yl-p03-container-candidate
```

  Use a fresh numbered directory if it already exists. Expected: five targets, identical complete artifact manifests, disabled network/GPL/nonfree, license and source pins verified. Copy only the verified candidate framework/lock into their canonical paths; rerun build contract, metadata, full audio bridge tests.
- [x] Run `YlProgramStreamTests` and affected route suites on macOS then iOS; strict PS/AVC and Vorbis integration on available platforms. `hardwareRequired`, managed and bounded each get actual success or a specific tested rejection. Commit this coherent container/audio slice with explicit paths and evidence.

## Task 3: 软件描述、准入与共享预算

**Files:**
- Create: `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/VideoToolbox/YlSoftwareDecodeAdmission.swift`
- Create: `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/VideoToolbox/YlSoftwareDecodeBudget.swift`
- Create: `tool/consumer_fixtures/apple_flutter/RunnerTests/YlSoftwareDecodeBudgetTests.swift`
- Create: `tool/decoder_probe/software_evidence.py`, `test_software_evidence.py`

**Interfaces:** Define these internal value types before wiring a decoder:

```swift
struct YlSoftwareDecodeKey: Hashable, Codable {
  let model: String; let osBuild: String; let decoderBuild: String
  let codec: Int32; let profile: Int32; let bitDepth: Int; let chroma: Int
  let width: Int; let height: Int; let fpsNumerator: Int; let fpsDenominator: Int
  let threads: Int; let outputPixelFormat: UInt32
}
struct YlSoftwareDecodeLimits: Codable {
  let maxOwnedBytes: Int; let maxFrames: Int; let maxPacketBytes: Int
  let windowNs: UInt64; let maxCpuNs: UInt64; let maxDecodeWallNs: UInt64
}
struct YlSoftwareDecodeObservation {
  let monotonicNs: UInt64; let cumulativeCpuNs: UInt64
  let decodeWallNs: UInt64; let thermalNominal: Bool?
}
```

  `YlSoftwareDecodeAdmission.limits(for: YlSoftwareDecodeKey) -> YlSoftwareDecodeLimits?` consumes only measured manifest entries, initially none. `YlSoftwareDecodeBudget.reserve(bytes:frames:) throws -> Token`, `observe(_:) throws`, `Token.release()` enforce accounting; a process-level pool issues decoder leases so current/candidate/player overlap shares a ceiling. Public errors remain existing `decoder.unavailable`/`resource.exhausted` mappings.

- [x] Write tests that observe rejected unknown device/build, zero/unknown fps, overflowed dimensions, negative/nonmonotonic counters, missing thermal data, shared pool exhaustion, double release and old-generation release. Example test sequence:

```text
profile maxOwnedBytes=100, maxFrames=2 (synthetic test values only)
current reserve(60,1) -> success
candidate reserve(60,1) -> resource.exhausted, current stays charged
current release twice -> exactly zero
candidate reserve(60,1) -> success; teardown -> zero
```

- [x] Execute RED via the focused native class and `python3 -B -m unittest discover -s tool/decoder_probe -p 'test_software_evidence.py'`. Expected failure is missing admission/accounting behavior; fix harness/import errors before counting RED.
- [x] Implement checked arithmetic, idempotent lifetime tokens and a locked shared pool. Charge decoded/reference/output ownership separately from compressed queue tokens; do not reset a pool while old resources own tokens. Process/thermal failures cancel the admitted session; single C decode cannot be preempted, so report only bounded between-call enforcement.
- [x] Implement strict evidence validation: exact protocol and build/fixture hashes, all planned runs present, no failed/skipped runs, known consistent environment, actual decoded output markers, unit/range validation, independent verification run. Debug/simulator and short-only thermal evidence cannot generate production profiles.
- [x] Expected GREEN: all focused cases pass; no production profile appears as a side effect of testing. Commit contracts/accounting with API unit/ownership comments.

## Task 4: 最小软件桥接与 AV1 配置

**Files:**
- Create: `packages/yl_player_apple/darwin/native/YlFFmpegBridge/YlSoftwareVideoBridge.inc`
- Modify: `packages/yl_player_apple/darwin/native/YlFFmpegBridge/YlFFmpegBridge.m`, `include/YlFFmpegBridge.h`
- Create: `packages/yl_player_apple/tool/apple_ffmpeg/dav1d.lock`, `test_software_video.m`, `test_software_video.sh`
- Modify: `packages/yl_player_apple/tool/apple_ffmpeg/build_xcframework.sh`, `test_build_contract.sh`
- Create: `packages/yl_player_apple/LICENSES/dav1d-BSD.txt`
- Modify: `tool/decoder_probe/fixtures/manifest.json` and explicitly added owned configuration/packet fixtures

**Interfaces:** Add stable AV1 codec ID after existing IDs without renumbering. Clone configuration into an independently owned decoder; no retained raw pointer to a closed demux context. C contract:

```c
typedef struct YLFSoftwareVideoDecoder *YLFSoftwareVideoDecoderRef;
typedef struct {
  uint64_t max_owned_bytes;
  uint32_t max_frames, max_packet_bytes, threads;
} YLFSoftwareVideoLimits;
int32_t ylf_software_video_create(YLFMediaContextRef context, int32_t stream,
  YLFSoftwareVideoLimits limits, YLFSoftwareVideoDecoderRef *out_decoder);
int32_t ylf_software_video_send(YLFSoftwareVideoDecoderRef decoder, CMSampleBufferRef sample);
int32_t ylf_software_video_receive(YLFSoftwareVideoDecoderRef decoder,
  CVPixelBufferRef *out_retained_image, CMTime *out_pts, CMTime *out_duration);
int32_t ylf_software_video_finish(YLFSoftwareVideoDecoderRef decoder);
void ylf_software_video_reset(YLFSoftwareVideoDecoderRef decoder);
void ylf_software_video_free(YLFSoftwareVideoDecoderRef decoder);
```

  Declare CoreVideo explicitly. `OK` requires non-null owned output, a new distinct `WouldBlock` result means more input is needed, `EOF` means drain complete. Document null handling, stream/profile rejection, returned buffer ownership and single serialized caller. Frame storage remains charged until final pixel-buffer release, including after decoder destruction.

- [x] Write bridge RED tests using owned AV1 Main8/Main10 and VP9 fixtures: exact frame count, independent decoded color/plane samples, PTS and drain; malformed config, huge geometry, oversized packets, reset/cancel and allocation failure. Actual codec/frames must cause assertions to fail before enabling dependencies.
- [x] Pin a reviewed stable dav1d source tarball, SHA-256 and COPYING; record retrieval source and configure flags. Build static, decoder-only dependency for the same five Apple targets. Enable `libdav1d`, required AV1 parser and VP9 native software decoder only; preserve disabled network/encoders/GPL/nonfree. Add new source/license/lock inputs to artifact manifests.
- [x] Implement `avcodec_send_packet`/`receive_frame` draining, explicit thread/size limits and bounded frame allocation; preserve packet PTS and full bit depth/color metadata. Copy/convert planes only with checked strides and counted destination allocation; do not use an unbounded scaler. Reject midstream config changes until an explicit reconfiguration transaction admits them.
- [x] Implement AV1 sequence/config validation and `av1C` CM format construction for VT. Register supplemental decoder only at supported OS availability; feature detection is a hint, actual session property remains authoritative. Compare native hardware probe/control before product routing.
- [x] Build candidate and independent rebuild in a fresh `yl-p03-video-candidate` directory using Task 2 commands with the new path. Expected GREEN: bridge independent reference, AV1 metadata, all prior audio/FEL checks and complete artifact equality. Install only verified candidate; commit source/locks/licenses/artifact together.

## Task 5: Apple 解码资源接入与生命周期

**Files:**
- Create: `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/VideoToolbox/YlVideoDecoderResource.swift`, `YlSoftwareVideoDecoder.swift`
- Modify: `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/VideoToolbox/YlVideoPipeline.swift`, `YlVideoToolboxDecoder.swift`, `YlHardwareDecoderEvidence.swift`
- Modify: `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/FFmpeg/YlPreparedFallback.swift`
- Create: `tool/consumer_fixtures/apple_flutter/RunnerTests/YlSoftwareVideoLifecycleTests.swift`
- Modify: affected ordinary fallback and DASH decoder preparation/rebuild consumers identified by `rg 'YlVideoToolboxDecoder|makeDecoder' packages/yl_player_apple/darwin/yl_player_apple/Sources`

**Interfaces:** Preserve the existing VT testing protocol and add a resource protocol rather than broadly renaming unrelated mocks:

```swift
protocol YlVideoDecoderResource: YlVideoToolboxDecoding {
  var hardwareEvidence: YlHardwareDecoderEvidence { get }
  var usesHardwareDecoder: Bool { get }
  func reserveSubmission(byteCount: Int, shouldCancel: () -> Bool) throws -> YlVideoDecodeReservation?
}
```

  VT and software conform; `YlVideoPipeline.Resource.ordinary` stores the resource interface. Existing sample, output callback and `YlVideoFrame` types remain stable. FEL remains its own resource. Software budget tokens accompany actual frame ownership, independent of compressed `YlVideoDecodeReservation`.

- [x] Write focused RED tests for actual software candidate decode, observed software identity, hardwareRequired never invoking software factory, failed candidate preserving current playback, seek/Period reset draining generations, current+candidate budget and teardown.
- [x] Replace concrete ordinary decoder parameters in pipeline submission/drain with the resource interface. Keep the tracked submission queue and all generation checks. The factory order is:

```text
validate configuration/output -> try hardware candidate -> verify actual evidence
hardwareRequired: no proven hardware => decoder.unavailable
otherwise: software admission lookup -> acquire shared lease -> create software
unknown profile or missing lease => explicit failure, no quality mutation
```

- [x] Feed bridge outputs through the existing video scheduler with preserved PTS/color. Implement drain/reset/dispose and callback lifetime tests. Exercise zero-audio and with-audio paths, 10-bit output, cancel during decoder creation and late image after release.
- [x] Remove existing blanket VP9 packet restrictions only for configurations proven by new header/frame tests; valid hidden/reference frames are decoded even when not displayed. Oversized superframe and dynamic configuration trigger validation/reconfiguration, not accidental output pool growth.
- [x] Audit the prior Opus/Vorbis managed/bounded gate while the resource ledger is available. Add actual managed Range, retry/cancel and byte-accounting tests before opening any strict route. Rejections stay explicit for a policy the route cannot enforce.
- [x] Expected GREEN: `YlSoftwareVideoLifecycleTests`, existing decoder restoration/FEL/buffer tests and P01 cross-Period regression pass on macOS then iOS. Current unavailable hardware rows remain failures/unsupported evidence. Commit Apple integration and comments.

## Task 6: Android 格式与软件策略依赖

**Files:**
- Modify: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlNativeModels.kt`, `YlNativeFallbackEngine.kt`, `YlHardwareCodecSelector.kt`, `YlFfmpegBridge.kt`
- Create: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlSoftwareDecodeAdmission.kt`, `YlSoftwareDecodeBudget.kt`
- Modify: `packages/yl_player_android/android/src/main/cpp/yl_player_ffmpeg.cpp`
- Modify: `packages/yl_player_android/tool/android_ffmpeg/build_shared_libraries.sh`, `test_build_contract.sh`
- Create: `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlSoftwareDecodeBudgetTest.kt`
- Create: `packages/yl_player_android/android/src/androidTest/kotlin/dev/ylplayer/yl_player_android/YlFormatDecodeInstrumentedTest.kt`

**Interfaces:** Append `AV1("video/av01")` without changing existing JNI ordinal identities; add JNI metadata fields with length/version validation on both sides. Mirror Task 3 key/limits/observation units and matching rules. Native decode configuration receives admitted limits before `avcodec_open2`, not after allocation.

- [x] Run three targeted real fixtures through Media3 to locate actual PS/AVI/AV1 gaps; do not route everything to native merely because its build lacks modules. Write real fallback failure tests only for combinations Media3 cannot satisfy.
- [x] Write unit RED for unknown fps rejecting software, metadata/JNI mismatch, hardwareRequired fallback prohibition, insufficient shared budget and software identity after rebuild. Add a direct planner check replacing its current unknown-fps acceptance:

```kotlin
val path = YlNativePlaybackPlanner { false }.chooseVideoPath(
    YlNativeStreamInfo(0, YlNativeStreamKind.VIDEO, YlNativeCodec.H264,
        width = 320, height = 180, frameRate = 0.0))
assertEquals(YlNativeVideoPath.UNSUPPORTED, path)
```

- [x] Implement validated codec mapping and needed PS/AVI/AV1 demux/decode modules, using the same pinned source/license decisions for dav1d if native AV1 is necessary. Build all existing ABIs (`arm64-v8a`, `armeabi-v7a`, `x86_64`), validate JNI symbols and minimum API, and keep the replaceable shared-library license boundary.
- [x] Enforce limits in Media3 software decoder selection/identity callbacks as well as native fallback. The native 1920×1080/30 historical envelope does not replace measured admission. Reference frames, pending native images and candidate/current leases all count; native color/output must preserve supported depth or explicitly reject.
- [x] Run `sh tool/check_native_android.sh` unit/contract checks and the targeted instrumented fixture class on the owned emulator, then public format/decoder tests through `tool/run_android_integration.sh`. Expected: controlled semantics pass, actual hardware/software identity accurate; emulator measurements produce no physical-device admission profile. Commit Android slice.

## Task 7: 三端实际输出和公开错误契约

**Files:**
- Modify: `packages/yl_player/example/integration_test/format_matrix_test.dart`
- Create: `packages/yl_player/example/integration_test/decoder_budget_test.dart`
- Modify: `packages/yl_player/example/integration_test/support/capture_composition.dart` only if format capture needs a reusable helper
- Create: `tool/media_matrix/observations.py`, `test_observations.py`
- Modify: `tool/check_native_macos.sh`, `tool/check_native_ios.sh`, `tool/run_android_integration.sh` only to register actual new test discovery where needed
- Modify: package failure adapter tests if existing internal codes do not map to public `YlFailureCodes.decoderUnavailable`/`resourceExhausted`

**Interfaces:** Preserve existing `YL_FORMAT_ROW` identity and add separate fields for `pixelMarkersVerified`, `pcmMarkersVerified`, `audioClockUs`, verification method and failure stage. Native PCM assertions produce their own evidence keyed by fixture SHA; don't copy their result into a Dart run unless the native measurement is from that same run.

- [x] Write observation validation RED: missing planned rows, duplicate identities, mismatched media/build hashes, marker failure with lifecycle success, and skipped software rows cannot yield full acceptance. Independent host decode remains `playerOutputVerified=false`.
  Required and diagnostic denominators are emitted separately using Task 2's pinned classification; a diagnostic rejection is never added to the supported count.
- [x] Extend the matrix test to sample real displayed colors at 0/1/2/3-second markers and after seek; use P02 capture helpers on Apple and actual texture capture on Android. Wait for marker observation, not just seek acknowledgement. Preserve both captures on mismatch; a host scale change is a failed run requiring a fresh run identity.
- [ ] Use native real-decoder PCM tests for tone, channel order/downmix, leading/trailing samples and seek/track-switch alignment. Reuse P01 PCM tap seams; do not expose a production debug endpoint or infer sound from selected audio track. Add AC-3 5.1, E-AC-3, DTS, FLAC controls.
- [x] Add real public failure assertions:

```dart
// failure comes from the actual load/play exception for an owned test source.
expect(failure.code, YlFailureCodes.decoderUnavailable);
expect(failure.retryable, isFalse);
```

  Controlled native budget exhaustion additionally checks `resourceExhausted`, session/command scope appropriate to the stage, one terminal event and cleanup. No synthetic `YlPlayerFailure` constructed merely to pass the public test.
- [x] Run native and public tests sequentially per platform. Example from `packages/yl_player/example`:

```sh
flutter test integration_test/format_matrix_test.dart -d macos --dart-define=YL_FORMAT_REQUIRE_SUPPORT=true
flutter test integration_test/decoder_budget_test.dart -d macos
```

  Supply P02's existing `P01_CAPTURE_URL` helper for Apple capture. Repeat with the available iOS simulator and Android wrapper. Strict runs may expose genuine still-open requirements; fix implementable failures, preserve unavailable device rows. Do not make unsupported required cases pass by changing expected outcome to rejection.
- [x] Expected GREEN for implemented admitted combinations: actual image/PCM/lifecycle assertions and exact public errors. Full CAP-FORMAT stays open if any confirmed combination still lacks implementation/evidence. Commit tests and measured per-platform observations.

## Task 8: P08 必要测量、准入复验和最终交付

**Files:**
- Create: `tool/decoder_probe/software_protocol.json`, `run_software.py`, `software_decode_probe.swift`
- Modify: `tool/decoder_probe/software_evidence.py`, `test_software_evidence.py`, `README.md`
- Modify: new Apple/Android admission manifests only when evidence qualifies
- Modify: `docs/superpowers/reports/2026-09-26-remaining-03-formats-decoding.md`, original P03 plan, `2026-09-26-remaining-overview.md`, `docs/platform-support.md`
- Create: `docs/superpowers/reports/evidence/2026-10-14-p03-completion/` (explicit logs/manifests/ledger/review files only)

**Interfaces:** `software_evidence.summarize(protocol: dict, rows: list[dict]) -> dict` returns measured summary and explicit admission blockers. `run_software.py PROTOCOL NEW_OUTPUT_DIRECTORY` never overwrites a run. A profile generation command consumes baseline and distinct verification run hashes and refuses incomplete/unqualified evidence.

- [x] Freeze a controlled baseline protocol before running: five fresh process repetitions, each idle 2 s, owned decode/output 12 s, dispose 2 s, monotonic resource samples at 250 ms, no excluded warmup/retries. Decoder runs optimized with fixed thread counts and fixture/build hashes. This short protocol measures engineering overhead; `sustainedThermalVerified=false` remains explicit and prevents standalone production admission.
- [x] Measure true process CPU/RSS/footprint, system power/thermal state and output correctness. Account internal decoder workers; process CPU is conservative and labelled if per-decoder attribution is unavailable. Test collector with truncated/duplicate/out-of-order samples and a failed positive control before accepting a run.
- [x] Consume any already qualified matching P08 sustained evidence read-only. If absent, finish engineering/controlled validation but retain production software profile as unadmitted with exact missing input; don't launch the other chat's long-play workload or invent thermal thresholds.
- [ ] When a baseline qualifies, freeze limits and profile identity in a reviewed evidence manifest before a new independent verification run. Verify real playback at the admitted boundary and synthetic one-unit-over accounting failures. Build/OS/device changes invalidate that record until remeasured. Preserve a failed verification as a failed profile, not a tuned-after-the-fact pass.
- [x] Run final affected Dart suites from repo root, keeping heavy native builds separate:

```sh
flutter test packages/yl_player_platform_interface/test --no-pub
flutter test packages/yl_player/test --no-pub --concurrency=2
flutter test packages/yl_player_apple/test --no-pub
flutter test packages/yl_player_android/test --no-pub
python3 -B -m unittest discover -s tool/media_matrix -p 'test_*.py'
python3 -B -m unittest discover -s tool/decoder_probe -p 'test_*.py'
python3 -B tool/media_matrix/catalog.py
sh packages/yl_player_apple/tool/apple_ffmpeg/test_build_contract.sh
```

  Run four-package analyze, public API/pigeon checks if their inputs changed, and impacted native audio/FEL/P01/P02 suites. Repeat only after a change/failure warrants it. Record original failures and environment workarounds separately.
- [x] Produce one final review package with base/head, approved spec, this plan, Review Focus, ledger rulings and evidence. Dispatch one fresh reviewer as required by executing-plans; fix Important/Critical findings with RED→GREEN and affected regressions. Deferred minors are recorded.
- [x] Update every relevant plan checkbox from actual evidence, archive ledger and review, and commit explicit final files. Report commits, tested functionality and remaining external acceptance conditions without calling all P03 complete while required evidence or implementation remains open.

## 2026-10-15 实施状态

Task 1–6 的勾选表示工程步骤和记录的受控验证已执行，不将未测设备视为支持。Task 7 已执行三端严格矩阵，失败行保留；新增 AC-3/E-AC-3/DTS/FLAC 原生 PCM 验证了音调、布局/降混和 seek，但逐格式独立首尾样本及切轨对齐的完整证明仍不足，故该复合项保留未勾选。iOS 当前模拟器缺少多数路径所需的正向硬解证据。Task 8 短协议五次测量有效，但没有匹配持续热证据，生产档位冻结/独立产品复验的条件未满足。完整 CAP-FORMAT/CAP-DECODE 不宣告通过。详见 [执行报告](../reports/2026-09-26-remaining-03-formats-decoding.md)。

### 2026-10-15 PCM 续做

首尾与切轨受控项已扩展到原 AC-3 5.1、E-AC-3、DTS、FLAC 压缩包复制的四音轨素材，逐包 PTS/帧数、首尾与 2.5 秒切轨窗口使用固定参考，不做波形找齐。Apple 按样本裁剪且保持分配计费，Android Dolby 移除重复 delay 处理；DASH 保留自己的精确时间窗裁剪归属。最终原生计数、制品独立重建及新桥接短测量见[本轮证据](../reports/evidence/2026-10-15-p03-pcm-alignment/README.md)。

该项提供四个控制的分离构建回归证据。Dolby/DTS/Android 与主机参考共享 FFmpeg 血统；逐格式独立实现、iOS 真实播放器切轨和同次产品身份绑定的完整音画验收仍未覆盖，Task 7 复合项继续保留未勾选。历史硬件失败与旧测量不被替换或转移到新制品。

## 自查覆盖与执行记录要求

设计中的容器/音频由 Task 1/2/6 覆盖，解码接口/AV1/VP9/FEL 保持由 Task 3/4/5/6 覆盖，managed/旧系统/错误扩展名由 Task 2/5/7 覆盖，资源/测量由 Task 3/8 覆盖，完整输出/跨计划回归由 Task 7/8 覆盖。五项 Review Focus 均有对应失败测试。

开始时使用本计划自己的 `.superpowers/sdd/2026-10-14-p03-completion/` ledger；不得读取或复用另一计划的工作目录。每项记录真实 RED/GREEN 命令、日志路径、fixture/build 哈希、通过/失败/跳过数及限定文件提交。当前共用 checkout 的明确文件提交方式延续 P02；检查 HEAD 和文件摘要后提交，避免把另一会话的改动带入。

### 2026-10-15 同次产品身份绑定音画续做

新增先冻结真实构建产物、原生进程内核验、同一 player/session 采集和结束后复核的验收链路。六个本地控制逐段保存真实像素、消费时钟、PCM 原始窗口及三次 seek；独立校验器拒绝跨运行/构建/播放器拼接。macOS 最终六项均通过；Android 实际消费头版本五项通过、VP9 硬解必需路径失败，固定分母仍为六；iOS 六项身份核验成功后均因缺少硬解正向证据失败，不使用跳过。

复审发现的 Android 外推时钟冒充消费证据问题已由停滞播放头测试 RED→GREEN 修复，只改变内部观察值，不改变生产调度估算。旧 Android 数据保留但不能升级成新消费时钟证据。公开 Flutter/release 全矩阵、物理/最低系统/Intel 和持续热资格仍不由此覆盖；Task 7 复合项继续开放。详见[本轮记录](../reports/evidence/2026-10-15-p03-bound-av/README.md)。

### 2026-10-16 Android Media3 VP9 同次音画续做

Task 7 的六控制计划现在显式冻结 engine：VP9/Vorbis 使用产品 Media3，其他五项继续 native fallback。新增仅 instrumentation 使用的 post-trim PCM/真实 AudioTrack 播放头采集，ImageReader、完成、三次 seek、释放与实际双解码器身份来自同一会话。内部注入点不开放受保护内容，生产硬解/软解准入未变。六项受控范围首次达到 6/6；公开 Flutter/release、完整格式矩阵、物理输出和持续热资格仍不由此覆盖，Task 7/8 复合项保持开放。详见[本轮证据](../reports/evidence/2026-10-16-p03-media3-vp9/README.md)。
