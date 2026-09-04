package dev.ylplayer.yl_player_android

import kotlin.test.Test
import kotlin.test.assertEquals

class YlPlaybackHealthMonitorTest {
    @Test
    fun `two unhealthy windows downgrade one step`() {
        val monitor = YlPlaybackHealthMonitor()

        assertEquals(YlRecoveryAction.None, monitor.record(unhealthyWindow(nowMs = 30_000)))
        assertEquals(
            YlRecoveryAction.DowngradeOneStep,
            monitor.record(unhealthyWindow(nowMs = 60_000)),
        )
    }

    @Test
    fun `downgrade cooldown is sixty seconds and never emits upgrade`() {
        val monitor = YlPlaybackHealthMonitor()
        monitor.record(unhealthyWindow(30_000))
        monitor.record(unhealthyWindow(60_000))

        assertEquals(YlRecoveryAction.None, monitor.record(unhealthyWindow(90_000)))
        assertEquals(
            YlRecoveryAction.DowngradeOneStep,
            monitor.record(unhealthyWindow(120_000)),
        )
        assertEquals(YlRecoveryAction.None, monitor.record(healthyWindow(150_000)))
    }

    @Test
    fun `drop ratio and rebuffer thresholds mark a window unhealthy`() {
        val ratioMonitor = YlPlaybackHealthMonitor()
        assertEquals(YlRecoveryAction.None, ratioMonitor.record(sample(30_000, dropped = 6, rendered = 100)))
        assertEquals(
            YlRecoveryAction.DowngradeOneStep,
            ratioMonitor.record(sample(60_000, dropped = 6, rendered = 100)),
        )

        val rebufferMonitor = YlPlaybackHealthMonitor()
        rebufferMonitor.record(sample(30_000, rebuffers = 2))
        assertEquals(
            YlRecoveryAction.DowngradeOneStep,
            rebufferMonitor.record(sample(60_000, rebufferMs = 3_001)),
        )
    }

    @Test
    fun `running low memory downgrades adaptive streams but keeps fixed streams alive`() {
        val adaptive = YlPlaybackHealthMonitor()
        assertEquals(
            YlRecoveryAction.DowngradeOneStep,
            adaptive.record(sample(1_000, memoryPressure = true)),
        )

        val fixed = YlPlaybackHealthMonitor()
        assertEquals(
            YlRecoveryAction.None,
            fixed.record(sample(1_000, memoryPressure = true, canDowngrade = false)),
        )
    }

    @Test
    fun `HLS catches up gently and resets speed inside target`() {
        val monitor = YlPlaybackHealthMonitor()
        assertEquals(
            YlRecoveryAction.SetCatchUpSpeed(1.03f),
            monitor.record(hlsSample(nowMs = 1_000, liveOffsetMs = 10_000)),
        )
        assertEquals(
            YlRecoveryAction.SetCatchUpSpeed(1f),
            monitor.record(hlsSample(nowMs = 2_000, liveOffsetMs = 7_000)),
        )
    }

    @Test
    fun `HLS forced live edge recovery is rate limited`() {
        val monitor = YlPlaybackHealthMonitor()
        assertEquals(
            YlRecoveryAction.SeekLiveEdge,
            monitor.record(hlsSample(nowMs = 1_000, liveOffsetMs = 16_000)),
        )
        assertEquals(
            YlRecoveryAction.SetCatchUpSpeed(1.03f),
            monitor.record(hlsSample(nowMs = 20_000, liveOffsetMs = 16_000)),
        )
        assertEquals(
            YlRecoveryAction.SeekLiveEdge,
            monitor.record(hlsSample(nowMs = 31_000, liveOffsetMs = 16_000)),
        )
    }

    @Test
    fun `HTTP FLV severe backlog reconnects and then exhausts`() {
        val monitor = YlPlaybackHealthMonitor()
        assertEquals(
            YlRecoveryAction.ReconnectLiveHead,
            monitor.record(flvSample(reconnectCount = 0)),
        )
        assertEquals(
            YlRecoveryAction.Fail(stableError(YlPlaybackFailure.LIVE_RETRY_EXHAUSTED)),
            monitor.record(flvSample(reconnectCount = 3)),
        )
    }

    private fun unhealthyWindow(nowMs: Long) = sample(nowMs, dropped = 61)

    private fun healthyWindow(nowMs: Long) = sample(nowMs)

    private fun sample(
        nowMs: Long,
        dropped: Int = 0,
        rendered: Int = 900,
        rebuffers: Int = 0,
        rebufferMs: Long = 0,
        memoryPressure: Boolean = false,
        canDowngrade: Boolean = true,
    ) = YlHealthSample(
        nowMs = nowMs,
        elapsedMs = 30_000,
        droppedFrames = dropped,
        estimatedRenderedFrames = rendered,
        rebufferCount = rebuffers,
        rebufferDurationMs = rebufferMs,
        memoryPressure = memoryPressure,
        canDowngrade = canDowngrade,
        sourceClass = YlSourceClass.NETWORK_VOD,
        liveOffsetMs = null,
        bufferedDurationMs = 0,
        targetLiveOffsetMs = 8_000,
        maxBufferMs = 15_000,
        reconnectCount = 0,
        maxRetries = 3,
    )

    private fun hlsSample(nowMs: Long, liveOffsetMs: Long) = sample(nowMs).copy(
        elapsedMs = 1_000,
        sourceClass = YlSourceClass.HLS_LIVE,
        liveOffsetMs = liveOffsetMs,
        targetLiveOffsetMs = 8_000,
        maxBufferMs = 12_000,
    )

    private fun flvSample(reconnectCount: Int) = sample(1_000).copy(
        elapsedMs = 1_000,
        sourceClass = YlSourceClass.HTTP_FLV_LIVE,
        bufferedDurationMs = 8_001,
        maxBufferMs = 5_000,
        reconnectCount = reconnectCount,
        maxRetries = 3,
    )
}
