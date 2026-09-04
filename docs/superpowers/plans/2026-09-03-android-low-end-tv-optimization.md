# Android Low-End TV Playback Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add automatic low-end Android TVBox classification, hardware-only video, bounded source-specific buffering, runtime degradation, live recovery, and robust TV lifecycle handling to the existing Media3 backend.

**Architecture:** Keep Media3 as the only Android engine and extract pure policy, codec, buffering, health, and video-output units from the monolithic plugin. The Flutter API gains nullable diagnostics while the Android player applies the policy at source-open time and uses generation-safe, bounded recovery.

**Tech Stack:** Flutter/Dart 3.12, Kotlin 2.3, Android API 24+, AndroidX Media3 1.11, OkHttp, Flutter TextureRegistry, kotlin-test/JUnit Platform.

**Spec:** `docs/superpowers/specs/2026-09-03-android-low-end-tv-optimization-design.md`

## Global Constraints

- Android 7.0/API 24 remains the minimum Android version.
- The reference device is Android 7.0, 1.5 GB RAM, 32 GB storage, and 32-bit ARM; it must always classify as `constrained`.
- H.264 is capped at 1920x1080 and 30 fps on constrained devices; HEVC requires an explicitly compatible hardware decoder.
- Android video never falls back to software decoding, regardless of `YlDecoderPolicy`.
- Media3 remains the only Android playback engine; do not add FFmpeg or a custom Android decoder.
- Keep subtitles/text renderers disabled; do not add playback UI, `MediaSession`, background audio, downloads, or disk media cache.
- Only one player may own an active Android video decoder.
- Non-Android backends expose the new metrics as `null` and remain behaviorally unchanged.
- Real-device endurance and smoothness validation remain deferred; do not document them as completed.

## File structure

- Create `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlaybackPolicy.kt`: pure tier, source classification, buffer, live, memory, and runtime decision models.
- Create `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlAndroidDeviceProfile.kt`: Android signal and display collection.
- Create `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlHardwareCodecSelector.kt`: hardware-only Media3 codec selection and codec diagnostics.
- Create `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlAdaptiveLoadControl.kt`: mutable byte/duration LoadControl.
- Create `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlaybackHealthMonitor.kt`: pure health-window hysteresis and bounded recovery decisions.
- Create `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlVideoOutput.kt`: Surface ownership and generation isolation.
- Create matching Kotlin unit tests under `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/`.
- Modify `YlPlayerAndroidPlugin.kt`: wire the extracted units into commands, Media3 callbacks, metrics, lifecycle, and errors.
- Modify Dart metrics and both platform codecs/tests for backward-compatible diagnostics.
- Modify Android manifest, README, changelog, and top-level package documentation only where the feature is user-visible.

---

### Task 1: Backward-compatible playback diagnostics

**Files:**
- Modify: `packages/yl_player_platform_interface/lib/src/playback_metrics.dart`
- Modify: `packages/yl_player_platform_interface/test/models_test.dart`
- Modify: `packages/yl_player_android/lib/src/channel_codec.dart`
- Modify: `packages/yl_player_android/test/yl_player_android_test.dart`
- Modify: `packages/yl_player_ios/lib/src/channel_codec.dart`
- Modify: `packages/yl_player_ios/test/yl_player_ios_test.dart`

**Interfaces:**
- Produces: nullable `androidDeviceTier`, `targetBufferBytes`, `adaptiveDowngradeCount`, `surfaceRebuildCount`, and `selectedVideoBitrate` fields on `YlPlaybackMetrics`.
- Compatibility: missing native map keys decode to `null`; existing constructor calls remain valid.

- [ ] **Step 1: Write failing Dart model and channel tests**

Add a platform-interface assertion:

```dart
const metrics = YlPlaybackMetrics(
  androidDeviceTier: 'constrained',
  targetBufferBytes: 24 * 1024 * 1024,
  adaptiveDowngradeCount: 1,
  surfaceRebuildCount: 2,
  selectedVideoBitrate: 2500000,
);
expect(metrics.androidDeviceTier, 'constrained');
expect(metrics.targetBufferBytes, 24 * 1024 * 1024);
```

Extend the Android native-state fixture with all five map keys and assert every
decoded value. Add an iOS fixture without those keys and assert all five fields
are null.

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
flutter test packages/yl_player_platform_interface/test/models_test.dart
flutter test packages/yl_player_android/test/yl_player_android_test.dart
flutter test packages/yl_player_ios/test/yl_player_ios_test.dart
```

Expected: compilation fails because the five members do not exist.

- [ ] **Step 3: Add the nullable fields and decode them**

Extend the constructor and class with:

```dart
this.androidDeviceTier,
this.targetBufferBytes,
this.adaptiveDowngradeCount,
this.surfaceRebuildCount,
this.selectedVideoBitrate,

final String? androidDeviceTier;
final int? targetBufferBytes;
final int? adaptiveDowngradeCount;
final int? surfaceRebuildCount;
final int? selectedVideoBitrate;
```

In both Android and iOS `_decodeMetrics`, pass `_int(...)` for numeric fields and
`map['androidDeviceTier'] as String?` for the tier. Do not synthesize Android
defaults in Dart.

- [ ] **Step 4: Format and rerun the focused tests**

Run:

```bash
dart format packages/yl_player_platform_interface/lib/src/playback_metrics.dart packages/yl_player_platform_interface/test/models_test.dart packages/yl_player_android/lib/src/channel_codec.dart packages/yl_player_android/test/yl_player_android_test.dart packages/yl_player_ios/lib/src/channel_codec.dart packages/yl_player_ios/test/yl_player_ios_test.dart
flutter test packages/yl_player_platform_interface/test/models_test.dart
flutter test packages/yl_player_android/test/yl_player_android_test.dart
flutter test packages/yl_player_ios/test/yl_player_ios_test.dart
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_platform_interface packages/yl_player_android/lib packages/yl_player_android/test packages/yl_player_ios/lib packages/yl_player_ios/test
git commit -m "feat: expose Android playback diagnostics"
```

### Task 2: Pure device and source policy

**Files:**
- Create: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlaybackPolicy.kt`
- Test: `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlPlaybackPolicyTest.kt`

**Interfaces:**
- Produces: `YlDeviceTier`, `YlDeviceSignals`, `YlSourceClass`, `YlBufferProfile`, `YlMemoryAction`, `YlPlaybackPolicy.classifyDevice`, `classifySource`, `effectiveBufferProfile`, and `memoryAction`.
- Consumes later: parsed `PlayerConfiguration` values and the source method-channel map.

- [ ] **Step 1: Write failing tier and source-classification tests**

Cover each boundary explicitly:

```kotlin
@Test
fun `Android 7 1_5GB 32-bit is constrained`() {
    val signals = YlDeviceSignals(
        totalMemoryBytes = 1536L * 1024 * 1024,
        memoryClassMb = 192,
        is64Bit = false,
        apiLevel = 24,
    )
    assertEquals(YlDeviceTier.CONSTRAINED, YlPlaybackPolicy.classifyDevice(signals))
}

@Test
fun `explicit hint wins and query is ignored`() {
    assertEquals(
        YlSourceClass.HLS_LIVE,
        YlPlaybackPolicy.classifySource("network", true, "hls", "https://x/live.flv?x=.m3u8"),
    )
}
```

Also test 2 GB exactly, API 27, unknown signals, standard, capable, file,
content, `.m3u8`, `.flv`, generic VOD, and unknown live.

- [ ] **Step 2: Run the Kotlin test and verify failure**

Run from `packages/yl_player_android/example/android`:

```bash
./gradlew :yl_player_android:testDebugUnitTest --tests '*YlPlaybackPolicyTest'
```

Expected: compilation fails because the policy types do not exist.

- [ ] **Step 3: Implement pure tier and source classification**

Create stable enums and values:

```kotlin
internal enum class YlDeviceTier(val wireName: String) {
    CONSTRAINED("constrained"), STANDARD("standard"), CAPABLE("capable")
}

internal enum class YlSourceClass { LOCAL, NETWORK_VOD, HLS_LIVE, HTTP_FLV_LIVE }

internal data class YlDeviceSignals(
    val totalMemoryBytes: Long?,
    val memoryClassMb: Int,
    val is64Bit: Boolean?,
    val apiLevel: Int,
)
```

Parse URL paths with `java.net.URI(uri).path.lowercase()` inside `runCatching`;
never inspect the query. Evaluate constrained before capable, and treat unknown
RAM/bitness as incapable of producing `CAPABLE`.

- [ ] **Step 4: Add failing exact-buffer and memory-action tests**

Assert constrained automatic values exactly:

```kotlin
assertEquals(
    YlBufferProfile(4_000, 15_000, 24 * 1024 * 1024),
    YlPlaybackPolicy.effectiveBufferProfile(
        YlDeviceTier.CONSTRAINED,
        YlSourceClass.NETWORK_VOD,
        YlBufferRequest.automatic(),
    ),
)
```

Cover all four source profiles, constrained clamping, standard 64 MiB and
capable 96 MiB caps, custom smaller values, min-above-max normalization, 25%
running-low shrink, critical release, UI-hidden release, and foreground restore.

- [ ] **Step 5: Implement buffer and memory decisions**

Use immutable values:

```kotlin
internal data class YlBufferProfile(
    val minBufferMs: Int,
    val maxBufferMs: Int,
    val targetBufferBytes: Int,
)

internal data class YlBufferRequest(
    val mode: String,
    val minBufferMs: Int?,
    val maxBufferMs: Int?,
    val maxBufferBytes: Int?,
) {
    companion object {
        fun automatic() = YlBufferRequest("automatic", null, null, null)
    }
}

internal enum class YlMemoryAction { NONE, SHRINK, RELEASE, RESTORE }
```

Keep Android callback constants out of the pure policy; the plugin will map
framework levels to `YlMemoryAction`.

- [ ] **Step 6: Run the policy suite and commit**

```bash
./gradlew :yl_player_android:testDebugUnitTest --tests '*YlPlaybackPolicyTest'
git add packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlaybackPolicy.kt packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlPlaybackPolicyTest.kt
git commit -m "feat: add Android TV playback policy"
```

Expected: tests pass.

### Task 3: Android signals and hardware-only codec selection

**Files:**
- Create: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlAndroidDeviceProfile.kt`
- Create: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlHardwareCodecSelector.kt`
- Test: `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlHardwareCodecSelectorTest.kt`
- Modify: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerAndroidPlugin.kt`

**Interfaces:**
- Produces: `YlAndroidDeviceProfile.collect(Context)`, `YlHardwareCodecSelector`, `YlVideoEnvelope`, `videoEnvelope(tier, displayWidth, displayHeight, displayRate)`, and `isHardwareCodecName`.
- Consumes: `YlDeviceSignals` and `YlDeviceTier` from Task 2.

- [ ] **Step 1: Write failing pure codec-classification tests**

```kotlin
@Test
fun `legacy software codec names are rejected`() {
    listOf("OMX.google.h264.decoder", "c2.android.avc.decoder", "vendor.sw.hevc")
        .forEach { assertFalse(isHardwareCodecName(it)) }
}

@Test
fun `constrained envelope is 1080p30`() {
    assertEquals(YlVideoEnvelope(1920, 1080, 30.0), videoEnvelope(YlDeviceTier.CONSTRAINED, 3840, 2160, 60.0))
}
```

Also cover vendor hardware names, uncertain names, HEVC capability absent,
profile/level rejection, display intersection, and host quality limits.

- [ ] **Step 2: Run the focused test and verify failure**

```bash
./gradlew :yl_player_android:testDebugUnitTest --tests '*YlHardwareCodecSelectorTest'
```

Expected: compilation fails for missing codec policy.

- [ ] **Step 3: Implement the Android signal collector**

Collect only local capabilities:

```kotlin
internal data class YlAndroidDeviceProfile(
    val signals: YlDeviceSignals,
    val tier: YlDeviceTier,
    val displayWidth: Int?,
    val displayHeight: Int?,
    val displayRefreshRate: Double?,
) {
    companion object {
        fun collect(context: Context): YlAndroidDeviceProfile
    }
}

val memoryInfo = ActivityManager.MemoryInfo().also(activityManager::getMemoryInfo)
val signals = YlDeviceSignals(
    totalMemoryBytes = memoryInfo.totalMem.takeIf { it > 0 },
    memoryClassMb = activityManager.memoryClass,
    is64Bit = if (Build.VERSION.SDK_INT >= 23) Process.is64Bit() else null,
    apiLevel = Build.VERSION.SDK_INT,
)
```

Read active display size/refresh conservatively and return null limits when the
window service cannot supply them. Do not persist identifiers.

- [ ] **Step 4: Implement the selector and envelope**

Wrap `MediaCodecSelector.DEFAULT`. For video MIME types, retain only entries
where `hardwareAccelerated && !softwareOnly`; on legacy/uncertain entries apply
the conservative name classifier. Use Media3 `isFormatSupported` and
`isVideoSizeAndRateSupported` for final selection; do not manually claim
capabilities that Media3 rejects. Audio decoder lists pass through unchanged.

The constrained envelope is:

```kotlin
YlVideoEnvelope(maxWidth = 1920, maxHeight = 1080, maxFrameRate = 30.0)
```

Intersect it with display and host constraints. HEVC is eligible only when the
filtered selector returns an explicitly supported hardware decoder.

- [ ] **Step 5: Replace the old inline codec helpers and rerun tests**

Delete `hardwareOnlyCodecSelector`, `isHardwareCodec`, and duplicate name logic
from `YlPlayerAndroidPlugin.kt`. Construct `DefaultRenderersFactory` with the new
selector for every Android decoder policy and keep text disabled.

Run:

```bash
./gradlew :yl_player_android:testDebugUnitTest --tests '*YlHardwareCodecSelectorTest'
./gradlew :yl_player_android:compileDebugKotlin
```

Expected: tests and Kotlin compilation pass.

- [ ] **Step 6: Commit**

```bash
git add packages/yl_player_android/android/src
git commit -m "feat: require Android hardware video decoding"
```

### Task 4: Mutable bounded LoadControl

**Files:**
- Create: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlAdaptiveLoadControl.kt`
- Test: `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlAdaptiveLoadControlTest.kt`
- Modify: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerAndroidPlugin.kt`

**Interfaces:**
- Produces: `YlAdaptiveLoadControl(profile)`, `updateProfile(profile)`, `shrinkForMemoryPressure()`, `restoreProfile()`, and `targetBufferBytes`.
- Consumes: `YlBufferProfile` from Task 2.

- [ ] **Step 1: Write failing load-decision tests**

Test the pure decision boundary used by LoadControl:

```kotlin
assertTrue(shouldContinueLoading(bufferedMs = 1_000, allocatedBytes = 8, profile = profile))
assertFalse(shouldContinueLoading(bufferedMs = 16_000, allocatedBytes = 8, profile = profile))
assertFalse(shouldContinueLoading(bufferedMs = 8_000, allocatedBytes = profile.targetBufferBytes, profile = profile))
```

Also test playback-start thresholds, 25% shrink, restore, and repeated shrink
idempotence within one pressure episode.

- [ ] **Step 2: Run the focused test and verify failure**

```bash
./gradlew :yl_player_android:testDebugUnitTest --tests '*YlAdaptiveLoadControlTest'
```

- [ ] **Step 3: Implement LoadControl with one allocator**

Implement `LoadControl` with a stable `DefaultAllocator(true,
C.DEFAULT_BUFFER_SEGMENT_SIZE)`. `updateProfile` updates the volatile profile and
calls `allocator.setTargetBufferSize`. `shrinkForMemoryPressure` installs the
75% target once and calls `allocator.trim()`. `restoreProfile` restores the
source profile.

Core decision:

```kotlin
val bytesReached = allocator.totalBytesAllocated >= current.targetBufferBytes
return when {
    bufferedMs < current.minBufferMs -> !bytesReached
    bufferedMs >= current.maxBufferMs -> false
    else -> !bytesReached
}
```

Start thresholds are `min(1_000, minBufferMs)` initially and
`min(2_000, minBufferMs)` after rebuffer. Scale buffered duration by playback
speed. Return a zero back buffer and never retain from keyframes.

- [ ] **Step 4: Wire one LoadControl instance into Media3**

Replace `PlayerConfiguration.createLoadControl()` with a player-owned
`YlAdaptiveLoadControl`. On every `open`, classify the source, derive the
effective profile, call `updateProfile` before `prepare`, and emit the effective
target in metrics.

- [ ] **Step 5: Run tests and compile**

```bash
./gradlew :yl_player_android:testDebugUnitTest --tests '*YlAdaptiveLoadControlTest' --tests '*YlPlaybackPolicyTest'
./gradlew :yl_player_android:compileDebugKotlin
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add packages/yl_player_android/android/src
git commit -m "feat: bound Android media buffers"
```

### Task 5: Integrate source policy, quality limits, metrics, and stable errors

**Files:**
- Modify: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerAndroidPlugin.kt`
- Create: `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlPlayerErrorPolicyTest.kt`

**Interfaces:**
- Consumes: device profile, source policy, hardware selector, and adaptive LoadControl.
- Produces: Media3 track constraints, selected bitrate metrics, single decoder retry, and stable error mapping.

- [ ] **Step 1: Write failing error and recovery-decision tests**

Extract a pure mapper and assert exact results:

```kotlin
internal data class YlStableError(
    val category: String,
    val code: String,
    val message: String = code,
)

assertEquals(
    YlStableError("decoderUnsupported", "decoder.hardware_required"),
    errorForNoHardwareDecoder(),
)
assertEquals(
    DecoderRecovery.DOWNGRADE_ONCE,
    decoderRecovery(isAdaptive = true, previousRetries = 0),
)
assertEquals(
    DecoderRecovery.FAIL,
    decoderRecovery(isAdaptive = true, previousRetries = 1),
)
```

Cover capability exceeded, fixed-stream failure, decoder busy, memory-pressure
rebuild failure, and exhausted live retry.

- [ ] **Step 2: Run and verify failure**

```bash
./gradlew :yl_player_android:testDebugUnitTest --tests '*YlPlayerErrorPolicyTest'
```

- [ ] **Step 3: Apply effective quality constraints at open**

Store the host constraint separately. Rebuild track-selector parameters at each
source generation and apply the minimum width, height, and bitrate ceiling. Set
`setExceedVideoConstraintsIfNecessary(false)` and
`setExceedRendererCapabilitiesIfNecessary(false)` so Media3 cannot silently
select an unsafe video track.

Record the selected video track's declared bitrate in `selectedVideoBitrate` on
`onTracksChanged`, or null when unknown. Reset all five new per-open diagnostics
as defined by the spec.

- [ ] **Step 4: Add the one permitted adaptive decoder retry**

On `ERROR_CODE_DECODER_INIT_FAILED`, inspect the current selected adaptive video
group. If no retry has occurred and a lower supported track exists, exclude the
failed format, lower the selector bitrate ceiling to the next bitrate, increment
the downgrade counter, and prepare once. Otherwise emit
`decoder.initialization_failed`. Fixed sources emit
`decoder.hardware_required` or `decoder.capability_exceeded` without retry.

- [ ] **Step 5: Emit stable errors and metrics**

Add these keys to the native metrics map:

```kotlin
"androidDeviceTier" to deviceProfile.tier.wireName,
"targetBufferBytes" to loadControl.targetBufferBytes,
"adaptiveDowngradeCount" to adaptiveDowngradeCount,
"surfaceRebuildCount" to videoOutput.surfaceRebuildCount,
"selectedVideoBitrate" to selectedVideoBitrate,
```

Use only sanitized codec name, dimensions, frame rate, and API level in error
diagnostics. Never include URL or headers.

- [ ] **Step 6: Run Android and Flutter tests**

```bash
./gradlew :yl_player_android:testDebugUnitTest
./gradlew :yl_player_android:compileDebugKotlin
flutter test packages/yl_player_android
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add packages/yl_player_android/android/src packages/yl_player_android/test
git commit -m "feat: apply Android TV decode policy"
```

### Task 6: Runtime health degradation and live recovery

**Files:**
- Create: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlaybackHealthMonitor.kt`
- Test: `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlPlaybackHealthMonitorTest.kt`
- Modify: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerAndroidPlugin.kt`

**Interfaces:**
- Produces: `YlHealthSample`, `YlRecoveryAction`, and `YlPlaybackHealthMonitor.record(...)`.
- Consumes: 30-second window deltas, source class, live offset, available adaptive tracks, and monotonic time.

- [ ] **Step 1: Write failing hysteresis and live-action tests**

Use an injected monotonic clock and cover:

```kotlin
monitor.record(unhealthyWindow(nowMs = 30_000)) // NONE
assertEquals(YlRecoveryAction.DOWNGRADE_ONE_STEP, monitor.record(unhealthyWindow(nowMs = 60_000)))
assertEquals(YlRecoveryAction.NONE, monitor.record(unhealthyWindow(nowMs = 90_000))) // cooldown
```

Also verify dropped ratio/absolute thresholds, rebuffer thresholds, immediate
memory downgrade, no upgrade, cooldown expiry, HLS 1.03x catch-up, 30-second
forced-live-edge rate limit, HTTP-FLV severe backlog reconnect, and retry
exhaustion.

- [ ] **Step 2: Run and verify failure**

```bash
./gradlew :yl_player_android:testDebugUnitTest --tests '*YlPlaybackHealthMonitorTest'
```

- [ ] **Step 3: Implement the pure monitor**

Make the monitor return commands rather than touching ExoPlayer:

```kotlin
internal data class YlHealthSample(
    val nowMs: Long,
    val elapsedMs: Long,
    val droppedFrames: Int,
    val estimatedRenderedFrames: Int,
    val rebufferCount: Int,
    val rebufferDurationMs: Long,
    val memoryPressure: Boolean,
    val sourceClass: YlSourceClass,
    val liveOffsetMs: Long?,
    val maxBufferMs: Int,
)

internal sealed interface YlRecoveryAction {
    data object None : YlRecoveryAction
    data object DowngradeOneStep : YlRecoveryAction
    data object SeekLiveEdge : YlRecoveryAction
    data object ReconnectLiveHead : YlRecoveryAction
    data class SetCatchUpSpeed(val speed: Float) : YlRecoveryAction
    data class Fail(val error: YlStableError) : YlRecoveryAction
}
```

Reset window counters after evaluation. Never return an upgrade command.

- [ ] **Step 4: Connect analytics and a lightweight health ticker**

Accumulate dropped frames and rebuffer duration from existing callbacks. After
the first frame, post a 30-second handler tick scoped to the source generation.
Translate monitor actions to one track-selector downgrade, playback speed no
higher than 1.03, a rate-limited `seekToDefaultPosition`, or HTTP-FLV stop/
prepare at live head. Reset speed to 1.0 when HLS is back within target.

- [ ] **Step 5: Run tests and compile**

```bash
./gradlew :yl_player_android:testDebugUnitTest --tests '*YlPlaybackHealthMonitorTest'
./gradlew :yl_player_android:testDebugUnitTest
./gradlew :yl_player_android:compileDebugKotlin
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add packages/yl_player_android/android/src
git commit -m "feat: adapt Android playback health"
```

### Task 7: Generation-safe Surface, lifecycle, audio focus, and memory pressure

**Files:**
- Create: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlVideoOutput.kt`
- Create: `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlLifecyclePolicyTest.kt`
- Modify: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerAndroidPlugin.kt`
- Modify: `packages/yl_player_android/android/src/main/AndroidManifest.xml`

**Interfaces:**
- Produces: `YlVideoOutput.attach`, `detach`, `rebuild`, `resize`, `dispose`, `generation`, and `surfaceRebuildCount`.
- Produces: pure lifecycle transition decisions tested without an Activity.
- Consumes: player source generation and `YlMemoryAction`.

- [ ] **Step 1: Write failing lifecycle transition tests**

Test an extracted state reducer:

```kotlin
internal enum class YlLifecycleEvent {
    SURFACE_LOST_FOREGROUND, RUNNING_LOW, RUNNING_CRITICAL, UI_HIDDEN, FOREGROUND
}
internal enum class YlLifecycleAction {
    KEEP_PLAYER_DETACH_VIDEO, SHRINK_BUFFERS, RELEASE_AND_SAVE, REBUILD_IF_INTENDED
}

assertEquals(YlLifecycleAction.KEEP_PLAYER_DETACH_VIDEO, reduce(YlLifecycleEvent.SURFACE_LOST_FOREGROUND))
assertEquals(YlLifecycleAction.SHRINK_BUFFERS, reduce(YlLifecycleEvent.RUNNING_LOW))
assertEquals(YlLifecycleAction.RELEASE_AND_SAVE, reduce(YlLifecycleEvent.RUNNING_CRITICAL))
assertEquals(YlLifecycleAction.RELEASE_AND_SAVE, reduce(YlLifecycleEvent.UI_HIDDEN))
assertEquals(YlLifecycleAction.REBUILD_IF_INTENDED, reduce(YlLifecycleEvent.FOREGROUND))
```

Also cover repeated callbacks, explicit pause not being undone, focus-paused
resume within three seconds, focus grace expiry, stale surface generation, and
dispose exactly once.

- [ ] **Step 2: Run and verify failure**

```bash
./gradlew :yl_player_android:testDebugUnitTest --tests '*YlLifecyclePolicyTest'
```

- [ ] **Step 3: Implement `YlVideoOutput`**

Keep the Flutter `SurfaceTextureEntry` for one player lifetime, but create and
release native `Surface` objects per output generation. `attach` succeeds only
when both expected source and surface generations still match. `resize` calls
`setDefaultBufferSize` only for positive dimensions. `dispose` releases the
current Surface and texture once.

- [ ] **Step 4: Configure Media3 audio and wake behavior**

During player construction:

```kotlin
exoPlayer.setAudioAttributes(
    AudioAttributes.Builder()
        .setUsage(C.USAGE_MEDIA)
        .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
        .build(),
    true,
)
exoPlayer.setHandleAudioBecomingNoisy(true)
exoPlayer.setWakeMode(C.WAKE_MODE_NETWORK)
```

Add only:

```xml
<uses-permission android:name="android.permission.WAKE_LOCK" />
```

- [ ] **Step 5: Replace lifecycle and trim behavior**

Map running-low/moderate to `loadControl.shrinkForMemoryPressure()` and an
immediate health sample; do not stop the player. Map critical, low-memory,
UI-hidden, and real background to save/release. Foreground restores the normal
profile, rebuilds Surface/Media3 state, and resumes only prior playback intent.

On configuration/HDMI changes call the generation-safe Surface rebuild. Use a
three-second handler grace for Media3 audio-focus loss. Cancel it on focus
recovery, explicit pause, background release, new open, or dispose.

- [ ] **Step 6: Verify single decoder ownership and stale-event isolation**

Keep transfer in the plugin: before `open` or `play` activates a player,
deactivate every other video owner. Ensure source/surface generation checks
guard late analytics events and that each resource release is idempotent.

- [ ] **Step 7: Run native and Dart regression tests**

```bash
./gradlew :yl_player_android:testDebugUnitTest
./gradlew :yl_player_android:compileDebugKotlin
flutter test packages/yl_player_android
flutter test packages/yl_player
```

Expected: pass.

- [ ] **Step 8: Commit**

```bash
git add packages/yl_player_android/android/src
git commit -m "feat: harden Android TV lifecycle"
```

### Task 8: Documentation, 32-bit build, publication, and full verification

**Files:**
- Modify: `packages/yl_player_android/README.md`
- Modify: `packages/yl_player_android/CHANGELOG.md`
- Modify: `packages/yl_player/README.md`
- Modify: `packages/yl_player/CHANGELOG.md`
- Modify: `docs/superpowers/plans/2026-09-03-android-low-end-tv-optimization.md`

**Interfaces:**
- Produces: accurate package claims and recorded automated evidence.
- Consumes: all previous tasks.

- [ ] **Step 1: Update documentation without overstating validation**

Document:

- automatic constrained/standard/capable tiers;
- constrained local/VOD/HLS/HTTP-FLV byte and time ceilings;
- hardware-only Android video and capability-dependent HEVC;
- no subtitles, background audio, software decode, or disk cache;
- the five nullable diagnostics; and
- deferred Android 7/1.5 GB/32-bit physical-device endurance validation.

Do not say 1080p or HEVC is universally smooth.

- [ ] **Step 2: Run formatting and static checks**

```bash
dart format --output=none --set-exit-if-changed packages
flutter analyze
git diff --check
```

Expected: all exit zero.

- [ ] **Step 3: Run the complete automated test suite**

```bash
flutter test packages/yl_player_platform_interface
flutter test packages/yl_player_android
flutter test packages/yl_player_ios
flutter test packages/yl_player
cd packages/yl_player_android/example/android
./gradlew :yl_player_android:testDebugUnitTest
```

Expected: every test passes.

- [ ] **Step 4: Build the Android 32-bit target**

Run from `packages/yl_player_android/example`:

```bash
flutter build apk --debug --target-platform android-arm
```

Expected: the debug APK builds and contains `lib/armeabi-v7a/libflutter.so`.
Confirm with:

```bash
unzip -l build/app/outputs/flutter-apk/app-debug.apk | rg 'lib/armeabi-v7a/libflutter.so'
```

- [ ] **Step 5: Run publication dry runs**

Run in each publishable package:

```bash
dart pub publish --dry-run
```

Execute for `yl_player_platform_interface`, `yl_player_android`, `yl_player_ios`,
and `yl_player`. Expected: no blocking validation error. Existing non-blocking
repository warnings must be reported exactly rather than hidden.

- [ ] **Step 6: Record completion evidence in this plan**

Append a `## Verification record` containing the executed command, date, and
result for each gate. Mark only completed checkboxes. Keep the physical-device
gate explicitly deferred.

- [ ] **Step 7: Commit documentation and verification record**

```bash
git add packages/yl_player_android/README.md packages/yl_player_android/CHANGELOG.md packages/yl_player/README.md packages/yl_player/CHANGELOG.md docs/superpowers/plans/2026-09-03-android-low-end-tv-optimization.md
git commit -m "docs: describe Android TV optimization"
```

- [ ] **Step 8: Inspect final history and worktree**

```bash
git status --short
git log --oneline -10
```

Expected: clean worktree and the eight independently reviewable feature/docs
commits following the design and plan commits. Do not push or publish without a
separate explicit user request.
