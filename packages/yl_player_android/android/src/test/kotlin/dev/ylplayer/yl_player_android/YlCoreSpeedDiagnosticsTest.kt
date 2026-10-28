package dev.ylplayer.yl_player_android

import android.os.SystemClock
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Timeline
import androidx.media3.exoplayer.analytics.AnalyticsListener
import org.mockito.Mockito.*
import kotlin.test.*

class YlCoreSpeedDiagnosticsTest {
    @Test fun `ticker reports observed symptoms at speed without changing playback`() {
        val lines = mutableListOf<String>()
        withCore(speedDiagnostics = YlPlaybackSpeedDiagnostics(lines::add)) { core, player, _ ->
            core.setPlaybackSpeed(1.5)
            `when`(player.playbackParameters).thenReturn(PlaybackParameters(1.5f))
            core.field("active", true)
            core.field("hasBeenReady", true)
            core.field("status", "playing")
            `when`(player.playWhenReady).thenReturn(true)
            `when`(player.currentPosition).thenReturn(1_000)
            `when`(player.bufferedPosition).thenReturn(10_000)
            val item = MediaItem.Builder().setMediaId("test").build()
            `when`(player.currentMediaItem).thenReturn(item)
            val event = AnalyticsListener.EventTime(0, Timeline.EMPTY, 0, null, 0, Timeline.EMPTY, 0, null, 0, 0)
            core.onBandwidthEstimate(event, 1_000, 100_000, 99_999_999)
            core.onDroppedVideoFrames(event, 2, 100)
            core.onAudioUnderrun(event, 1000, 10, 10)
            val ticker = core.javaClass.getDeclaredField("positionTicker").apply { isAccessible = true }.get(core) as Runnable
            clearInvocations(player)
            `when`(SystemClock.elapsedRealtime()).thenReturn(100L)
            ticker.run()
            assertEquals(1, lines.size)
            assertTrue(lines.single().contains("bufferedPlayoutMs=6000"))
            assertTrue(lines.single().contains("transferBitsPerSecond=800000"))
            assertTrue(lines.single().contains("droppedFrames=2 audioUnderruns=1"))
            `when`(player.playWhenReady).thenReturn(false)
            core.onDroppedVideoFrames(event, 4, 100)
            `when`(SystemClock.elapsedRealtime()).thenReturn(20_000L)
            ticker.run()
            assertEquals(1, lines.size)
            verify(player, never()).pause()
            verify(player, never()).stop()
            verify(player, never()).seekTo(anyLong())
            verify(player, never()).setPlaybackSpeed(anyFloat())
        }
    }
}
