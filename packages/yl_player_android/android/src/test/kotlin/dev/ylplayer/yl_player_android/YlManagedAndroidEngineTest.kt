package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.AndroidVideoConstraintsMessage
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
    private val preparationFailure: YlFailureKind? = null,
    private val activationFailure: YlFailureKind? = null,
) : YlPlaybackEngineAdapter {
    private var callback: ((YlSessionIdentity, YlEngineEvent) -> Unit)? = null
    private val identity = YlSessionIdentity("s", "r")
    var prepareCount = 0
    var activateCount = 0
    var volume = 1.0
    var speed = 1.0
    var playing = false
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
    override suspend fun setVideoConstraints(constraints: AndroidVideoConstraintsMessage) = Unit
    override suspend fun setVolume(volume: Double) { this.volume = volume }
    override suspend fun stop() = Unit
    override fun dispose(): Deferred<Unit> = CompletableDeferred(Unit)
    override suspend fun onForeground() = Unit
    override suspend fun onBackground() = Unit
    override suspend fun onTrimMemory(level: Int) = Unit
    override suspend fun onConfigurationChanged() = Unit
}
