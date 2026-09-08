package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import kotlin.test.*

class YlStateReducerTest {
    @Test fun `output replacement rejects old public output without consuming the milestone`() {
        val events = SessionEvents()
        val reducer = YlStateReducer(events)
        reducer.commit(YlSessionIdentity("a1-s1", "r1"), YlOutputIdentity(1, true))
        reducer.updateOutput(YlOutputIdentity(2, true))
        reducer.firstFrame(YlOutputIdentity(1, true), 1)
        reducer.firstFrame(YlOutputIdentity(2, true), 2)
        assertEquals(2L, events.frames.single().occurredAtMs)
    }
    @Test fun `timeline metadata changes publish full state and metrics only snapshots use delta`() {
        val events = SessionEvents()
        val reducer = YlStateReducer(events)
        reducer.commit(YlSessionIdentity("a1-s1", "r1"), YlOutputIdentity(1, true))
        val initial = YlEngineSnapshot(status = AndroidPlaybackStatus.READY)
        reducer.snapshot(initial)
        reducer.snapshot(initial.copy(metrics = AndroidMetricsMessage(droppedVideoFrames = 3)))
        assertEquals(2, events.states.size)
        assertEquals(1, events.deltas.size)
        reducer.tick(emptyTimeline().copy(durationMs = 100, isSeekable = true), AndroidMetricsMessage())
        assertEquals(100L, events.states.last().timeline.durationMs)
        assertTrue(events.states.last().timeline.isSeekable)
    }
    @Test fun `semantic changes and timeline deltas each own consecutive revisions and sequences`() {
        val events = SessionEvents()
        val reducer = YlStateReducer(events)
        assertEquals(0, reducer.state.revision)
        assertEquals(0, reducer.state.sequence)
        reducer.commit(YlSessionIdentity("a1-s1", "r1"), YlOutputIdentity(1, true))
        reducer.snapshot(YlEngineSnapshot(status = AndroidPlaybackStatus.READY, timeline = emptyTimeline().copy(isSeekable = true)))
        reducer.tick(AndroidTimelineMessage(42, bufferedPositionMs = 99, isSeekable = true, isLive = false), AndroidMetricsMessage(droppedVideoFrames = 2))
        assertEquals(listOf(1L, 2L), events.states.map { it.revision })
        val delta = events.deltas.single()
        assertEquals(2L, delta.previousRevision)
        assertEquals(3L, delta.revision)
        assertEquals(3L, delta.sequence)
        assertEquals(42L, reducer.state.timeline.positionMs)
        reducer.snapshot(YlEngineSnapshot(status = AndroidPlaybackStatus.PLAYING))
        assertEquals(4L, events.states.last().revision)
        assertEquals(4L, events.states.last().sequence)
    }
    @Test fun `initial buffering remains loading and later buffering retains reached Ready`() {
        val reducer = YlStateReducer(SessionEvents())
        reducer.commit(YlSessionIdentity("a1-s1", "r1"), YlOutputIdentity(1, true))
        reducer.snapshot(YlEngineSnapshot(status = AndroidPlaybackStatus.BUFFERING))
        assertEquals(AndroidPlaybackStatus.LOADING, reducer.state.status)
        reducer.snapshot(YlEngineSnapshot(status = AndroidPlaybackStatus.READY))
        reducer.snapshot(YlEngineSnapshot(status = AndroidPlaybackStatus.BUFFERING))
        assertEquals(AndroidPlaybackStatus.BUFFERING, reducer.state.status)
        reducer.commit(YlSessionIdentity("a1-s2", "r2"), YlOutputIdentity(1, true))
        reducer.snapshot(YlEngineSnapshot(status = AndroidPlaybackStatus.BUFFERING, reachedReady = true))
        assertEquals(AndroidPlaybackStatus.BUFFERING, reducer.state.status)
    }
    @Test fun `failures and public frame milestones deduplicate independently of state revisions`() {
        val events = SessionEvents()
        val reducer = YlStateReducer(events)
        val output = YlOutputIdentity(1, true)
        reducer.commit(YlSessionIdentity("a1-s1", "r1"), output)
        reducer.firstFrame(YlOutputIdentity(2, false), 1)
        repeat(2) { reducer.firstFrame(output, 2) }
        assertEquals(1, events.frames.size)
        repeat(2) { reducer.fail(YlFailureKind.NETWORK_FAILED) }
        assertEquals(1, events.failures.size)
        assertEquals(listOf(1L, 2L), events.states.map { it.revision })
        assertEquals(listOf(1L, 3L), events.states.map { it.sequence })
        assertEquals(4L, events.failures.single().sequence)
        assertEquals("r1", reducer.state.loadRequestId)
    }
}
