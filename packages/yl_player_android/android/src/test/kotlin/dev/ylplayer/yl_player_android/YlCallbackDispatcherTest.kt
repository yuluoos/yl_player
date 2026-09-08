package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class YlCallbackDispatcherTest {
    @Test
    fun `attach gates all methods and each acknowledgement permits exactly one following item`() = runTest {
        val calls = mutableListOf<String>()
        val acknowledgements = ArrayDeque<CompletableDeferred<Unit>>()
        val callbacks = object : RecordingCallbacks() {
            override suspend fun onState(state: AndroidStateMessage) { calls += "state"; CompletableDeferred<Unit>().also(acknowledgements::add).await() }
            override suspend fun onFirstFrame(event: AndroidFirstFrameMessage) { calls += "frame"; CompletableDeferred<Unit>().also(acknowledgements::add).await() }
            override suspend fun onStateDelta(delta: AndroidStateDeltaMessage) { calls += "delta"; CompletableDeferred<Unit>().also(acknowledgements::add).await() }
        }
        val dispatcher = YlCallbackDispatcher(callbacks, StandardTestDispatcher(testScheduler)) { fail("Unexpected transport failure") }
        dispatcher.onState(idleState())
        dispatcher.onFirstFrame(AndroidFirstFrameMessage("s", 1, 2, 0))
        dispatcher.onStateDelta(AndroidStateDeltaMessage("s", 1, 2, 3, hasIsAtLiveEdge = false, hasLiveOffsetMs = false))
        runCurrent()
        assertTrue(calls.isEmpty())
        dispatcher.attach()
        dispatcher.attach()
        runCurrent()
        assertEquals(listOf("state"), calls)
        acknowledgements.removeFirst().complete(Unit)
        assertEquals(listOf("state"), calls, "Acknowledgement must post its continuation")
        runCurrent()
        assertEquals(listOf("state", "frame"), calls)
        acknowledgements.removeFirst().complete(Unit)
        runCurrent()
        assertEquals(listOf("state", "frame", "delta"), calls)
        dispatcher.close()
    }

    @Test
    fun `all six generated callback methods share one acknowledged queue and suffix`() = runTest {
        val fixture = RegistryFixture(StandardTestDispatcher(testScheduler))
        val player = fixture.registry.create(createRequest())
        fixture.call(player.channelSuffix, "attach")
        val sink = fixture.sessions.single().events!!
        val failure = AndroidFailureMessage(AndroidFailureCategory.NETWORK, "network.failed", "The network request failed.", true, AndroidFailureScope.SESSION, "fixture-diagnostic")
        sink.onState(idleState().copy(loadRequestId = "load-A"))
        sink.onFirstFrame(AndroidFirstFrameMessage("s", 1, 2, 0))
        sink.onStateDelta(AndroidStateDeltaMessage("s", 1, 2, 3, hasIsAtLiveEdge = false, hasLiveOffsetMs = false))
        sink.onRetryScheduled(AndroidRetryScheduledMessage("s", 2, 4, 0, 1, 50, failure))
        sink.onEngineChanged(AndroidEngineChangedMessage("s", 2, 5, 0, AndroidEngine.UNKNOWN, AndroidEngine.MEDIA3))
        sink.onPlaybackFailed(AndroidPlaybackFailedMessage("s", 2, 6, 0, failure))
        val methods = listOf("onState", "onFirstFrame", "onStateDelta", "onRetryScheduled", "onEngineChanged", "onPlaybackFailed")
        for ((index, method) in methods.withIndex()) {
            runCurrent()
            assertEquals(index + 1, fixture.outgoing.size)
            assertEquals("dev.flutter.pigeon.yl_player_android.AndroidPlayerFlutterApi.$method.${player.channelSuffix}", fixture.outgoingChannels[index])
            val ack = AndroidPlayerFlutterApi.codec.encodeMessage(listOf(null))!!.apply { flip() }
            fixture.outgoing[index].reply(ack)
            assertEquals(index + 1, fixture.outgoing.size)
        }
        runCurrent()
        assertEquals(6, fixture.outgoing.size)
        fixture.registry.detach()
        runCurrent()
    }

    @Test
    fun `callback error terminates once and never skips the failed milestone`() = runTest {
        val calls = mutableListOf<String>()
        val failures = mutableListOf<Throwable>()
        val dispatcher = YlCallbackDispatcher(object : RecordingCallbacks() {
            override suspend fun onState(state: AndroidStateMessage) { calls += "state"; throw IllegalStateException("private") }
            override suspend fun onFirstFrame(event: AndroidFirstFrameMessage) { calls += "frame" }
        }, StandardTestDispatcher(testScheduler), failures::add)
        dispatcher.attach()
        dispatcher.onState(idleState())
        dispatcher.onFirstFrame(AndroidFirstFrameMessage("s", 1, 2, 0))
        runCurrent()
        dispatcher.onState(idleState())
        dispatcher.attach()
        runCurrent()
        assertEquals(listOf("state"), calls)
        assertEquals(1, failures.size)
    }

    @Test
    fun `five second acknowledgement deadline is terminal`() = runTest {
        val failures = mutableListOf<Throwable>()
        val dispatcher = YlCallbackDispatcher(object : RecordingCallbacks() {
            override suspend fun onState(state: AndroidStateMessage) = awaitCancellation()
        }, StandardTestDispatcher(testScheduler), failures::add)
        dispatcher.attach()
        dispatcher.onState(idleState())
        runCurrent()
        advanceTimeBy(4_999)
        assertTrue(failures.isEmpty())
        advanceTimeBy(1)
        runCurrent()
        assertEquals(1, failures.size)
    }

    @Test
    fun `detach invalidates in flight acknowledgement and queued items`() = runTest {
        val acknowledgement = CompletableDeferred<Unit>()
        var calls = 0
        val dispatcher = YlCallbackDispatcher(object : RecordingCallbacks() {
            override suspend fun onState(state: AndroidStateMessage) { calls++; acknowledgement.await() }
        }, StandardTestDispatcher(testScheduler)) { fail("Dispose is not a delivery failure") }
        dispatcher.attach()
        dispatcher.onState(idleState())
        dispatcher.onState(idleState())
        runCurrent()
        dispatcher.close()
        acknowledgement.complete(Unit)
        advanceUntilIdle()
        assertEquals(1, calls)
    }

    @Test
    fun `snapshot copies caller owned track lists and keeps original load identity`() = runTest {
        var delivered: AndroidStateMessage? = null
        val tracks = mutableListOf<AndroidTrackMessage>()
        val dispatcher = YlCallbackDispatcher(object : RecordingCallbacks() {
            override suspend fun onState(state: AndroidStateMessage) { delivered = state }
        }, StandardTestDispatcher(testScheduler)) { fail("Unexpected failure") }
        dispatcher.onState(idleState().copy(loadRequestId = "old-load", audioTracks = tracks))
        tracks += AndroidTrackMessage("audio", AndroidTrackKind.AUDIO, isSelected = true)
        dispatcher.attach()
        runCurrent()
        assertEquals("old-load", delivered?.loadRequestId)
        assertEquals(emptyList(), delivered?.audioTracks)
        dispatcher.close()
    }
}

internal open class RecordingCallbacks : YlPlayerCallbacks {
    override suspend fun onState(state: AndroidStateMessage) = Unit
    override suspend fun onStateDelta(delta: AndroidStateDeltaMessage) = Unit
    override suspend fun onFirstFrame(event: AndroidFirstFrameMessage) = Unit
    override suspend fun onRetryScheduled(event: AndroidRetryScheduledMessage) = Unit
    override suspend fun onEngineChanged(event: AndroidEngineChangedMessage) = Unit
    override suspend fun onPlaybackFailed(event: AndroidPlaybackFailedMessage) = Unit
}

internal fun idleState() = AndroidStateMessage(
    revision = 0, sequence = 0, status = AndroidPlaybackStatus.IDLE,
    timeline = AndroidTimelineMessage(positionMs = 0, bufferedPositionMs = 0, isSeekable = false, isLive = false),
    audioTracks = emptyList(), videoTracks = emptyList(), engine = AndroidEngine.UNKNOWN,
    decoderMode = AndroidDecoderMode.UNKNOWN, metrics = AndroidMetricsMessage(),
)
