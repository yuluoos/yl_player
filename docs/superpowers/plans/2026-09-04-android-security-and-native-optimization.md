# Android Security and Native Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent redirect credential leakage, correct first-frame and capability reporting, emit compact versioned position deltas, and split the Android implementation into focused files without changing Media3 playback algorithms.

**Architecture:** Keep Media3 and the existing hardware-only codec selector. Extract redirect policy, channel models/encoding, and `Media3Player` from plugin registration; pure Kotlin helpers receive focused unit tests while the plugin continues owning the player registry and application lifecycle.

**Tech Stack:** Kotlin, Android API 24+, AndroidX Media3 1.11, OkHttp 4.12, Flutter texture registry, Gradle/AGP 9, JUnit Platform.

**Spec:** `docs/superpowers/specs/2026-09-04-full-repository-optimization-design.md`

## Global Constraints

- Complete `docs/superpowers/plans/2026-09-04-dart-contract-and-state-semantics.md` first; Android envelopes target channel protocol version 1 defined there.
- Android API 24 remains the minimum and Media3 remains the only Android engine.
- Caller `Authorization`, `Cookie`, and `Proxy-Authorization` must never cross a scheme, host, or effective-port boundary.
- The one-active-video-decoder and hardware-only policies remain unchanged.
- The default position update frequency remains 250 ms and native clamping remains 100–2000 ms.
- Full state must be emitted on listen and on every semantic transition; only timer ticks become deltas.
- Keep the existing texture API unless Flutter 3.44/API 24 lifecycle equivalence is proven by tests.
- Do not log or encode source URLs, query strings, credentials, or headers in diagnostics.
- Every behavior change follows red-green-refactor and ends in a focused commit.

## File Structure

- Create `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlAndroidNetwork.kt`: parsed network configuration, same-origin credential policy, OkHttp construction, and retry policy.
- Create `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlRedirectCredentialPolicyTest.kt`: same-origin and redirect-hop security tests.
- Create `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlFirstFrameGate.kt`: source-generation first-frame gate.
- Create `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlFirstFrameGateTest.kt`: duplicate/stale frame tests.
- Create `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlAndroidChannel.kt`: configuration models, format routing, canonical capabilities, error maps, and full/delta envelope builders.
- Create `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlAndroidChannelTest.kt`: format/capability/envelope tests.
- Create `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3Player.kt`: Media3 player, listeners, commands, health, and lifecycle implementation moved intact from the plugin file.
- Modify `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerAndroidPlugin.kt`: retain registration, registry, command routing, and application callbacks only.
- Modify both Flutter example `gradle.properties` and `settings.gradle.kts` files plus the plugin `build.gradle.kts`: remove AGP 9 compatibility flags and redundant external Kotlin plugin configuration.
- Modify existing Android unit tests only where visibility/imports move with the extraction.

---

### Task 1: Cross-origin credential stripping

**Files:**
- Create: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlAndroidNetwork.kt`
- Create: `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlRedirectCredentialPolicyTest.kt`
- Modify: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerAndroidPlugin.kt`

**Interfaces:**
- Produces: `YlHttpOrigin.from(HttpUrl): YlHttpOrigin` using lowercase scheme/host and OkHttp's effective `port`.
- Produces: `YlRedirectCredentialPolicy.sanitize(originalUrl: HttpUrl, request: Request): Request`.
- Produces: `NetworkConfiguration.createHttpClient(): OkHttpClient` with credential sanitation before every `chain.proceed`.

- [ ] **Step 1: Write failing origin and header-policy tests**

Use real OkHttp `Request` objects:

```kotlin
@Test
fun `same origin keeps caller credentials including implicit https port`() {
    val original = "https://media.test/start".toHttpUrl()
    val redirected = Request.Builder()
        .url("https://MEDIA.test:443/next")
        .header("Authorization", "Bearer secret")
        .header("Cookie", "sid=secret")
        .header("Proxy-Authorization", "Basic secret")
        .build()

    val safe = YlRedirectCredentialPolicy.sanitize(original, redirected)

    assertEquals("Bearer secret", safe.header("Authorization"))
    assertEquals("sid=secret", safe.header("Cookie"))
    assertEquals("Basic secret", safe.header("Proxy-Authorization"))
}

@Test
fun `cross origin strips all credentials but keeps ordinary headers`() {
    val safe = YlRedirectCredentialPolicy.sanitize(
        "https://media.test/start".toHttpUrl(),
        Request.Builder()
            .url("https://cdn.test/next")
            .header("Authorization", "Bearer secret")
            .header("Cookie", "sid=secret")
            .header("Proxy-Authorization", "Basic secret")
            .header("User-Agent", "YL")
            .build(),
    )
    assertNull(safe.header("Authorization"))
    assertNull(safe.header("Cookie"))
    assertNull(safe.header("Proxy-Authorization"))
    assertEquals("YL", safe.header("User-Agent"))
}
```

Add separate cases for `https→http`, `443→8443`, host case normalization, `http:80`, and two hops where credentials removed on hop one cannot reappear on hop two.

- [ ] **Step 2: Run the focused native test and verify failure**

Run from `packages/yl_player_android/example/android`:

```bash
./gradlew :yl_player_android:testDebugUnitTest --tests '*YlRedirectCredentialPolicyTest'
```

Expected: compilation fails because the policy does not exist.

- [ ] **Step 3: Implement effective-origin sanitation and wire it before I/O**

Implement:

```kotlin
internal data class YlHttpOrigin(val scheme: String, val host: String, val port: Int) {
    companion object {
        fun from(url: HttpUrl) = YlHttpOrigin(
            scheme = url.scheme.lowercase(),
            host = url.host.lowercase(),
            port = url.port,
        )
    }
}

internal object YlRedirectCredentialPolicy {
    private val credentialHeaders = listOf(
        "Authorization", "Cookie", "Proxy-Authorization",
    )

    fun sanitize(originalUrl: HttpUrl, request: Request): Request {
        if (YlHttpOrigin.from(originalUrl) == YlHttpOrigin.from(request.url)) return request
        return request.newBuilder().apply {
            credentialHeaders.forEach(::removeHeader)
        }.build()
    }
}
```

In the network interceptor, compute `safeRequest` from `chain.call().request().url` and `chain.request()`, then call `chain.proceed(safeRequest)`. Preserve existing redirect counting and response closing. Move `NetworkConfiguration` and `YlLoadErrorHandlingPolicy` into the same file without behavioral changes.

- [ ] **Step 4: Run redirect and complete Android native suites**

Run:

```bash
./gradlew :yl_player_android:testDebugUnitTest --tests '*YlRedirectCredentialPolicyTest'
./gradlew :yl_player_android:testDebugUnitTest
```

Expected: all tests pass and no test output contains a credential value.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_android/android/src/main packages/yl_player_android/android/src/test
git commit -m "fix(android): strip credentials across redirects"
```

### Task 2: First-frame generation gate

**Files:**
- Create: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlFirstFrameGate.kt`
- Create: `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlFirstFrameGateTest.kt`
- Modify: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerAndroidPlugin.kt`

**Interfaces:**
- Produces: `YlFirstFrameGate.reset(generation: Long)` and `YlFirstFrameGate.markRendered(generation: Long): Boolean`.
- Consumer behavior: only a `true` return may set `firstFrameDurationMs`, emit `firstFrame`, or emit the associated full state.

- [ ] **Step 1: Write failing gate tests**

```kotlin
@Test
fun `only first current-generation callback is accepted`() {
    val gate = YlFirstFrameGate()
    gate.reset(4)
    assertTrue(gate.markRendered(4))
    assertFalse(gate.markRendered(4))
    assertFalse(gate.markRendered(3))
}

@Test
fun `new source generation admits one new first frame`() {
    val gate = YlFirstFrameGate()
    gate.reset(4)
    assertTrue(gate.markRendered(4))
    gate.reset(5)
    assertTrue(gate.markRendered(5))
}
```

- [ ] **Step 2: Run the test and verify failure**

```bash
./gradlew :yl_player_android:testDebugUnitTest --tests '*YlFirstFrameGateTest'
```

Expected: compilation fails because `YlFirstFrameGate` does not exist.

- [ ] **Step 3: Implement and integrate the gate**

```kotlin
internal class YlFirstFrameGate {
    private var generation = Long.MIN_VALUE
    private var sent = false

    fun reset(generation: Long) {
        this.generation = generation
        sent = false
    }

    fun markRendered(generation: Long): Boolean {
        if (sent || this.generation != generation) return false
        sent = true
        return true
    }
}
```

Reset immediately after incrementing `sourceGeneration` in `open`. At the top of `onRenderedFirstFrame`, capture the current generation and return unless `markRendered` succeeds. Leave surface rebuilds free to call Media3; they simply cannot alter the public first-frame measurement.

- [ ] **Step 4: Run gate, lifecycle, and native suites**

```bash
./gradlew :yl_player_android:testDebugUnitTest --tests '*YlFirstFrameGateTest' --tests '*YlLifecyclePolicyTest'
./gradlew :yl_player_android:testDebugUnitTest
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_android/android/src/main packages/yl_player_android/android/src/test
git commit -m "fix(android): emit first frame once per source"
```

### Task 3: Canonical Android capabilities and format routing

**Files:**
- Create: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlAndroidChannel.kt`
- Create: `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlAndroidChannelTest.kt`
- Modify: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerAndroidPlugin.kt`

**Interfaces:**
- Produces: `YlAndroidChannel.mimeType(formatHint: String?): String?`.
- Produces: `YlAndroidChannel.supportedFormats: List<String>` containing `automatic`, `hls`, `httpFlv`, `mp4`, `mov`, `matroska`, `webm`, `mpegTs`, `mpegPs`, `flv`, and `avi` exactly once.
- Produces: `YlAndroidChannel.capabilities(...)` with MIME codec identifiers such as `video/avc` and `video/hevc`.

- [ ] **Step 1: Write failing route/capability consistency tests**

```kotlin
@Test
fun `every explicit supported format has a MIME route`() {
    val explicit = YlAndroidChannel.supportedFormats.filterNot { it == "automatic" }
    assertTrue(explicit.all { YlAndroidChannel.mimeType(it) != null })
    assertTrue("mov" in explicit)
    assertTrue("avi" in explicit)
    assertEquals(explicit.size, explicit.toSet().size)
}

@Test
fun `capability codecs remain canonical MIME strings`() {
    val capabilities = YlAndroidChannel.capabilities(
        hardwareVideoCodecs = listOf("video/hevc", "video/avc"),
        maxWidth = 1920,
        maxHeight = 1080,
    )
    assertEquals(listOf("video/avc", "video/hevc"), capabilities["hardwareVideoCodecs"])
}
```

- [ ] **Step 2: Run the focused test and verify failure**

```bash
./gradlew :yl_player_android:testDebugUnitTest --tests '*YlAndroidChannelTest'
```

Expected: compilation fails because `YlAndroidChannel` does not exist.

- [ ] **Step 3: Centralize routing and capability encoding**

Move the current `mimeType` mapping into `YlAndroidChannel`, define the exact
supported list above, and have the lazy capability snapshot call one encoder.
Sort and de-duplicate codec MIME values in the encoder. Move
`PlayerConfiguration`, `AndroidQualityConstraint`, `AudioSelection`,
`errorMap`, and `asStringMap` to this file so the eventual plugin split has no
private cross-file blockers. Change the defensive native configuration default
from `preferHardware` to `hardwareOnly` and assert that value in the channel
test; explicit legacy `preferHardware` input remains accepted and resolves to
the existing hardware-only selector.

- [ ] **Step 4: Run focused and complete native tests**

```bash
./gradlew :yl_player_android:testDebugUnitTest --tests '*YlAndroidChannelTest'
./gradlew :yl_player_android:testDebugUnitTest
```

Expected: all tests pass and capability formats exactly match routing support.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_android/android/src/main packages/yl_player_android/android/src/test
git commit -m "fix(android): align formats and capabilities"
```

### Task 4: Versioned full-state and compact delta envelopes

**Files:**
- Modify: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlAndroidChannel.kt`
- Modify: `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlAndroidChannelTest.kt`
- Modify: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerAndroidPlugin.kt`

**Interfaces:**
- Produces: `YlAndroidChannel.fullStateEnvelope(playerId: Long, generation: Long, state: Map<String, Any?>)`.
- Produces: `YlAndroidChannel.stateDeltaEnvelope(playerId: Long, generation: Long, delta: Map<String, Any?>)`.
- Envelope keys match Dart protocol version 1: `protocolVersion`, `generation`, `type`, and `state` or `delta`.

- [ ] **Step 1: Write failing envelope shape tests**

```kotlin
@Test
fun `delta envelope carries no static state`() {
    val envelope = YlAndroidChannel.stateDeltaEnvelope(
        playerId = 7,
        generation = 3,
        delta = mapOf(
            "positionMs" to 1000L,
            "bufferedPositionMs" to 3000L,
            "isAtLiveEdge" to false,
            "liveOffsetMs" to 2500L,
            "metrics" to mapOf("droppedVideoFrames" to 2),
        ),
    )
    assertEquals(1, envelope["protocolVersion"])
    assertEquals("stateDelta", envelope["type"])
    val delta = envelope["delta"] as Map<*, *>
    assertFalse(delta.containsKey("tracks"))
    assertFalse(delta.containsKey("capabilities"))
    assertFalse(delta.containsKey("decoderName"))
}
```

Also test that a full envelope includes the same generation and the full state map.

- [ ] **Step 2: Run the channel test and verify failure**

```bash
./gradlew :yl_player_android:testDebugUnitTest --tests '*YlAndroidChannelTest'
```

Expected: compilation fails because the envelope builders do not exist.

- [ ] **Step 3: Add builders and use deltas only from the ticker**

Implement the two pure envelope builders. Keep `emitState(error)` as the semantic full-snapshot path, add `emitPositionDelta()`, and change only `positionTicker.run()` from `emitState()` to `emitPositionDelta()`.

The delta map must contain:

```kotlin
mapOf(
    "positionMs" to position,
    "bufferedPositionMs" to bufferedPosition,
    "isAtLiveEdge" to (liveOffset != null && liveOffset <= 2_000L),
    "liveOffsetMs" to liveOffset,
    "metrics" to dynamicMetricsMap(bufferedDuration, liveOffset),
)
```

Include protocol version and `sourceGeneration` on every full state and delta. `onListen` already invokes each player's full `emitState`, satisfying initial synchronization.

- [ ] **Step 4: Run Android native and Dart channel tests**

```bash
./gradlew :yl_player_android:testDebugUnitTest
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
flutter test packages/yl_player_platform_interface/test/channel_player_test.dart packages/yl_player_android/test/yl_player_android_test.dart
```

Expected: native envelope tests and Dart generation/merge tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_android/android
git commit -m "perf(android): send compact position deltas"
```

### Task 5: Split plugin registration from Media3 playback

**Files:**
- Create: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3Player.kt`
- Modify: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerAndroidPlugin.kt`
- Modify if visibility requires it: existing files under `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/`

**Interfaces:**
- Consumes: `PlayerConfiguration`, `NetworkConfiguration`, `YlAndroidChannel`, and `YlFirstFrameGate` from prior tasks.
- Produces: package-internal `YlMedia3Player` with the same constructor and methods currently used by the plugin: `command`, `validateOpen`, `activate`, `deactivate`, `releaseForLifecycle`, `restoreAfterForeground`, `rebuildVideoOutput`, `handleRunningLowMemory`, `emitState`, and `dispose`.

- [ ] **Step 1: Record the passing extraction safety net**

Run:

```bash
./gradlew :yl_player_android:testDebugUnitTest
```

Expected: all native tests pass before the mechanical move.

- [ ] **Step 2: Move `Media3Player` without changing its algorithms**

Move the entire Media3 class into `YlMedia3Player.kt`, rename it from private `Media3Player` to internal `YlMedia3Player`, and update registry/callback references. Leave the plugin file responsible only for Flutter attachment, method/event routing, player ownership, one-active-player arbitration, and Android application callbacks.

Do not reorder the demux/load-control/health/lifecycle operations during this task. Any needed helper visibility changes must be `internal`, not public.

- [ ] **Step 3: Format Kotlin and rerun the complete native suite**

Run:

```bash
./gradlew :yl_player_android:testDebugUnitTest
```

Expected: all tests pass with the same count as Step 1.

- [ ] **Step 4: Verify file responsibility boundaries**

Run from repository root:

```bash
rg -n "ExoPlayer|AnalyticsListener|onRenderedFirstFrame" packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerAndroidPlugin.kt
rg -n "class YlPlayerAndroidPlugin|MethodChannel.MethodCallHandler" packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3Player.kt
```

Expected: both searches return no matches. The plugin has no Media3 callbacks; the player file has no Flutter plugin-registration class.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_android/android/src/main
git commit -m "refactor(android): split Media3 player from plugin"
```

### Task 6: AGP 9 cleanup and texture compatibility decision

**Files:**
- Modify: `packages/yl_player_android/android/build.gradle.kts`
- Modify: `packages/yl_player_android/example/android/gradle.properties`
- Modify: `packages/yl_player_android/example/android/settings.gradle.kts`
- Modify: `packages/yl_player/example/android/gradle.properties`
- Modify: `packages/yl_player/example/android/settings.gradle.kts`
- Modify: `packages/yl_player/README.md`

**Interfaces:**
- Produces: AGP 9 built-in Kotlin/new DSL configuration without `android.newDsl=false` or `android.builtInKotlin=false`.
- Records: `SurfaceTextureEntry` remains the chosen Flutter 3.44/API 24 texture contract for this release; `SurfaceProducer` is not adopted without equivalent tested restoration behavior.

- [ ] **Step 1: Capture current warning and lifecycle baseline**

Run:

```bash
./gradlew :yl_player_android:testDebugUnitTest --warning-mode all
```

Expected before cleanup: warnings identify the two deprecated Android flags; all lifecycle tests pass.

- [ ] **Step 2: Remove deprecated compatibility switches**

Delete these lines from both example `gradle.properties` files:

```properties
android.newDsl=false
android.builtInKotlin=false
```

Remove the external Kotlin Gradle plugin classpath from the plugin `build.gradle.kts` and the unused `org.jetbrains.kotlin.android` `apply false` declaration from both example settings files. Retain JVM 17, compile SDK 36, minimum SDK 24, and the `src/main/kotlin` source set.

- [ ] **Step 3: Build and test both Android hosts**

Run from `packages/yl_player_android/example/android`:

```bash
./gradlew clean :app:assembleDebug :yl_player_android:testDebugUnitTest --warning-mode all
```

Then run from `packages/yl_player/example/android`:

```bash
./gradlew clean :app:assembleDebug --warning-mode all
```

Expected: both builds pass and the removed-flag warnings do not appear.

- [ ] **Step 4: Document and verify the texture decision**

In the README platform notes, state that Android uses Flutter's `SurfaceTextureEntry` on the current Flutter 3.44/API 24 compatibility floor and restores output through the tested `YlVideoOutput` generation lifecycle. Do not claim `SurfaceProducer` parity.

Run:

```bash
./gradlew :yl_player_android:testDebugUnitTest --tests '*YlLifecyclePolicyTest'
```

Expected: configuration-change, stale-generation, background release, and foreground restoration cases pass.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_android/android packages/yl_player_android/example/android packages/yl_player/example/android packages/yl_player/README.md
git commit -m "build(android): adopt AGP 9 defaults"
```

### Task 7: Android-phase verification

**Files:**
- Modify only if verification exposes a defect: Android files changed in Tasks 1–6.

**Interfaces:**
- Produces: a clean, tested Android phase ready for the iOS and final-verification plans.

- [ ] **Step 1: Run the entire Android and Dart foundation checks**

```bash
cd /Users/yy2021_8689/Desktop/Flutter/yl_player/packages/yl_player_android/example/android
./gradlew testDebugUnitTest
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
sh tool/check_foundation.sh
git diff --check
```

Expected: all 47 existing native tests plus new tests pass, every Dart check passes, and there are no whitespace errors.

- [ ] **Step 2: Commit only verification-driven corrections**

```bash
git add packages/yl_player_android packages/yl_player_platform_interface packages/yl_player
git commit -m "test(android): close optimization regressions"
```

If no files changed, do not create an empty commit.
