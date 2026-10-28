package dev.ylplayer.yl_player_android

import android.os.SystemClock
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.exoplayer.DecoderCounters
import androidx.media3.exoplayer.analytics.AnalyticsListener
import org.mockito.Mockito.*
import kotlin.test.*

class YlCoreFrameHealthTest {
    @Test fun `actual frames at high speed prevent false adaptive downgrade from a wall clock estimate`() {
        checkWindows(renderedPerWindow = 1350, droppedPerWindow = 50, expectedDowngrades = 0)
    }

    @Test fun `low actual output cannot be hidden by fictional rendered frames during a stall`() {
        checkWindows(renderedPerWindow = 100, droppedPerWindow = 6, expectedDowngrades = 1)
    }

    @Test fun `paused time and old frames are discarded before the next health window`() = withCore { core, player, _ ->
        val event = ready(core, player)
        val decoder = DecoderCounters()
        core.onVideoEnabled(event, decoder)
        tick(core, 0)
        decoder.renderedOutputBufferCount = 100
        decoder.droppedBufferCount = 10
        tick(core, 30_000) // One unhealthy window, not yet a downgrade.
        `when`(player.playWhenReady).thenReturn(false)
        core.onPlayWhenReadyChanged(event, false, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
        tick(core, 300_000)
        `when`(player.playWhenReady).thenReturn(true)
        core.onPlayWhenReadyChanged(event, true, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
        tick(core, 301_000)
        assertEquals(0, core.value("adaptiveDowngradeCount"))
        decoder.renderedOutputBufferCount = 200
        decoder.droppedBufferCount = 20
        tick(core, 330_000) // First fresh unhealthy window, not the second old one.
        assertEquals(0, core.value("adaptiveDowngradeCount"))
    }

    @Test fun `ongoing rebuffer duration is not counted again in subsequent windows`() = withCore { core, player, _ ->
        ready(core, player)
        core.field("bufferingStartedAtMs", 0L)
        core.field("status", "buffering")
        tick(core, 0)
        tick(core, 30_000)
        assertEquals(30_000L, core.value("healthWindowRebufferDurationMs"))
        // Buffering ends one second into the next window: only that second belongs to it.
        core.field("rebufferDurationMs", 31_000L)
        core.field("bufferingStartedAtMs", null)
        core.field("status", "playing")
        tick(core, 60_000)
        assertEquals(0, core.value("adaptiveDowngradeCount"))
    }

    private fun checkWindows(renderedPerWindow: Int, droppedPerWindow: Int, expectedDowngrades: Int) = withCore { core, player, _ ->
        val event = ready(core, player)
        val decoder = DecoderCounters()
        core.onVideoEnabled(event, decoder)
        tick(core, 0)
        for (window in 1..2) {
            decoder.renderedOutputBufferCount = renderedPerWindow * window
            decoder.droppedBufferCount = droppedPerWindow * window
            tick(core, 30_000L * window)
        }
        assertEquals(expectedDowngrades, core.value("adaptiveDowngradeCount"))
        verify(player, never()).setPlaybackSpeed(anyFloat())
        verify(player, never()).stop()
    }

    private fun ready(core: YlMedia3Core, player: androidx.media3.exoplayer.ExoPlayer): AnalyticsListener.EventTime {
        core.field("active", true)
        core.field("hasBeenReady", true)
        core.field("status", "playing")
        core.field("selectedVideoBitrate", 2_000_000)
        core.field("availableVideoBitrates", listOf(2_000_000, 1_000_000))
        `when`(player.playWhenReady).thenReturn(true)
        `when`(player.playbackParameters).thenReturn(PlaybackParameters(1.5f))
        val item = MediaItem.Builder().setMediaId("test").build()
        `when`(player.currentMediaItem).thenReturn(item)
        return AnalyticsListener.EventTime(0, Timeline.EMPTY, 0, null, 0, Timeline.EMPTY, 0, null, 0, 0)
    }

    private fun tick(core: YlMedia3Core, now: Long) {
        `when`(SystemClock.elapsedRealtime()).thenReturn(now)
        (core.value("positionTicker") as Runnable).run()
    }
    private fun YlMedia3Core.value(name: String): Any? = javaClass.getDeclaredField(name).apply { isAccessible = true }.get(this)
}
