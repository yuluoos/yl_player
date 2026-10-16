package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class YlLivePlaybackModeTest {
    private fun FakeSessionEngine.live() = emit(YlEngineEvent.Snapshot(YlEngineSnapshot(
        status = AndroidPlaybackStatus.PAUSED, timeline = emptyTimeline().copy(isLive = true),
        livePlayback = AndroidLivePlaybackStateMessage(AndroidLivePlaybackMode.SMOOTH_PLAYBACK, AndroidLivePlaybackMode.entries))))
    @Test fun `native FIFO commits each request and preserves rejection between successes`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val id = f.coordinator.load(request("live")).sessionId
        val engine = f.engines.single(); engine.live()
        val held = CompletableDeferred<Unit>(); engine.liveModeAcknowledgement = held
        engine.rejectedModeRequest = 2
        val requests = (1L..3L).map { n -> async { runCatching { f.coordinator.setLivePlaybackMode(
            AndroidLivePlaybackModeCommand(id,n,if(n==2L) AndroidLivePlaybackMode.SMOOTH_PLAYBACK else AndroidLivePlaybackMode.LOW_LATENCY)) } } }
        runCurrent(); assertEquals(listOf(1L),engine.modeCalls.map { it.second })
        held.complete(Unit); runCurrent()
        val results = requests.map { it.await() }
        assertEquals(listOf(1L,2L,3L), engine.modeCalls.map { it.second })
        assertTrue(results[0].isSuccess); assertTrue(results[1].isFailure); assertTrue(results[2].isSuccess)
        val first = results[0].getOrThrow(); val last = results[2].getOrThrow()
        assertTrue(last.committedRevision > first.committedRevision)
        assertEquals(last.committedRevision, f.coordinator.initialState.revision)
        assertEquals(3L, f.coordinator.initialState.livePlayback!!.committedRequestId)
        assertFalse(engine.playing); assertEquals(0,engine.playCalls)
        f.finish()
    }
    @Test fun `stop immediately cancels native pending modes and late worker cannot publish`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val id = f.coordinator.load(request("live")).sessionId
        val engine = f.engines.single(); engine.live()
        val held = CompletableDeferred<Unit>(); engine.liveModeAcknowledgement = held
        val mode = async { runCatching { f.coordinator.setLivePlaybackMode(AndroidLivePlaybackModeCommand(id,1,AndroidLivePlaybackMode.LOW_LATENCY)) } }
        runCurrent(); val stop = async { f.coordinator.stop() }; runCurrent()
        assertTrue(mode.isCompleted); assertTrue(mode.await().isFailure)
        held.complete(Unit); stop.await(); runCurrent()
        assertNull(f.coordinator.initialState.livePlayback); assertNull(f.coordinator.initialState.sessionId)
        f.finish()
    }
    @Test fun `duplicate IDs background and unknown live state reject before worker`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val id = f.coordinator.load(request("live")).sessionId
        val engine = f.engines.single()
        assertFailsWith<YlBoundaryException> { f.coordinator.setLivePlaybackMode(AndroidLivePlaybackModeCommand(id,1,AndroidLivePlaybackMode.LOW_LATENCY)) }
        engine.live()
        assertFailsWith<YlBoundaryException> { f.coordinator.setLivePlaybackMode(AndroidLivePlaybackModeCommand(id,1,AndroidLivePlaybackMode.LOW_LATENCY)) }
        f.coordinator.onBackground(); runCurrent()
        assertFailsWith<YlBoundaryException> { f.coordinator.setLivePlaybackMode(AndroidLivePlaybackModeCommand(id,2,AndroidLivePlaybackMode.LOW_LATENCY)) }
        assertTrue(engine.modeCalls.isEmpty()); f.finish()
    }
}
