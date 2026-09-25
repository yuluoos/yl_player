package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.AndroidVideoConstraintsMessage
import dev.ylplayer.yl_player_android.pigeon.AndroidVideoSelectionMessage
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class YlManagedAndroidEngineTest {
    @Test fun `track unavailable reason survives fallback snapshots and restoration until stop`() = runTest {
        assertFallbackRetainsReason("trackUnavailable")
    }

    @Test fun `explicit auto reason survives fallback snapshots and restoration until stop`() = runTest {
        assertFallbackRetainsReason("user")
    }

    private suspend fun kotlinx.coroutines.test.TestScope.assertFallbackRetainsReason(reason: String) {
        val primary = FakeManagedEngine()
        val fallback = FakeManagedEngine(videoSupport = false)
        val reducer = YlStateReducer(clockMs = { 0 })
        reducer.commit(YlSessionIdentity("s", "r"), FakeOutput.identity)
        val engine = YlManagedAndroidEngine(YlSessionIdentity("s", "r"), primary, { fallback },
            StandardTestDispatcher(testScheduler), clockMs = { 0 })
        engine.registerCallback { _, event ->
            when (event) {
                is YlEngineEvent.Snapshot -> reducer.snapshot(event.value)
                is YlEngineEvent.BackendChanged -> reducer.engineChanged(event)
                else -> Unit
            }
        }
        engine.prepare(); engine.activate(FakeOutput)
        if (reason == "user") engine.selectVideoTrack(null) else engine.selectVideoTrack("high")
        primary.snapshot(YlEngineSnapshot(videoSelection = AndroidVideoSelectionMessage(reason = reason)))
        assertEquals(reason, reducer.state.videoSelection!!.reason)
        primary.fail(YlFailureKind.DECODER_UNSUPPORTED)
        testScheduler.advanceUntilIdle()
        assertEquals(1, fallback.prepareCount)
        repeat(2) {
            fallback.snapshot(YlEngineSnapshot(timeline = emptyTimeline().copy(positionMs = it.toLong())))
            assertEquals(AndroidVideoSelectionMessage(reason = reason), reducer.state.videoSelection)
        }
        val restored = engine.quiesce()
        assertEquals(reason, restored.videoSelection.reason)
        engine.restore(restored, FakeOutput)
        fallback.snapshot(YlEngineSnapshot())
        assertEquals(reason, reducer.state.videoSelection!!.reason)
        engine.stop()
        fallback.snapshot(YlEngineSnapshot())
        assertEquals(AndroidVideoSelectionMessage(reason = "initial"), reducer.state.videoSelection)
        engine.dispose().await()
    }

    @Test fun `fixed selection delegates and blocks incompatible fallback until authoritative auto snapshot`() = runTest {
        val primary = FakeManagedEngine()
        val fallback = FakeManagedEngine(videoSupport = false)
        val events = mutableListOf<YlEngineEvent>()
        val engine = YlManagedAndroidEngine(YlSessionIdentity("s", "r"), primary, { fallback },
            StandardTestDispatcher(testScheduler), clockMs = { 0 })
        engine.registerCallback { _, event -> events += event }
        engine.prepare(); engine.activate(FakeOutput)
        assertTrue(engine.supportsVideoTrackSelection)
        engine.selectVideoTrack("high")
        assertEquals(listOf<String?>("high"), primary.videoCalls)
        primary.fail(YlFailureKind.DECODER_UNSUPPORTED)
        testScheduler.advanceUntilIdle()
        assertEquals(0, fallback.prepareCount)
        assertEquals(YlEngineEvent.Failed(YlFailureKind.DECODER_UNSUPPORTED), events.last())
        primary.snapshot(YlEngineSnapshot(videoSelection = dev.ylplayer.yl_player_android.pigeon.AndroidVideoSelectionMessage(reason = "trackUnavailable")))
        primary.fail(YlFailureKind.DECODER_UNSUPPORTED)
        testScheduler.advanceUntilIdle()
        assertEquals(1, fallback.prepareCount)
        kotlin.test.assertFalse(engine.supportsVideoTrackSelection)
        val unsupported = kotlin.test.assertFailsWith<YlBoundaryException> { engine.selectVideoTrack(null) }
        assertEquals(YlFailureKind.POLICY_UNSUPPORTED, unsupported.kind)
        engine.dispose().await()
    }

    @Test fun `rejected constraints do not poison later fallback policy`() = runTest {
        val primary = FakeManagedEngine()
        val fallback = FakeManagedEngine()
        val engine = YlManagedAndroidEngine(
            YlSessionIdentity("s", "r"), primary, { fallback },
            StandardTestDispatcher(testScheduler), clockMs = { 0 },
        )
        engine.prepare(); engine.activate(FakeOutput)
        val original = AndroidVideoConstraintsMessage(maxWidth = 1920)
        val rejected = AndroidVideoConstraintsMessage(maxWidth = 1280)
        engine.setVideoConstraints(original)
        primary.constraintsFailure = YlFailureKind.POLICY_UNSUPPORTED
        kotlin.test.assertFailsWith<YlBoundaryException> { engine.setVideoConstraints(rejected) }
        primary.fail(YlFailureKind.DECODER_UNSUPPORTED)
        testScheduler.advanceUntilIdle()
        assertEquals(listOf(original), fallback.constraintsCalls)
        engine.dispose().await()
    }
    @Test fun `disposal acknowledgement waits for owned release and completes without self cancellation`() = runTest {
        val released = CompletableDeferred<Unit>()
        val primary = FakeManagedEngine(release = released)
        val engine = YlManagedAndroidEngine(YlSessionIdentity("s", "r"), primary, { error("unexpected fallback") }, StandardTestDispatcher(testScheduler), clockMs = { 0 }, allowFallback = false)
        val disposal = engine.dispose()
        testScheduler.runCurrent()
        kotlin.test.assertFalse(disposal.isCompleted)
        kotlin.test.assertSame(disposal, engine.dispose())
        released.complete(Unit)
        disposal.await()
        kotlin.test.assertFalse(disposal.isCancelled)
    }

    @Test fun `already completed release remains successful with immediate dispatch`() = runTest {
        val engine = YlManagedAndroidEngine(YlSessionIdentity("s", "r"), FakeManagedEngine(), { error("unexpected fallback") }, kotlinx.coroutines.test.UnconfinedTestDispatcher(testScheduler), clockMs = { 0 }, allowFallback = false)
        val disposal = engine.dispose()
        assertTrue(disposal.isCompleted)
        disposal.await()
        kotlin.test.assertFalse(disposal.isCancelled)
        kotlin.test.assertSame(disposal, engine.dispose())
    }

    @Test fun `failed borrower release still waits for every other owned release`() = runTest {
        val released = CompletableDeferred<Unit>()
        val originalFailure = YlBoundaryException(YlFailureKind.PLATFORM_FAILURE)
        val failed = CompletableDeferred<Unit>().apply { completeExceptionally(originalFailure) }
        val primary = FakeManagedEngine(preparationFailure = YlFailureKind.DECODER_UNSUPPORTED, release = failed)
        val fallback = FakeManagedEngine(release = released)
        val engine = YlManagedAndroidEngine(YlSessionIdentity("s", "r"), primary, { fallback }, StandardTestDispatcher(testScheduler), clockMs = { 0 })
        engine.prepare()
        val disposal = engine.dispose()
        testScheduler.runCurrent()
        val completedBeforeAllBorrowers = disposal.isCompleted
        released.complete(Unit)
        val error = kotlin.test.assertFailsWith<YlBoundaryException> { disposal.await() }
        kotlin.test.assertFalse(completedBeforeAllBorrowers)
        kotlin.test.assertSame(originalFailure, error)
    }

    @Test fun `DASH disabled fallback preserves terminal prepare and asynchronous failures`() = runTest {
        val fallback = FakeManagedEngine()
        val primary = FakeManagedEngine(preparationFailure = YlFailureKind.CONTAINER_UNSUPPORTED)
        val engine = YlManagedAndroidEngine(YlSessionIdentity("s", "r"), primary, { fallback }, StandardTestDispatcher(testScheduler), clockMs = { 0 }, allowFallback = false)
        val failure = kotlin.test.assertFailsWith<YlBoundaryException> { engine.prepare() }
        assertEquals(YlFailureKind.CONTAINER_UNSUPPORTED, failure.kind)
        assertEquals(0, fallback.prepareCount)
        engine.dispose().await()
        testScheduler.advanceUntilIdle()
        val activePrimary = FakeManagedEngine()
        val active = YlManagedAndroidEngine(YlSessionIdentity("s", "r"), activePrimary, { fallback }, StandardTestDispatcher(testScheduler), clockMs = { 0 }, allowFallback = false)
        val events = mutableListOf<YlEngineEvent>()
        active.registerCallback { _, event -> events += event }
        active.prepare(); active.activate(FakeOutput)
        activePrimary.fail(YlFailureKind.CONTAINER_UNSUPPORTED)
        testScheduler.advanceUntilIdle()
        assertEquals(0, fallback.prepareCount)
        assertEquals(listOf<YlEngineEvent>(YlEngineEvent.Failed(YlFailureKind.CONTAINER_UNSUPPORTED)), events)
        active.dispose().await()
        testScheduler.advanceUntilIdle()
    }

    @Test
    fun `decoder failure during preparation publishes the backend switch`() = runTest {
        val primary = FakeManagedEngine(preparationFailure = YlFailureKind.DECODER_UNSUPPORTED)
        val fallback = FakeManagedEngine()
        val events = mutableListOf<YlEngineEvent>()
        val engine = YlManagedAndroidEngine(
            YlSessionIdentity("s", "r"), primary, { fallback }, StandardTestDispatcher(testScheduler),
            clockMs = { 42 },
        )
        engine.registerCallback { _, event -> events += event }

        engine.prepare()

        assertEquals(1, fallback.prepareCount)
        assertEquals(
            listOf(YlEngineEvent.BackendChanged::class),
            events.map { it::class },
        )
    }

    @Test
    fun `decoder failure during activation switches once and restores controls`() = runTest {
        val primary = FakeManagedEngine(activationFailure = YlFailureKind.DECODER_UNSUPPORTED)
        val fallback = FakeManagedEngine()
        val events = mutableListOf<YlEngineEvent>()
        val engine = YlManagedAndroidEngine(
            YlSessionIdentity("s", "r"), primary, { fallback }, StandardTestDispatcher(testScheduler),
            clockMs = { 0 },
        )
        engine.registerCallback { _, event -> events += event }
        engine.prepare()
        engine.setVolume(0.4)
        engine.setPlaybackSpeed(1.25)
        engine.play()
        engine.activate(FakeOutput)
        testScheduler.advanceUntilIdle()

        assertEquals(1, fallback.prepareCount)
        assertEquals(1, fallback.activateCount)
        assertEquals(0.4, fallback.volume)
        assertEquals(1.25, fallback.speed)
        assertTrue(fallback.playing)
        assertEquals(1, events.filterIsInstance<YlEngineEvent.BackendChanged>().size)

        fallback.fail(YlFailureKind.DECODER_UNSUPPORTED)
        testScheduler.advanceUntilIdle()
        assertEquals(1, fallback.prepareCount)
        assertTrue(events.last() is YlEngineEvent.Failed)
    }
}

private object FakeOutput : YlSessionVideoOutput {
    override val identity = YlOutputIdentity(1, true)
    override fun release() = Unit
}

private class FakeManagedEngine(
    private val videoSupport: Boolean = true,
    private val preparationFailure: YlFailureKind? = null,
    private val activationFailure: YlFailureKind? = null,
    private val release: Deferred<Unit> = CompletableDeferred(Unit),
) : YlPlaybackEngineAdapter {
    private var callback: ((YlSessionIdentity, YlEngineEvent) -> Unit)? = null
    private val identity = YlSessionIdentity("s", "r")
    var prepareCount = 0
    var activateCount = 0
    var volume = 1.0
    var speed = 1.0
    var playing = false
    var constraintsFailure: YlFailureKind? = null
    override val supportsVideoTrackSelection get() = videoSupport
    val videoCalls = mutableListOf<String?>()
    override suspend fun selectVideoTrack(trackId: String?) {
        if (!videoSupport) throw YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED)
        videoCalls += trackId
    }
    fun snapshot(value: YlEngineSnapshot) { callback?.invoke(identity, YlEngineEvent.Snapshot(value)) }
    val constraintsCalls = mutableListOf<AndroidVideoConstraintsMessage>()
    override fun registerCallback(callback: (YlSessionIdentity, YlEngineEvent) -> Unit) { this.callback = callback }
    fun fail(kind: YlFailureKind) { callback?.invoke(identity, YlEngineEvent.Failed(kind)) }
    override suspend fun prepare() {
        prepareCount++
        preparationFailure?.let { throw YlBoundaryException(it) }
    }
    override suspend fun activate(output: YlSessionVideoOutput) { activateCount++; activationFailure?.let { throw YlBoundaryException(it) } }
    override suspend fun quiesce() = YlEngineRestorePoint(1200, false, playing, speed = speed, volume = volume)
    override suspend fun restore(point: YlEngineRestorePoint, output: YlSessionVideoOutput) = Unit
    override suspend fun play() { playing = true }
    override suspend fun pause() { playing = false }
    override suspend fun seekTo(positionMs: Long) = Unit
    override suspend fun seekToLiveEdge() = Unit
    override suspend fun setPlaybackSpeed(speed: Double) { this.speed = speed }
    override suspend fun selectAudioTrack(trackId: String) = Unit
    override suspend fun setVideoConstraints(constraints: AndroidVideoConstraintsMessage) {
        constraintsFailure?.let { throw YlBoundaryException(it) }
        constraintsCalls += constraints
    }
    override suspend fun setVolume(volume: Double) { this.volume = volume }
    override suspend fun stop() = Unit
    override fun dispose(): Deferred<Unit> = release
    override suspend fun onForeground() = Unit
    override suspend fun onBackground() = Unit
    override suspend fun onTrimMemory(level: Int) = Unit
    override suspend fun onConfigurationChanged() = Unit
}
