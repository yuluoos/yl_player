package dev.ylplayer.yl_player_android

import kotlin.test.*

class YlLiveModePolicyTest {
    @Test fun `HTTP FLV long pause refreshes only low live demand`() {
        val policy = YlHttpFlvResumePolicy()
        assertFalse(policy.requiresRefresh(low = true, live = true, nowMs = 5000))
        policy.paused(1000)
        assertFalse(policy.requiresRefresh(low = true, live = true, nowMs = 1200))
        policy.paused(2000)
        assertTrue(policy.requiresRefresh(low = true, live = true, nowMs = 5000))
        assertTrue(policy.requiresRefresh(low = true, live = true, nowMs = 5001)) // failed admission must not erase intent
        policy.clear()
        assertFalse(policy.requiresRefresh(low = true, live = true, nowMs = 5002))
        policy.paused(6000)
        assertFalse(policy.requiresRefresh(low = false, live = true, nowMs = 9000))
        policy.paused(10000)
        assertFalse(policy.requiresRefresh(low = true, live = false, nowMs = 13000))
    }

    @Test fun `absolute seek ends installed catch-up and respects explicit rate`() {
        val policy = YlLiveCatchUpPolicy()
        var installed = 1.03f
        policy.absoluteSeek(1f) { installed = it }
        assertEquals(1f, installed)
        assertFalse(policy.canCatchUp(low = true, playing = true, active = true, requestedSpeed = 1f))
        policy.absoluteSeek(1.5f) { installed = it }
        assertEquals(1.5f, installed)
        policy.automaticEdgeAllowed = true
        assertFalse(policy.canCatchUp(low = true, playing = false, active = true, requestedSpeed = 1f))
        assertTrue(policy.canCatchUp(low = true, playing = true, active = true, requestedSpeed = 1f))
    }
    @Test fun `RTMP low mode flushes pause backlog only on playback demand`() {
        val policy = YlRtmpLiveModePolicy()
        policy.paused()
        assertFalse(policy.shouldRefresh(low = false, playing = true, bufferedMs = 0, maxBufferMs = 2000))
        assertFalse(policy.shouldRefresh(low = true, playing = false, bufferedMs = 9000, maxBufferMs = 2000))
        assertTrue(policy.shouldRefresh(low = true, playing = true, bufferedMs = 0, maxBufferMs = 2000))
        policy.refreshed()
        assertFalse(policy.shouldRefresh(low = true, playing = true, bufferedMs = 0, maxBufferMs = 2000))
        assertTrue(policy.shouldRefresh(low = true, playing = true, bufferedMs = 9000, maxBufferMs = 2000))
    }
    @Test fun `mode refresh and transient recovery spend one lifetime budget`() {
        val recovery = YlRtmpRecovery()
        assertFalse(recovery.reserveLiveRefresh())
        recovery.committed = true
        assertTrue(recovery.reserveLiveRefresh())
        val oldEpoch = recovery.epoch
        recovery.invalidate()
        assertFalse(recovery.accepts(oldEpoch))
        assertEquals(1000L, recovery.next(YlFailureKind.RTMP_DISCONNECTED, true))
        assertTrue(recovery.reserveLiveRefresh())
        assertEquals(3, recovery.attempts)
        assertFalse(recovery.reserveLiveRefresh())
        assertNull(recovery.next(YlFailureKind.RTMP_DISCONNECTED, true))
    }
}
