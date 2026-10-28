package dev.ylplayer.yl_player_android

import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Timeline
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.source.MediaSource.MediaPeriodId
import org.mockito.Mockito.*
import kotlin.test.*

class YlSpeedLoadControlTest {
    private val profile = YlBufferProfile(4_000, 15_000, 24 * 1024 * 1024)

    @Test fun `VOD at one and a half speed maintains fifteen seconds of playout`() {
        val control = YlAdaptiveLoadControl(profile)
        assertTrue(control.shouldContinueLoading(parameters(15_000, 1.5f)))
        assertTrue(control.shouldContinueLoading(parameters(22_499, 1.5f)))
        assertFalse(control.shouldContinueLoading(parameters(22_500, 1.5f)))
        assertEquals(24 * 1024 * 1024, control.targetBufferBytes)
    }

    @Test fun `speed changes do not compound targets and prefetch scaling stops at two times`() {
        val control = YlAdaptiveLoadControl(profile)
        assertTrue(control.shouldContinueLoading(parameters(29_999, 4f)))
        assertFalse(control.shouldContinueLoading(parameters(30_000, 4f)))
        assertFalse(control.shouldContinueLoading(parameters(15_000, 1f)))
        assertFalse(control.shouldContinueLoading(parameters(15_000, 0.5f)))
        assertTrue(control.shouldContinueLoading(parameters(14_999, 0.5f)))
        assertFalse(control.shouldContinueLoading(parameters(22_500, 1.5f)))
        assertEquals(profile, control.currentProfile)
    }

    @Test fun `actual allocator byte target wins even when media duration is insufficient`() {
        val control = YlAdaptiveLoadControl(profile.copy(targetBufferBytes = 2 * C.DEFAULT_BUFFER_SEGMENT_SIZE))
        val allocator = control.getAllocator(PlayerId.UNSET)
        val allocations = Array(2) { allocator.allocate() }
        try {
            assertFalse(control.shouldContinueLoading(parameters(100, 1.5f)))
            assertTrue(control.shouldStartPlayback(parameters(100, 1.5f)))
            assertFalse(control.shouldStartPlayback(parameters(0, 1.5f)))
        } finally { allocations.forEach(allocator::release); control.onReleased(PlayerId.UNSET) }
    }

    @Test fun `changing speed never revokes the memory pressure reduction`() {
        val control = YlAdaptiveLoadControl(profile.copy(targetBufferBytes = 4 * C.DEFAULT_BUFFER_SEGMENT_SIZE))
        control.shrinkForMemoryPressure()
        val allocator = control.getAllocator(PlayerId.UNSET)
        val allocations = Array(3) { allocator.allocate() }
        try {
            for (speed in listOf(1f, 1.5f, 2f, 1f)) {
                assertFalse(control.shouldContinueLoading(parameters(100, speed)))
                assertEquals(3 * C.DEFAULT_BUFFER_SEGMENT_SIZE, control.targetBufferBytes)
            }
        } finally { allocations.forEach(allocator::release); control.onReleased(PlayerId.UNSET) }
    }

    @Test fun `live dynamic unknown and ad periods keep their original time targets`() {
        val control = YlAdaptiveLoadControl(profile)
        assertFalse(control.shouldContinueLoading(parameters(15_000, 1.5f, live = true)))
        assertFalse(control.shouldContinueLoading(parameters(15_000, 1.5f, dynamic = true)))
        assertFalse(control.shouldContinueLoading(parameters(15_000, 1.5f, unknown = true)))
        assertFalse(control.shouldContinueLoading(parameters(15_000, 1.5f, ad = true)))
    }

    @Test fun `rebuffer startup still measures actual playout time`() {
        val control = YlAdaptiveLoadControl(profile)
        assertFalse(control.shouldStartPlayback(parameters(2_999, 1.5f)))
        assertTrue(control.shouldStartPlayback(parameters(3_000, 1.5f)))
    }

    private fun parameters(ms: Long, speed: Float, live: Boolean = false, dynamic: Boolean = false,
        unknown: Boolean = false, ad: Boolean = false): LoadControl.Parameters {
        val timeline = if (unknown) Timeline.EMPTY else mock(Timeline::class.java).also { timeline ->
            `when`(timeline.windowCount).thenReturn(1)
            `when`(timeline.getIndexOfPeriod("period")).thenReturn(0)
            `when`(timeline.getPeriod(eq(0), any(Timeline.Period::class.java), eq(false))).thenAnswer {
                (it.arguments[1] as Timeline.Period).apply { windowIndex = 0 }
            }
            `when`(timeline.getWindow(eq(0), any(Timeline.Window::class.java), eq(0L))).thenAnswer {
                (it.arguments[1] as Timeline.Window).apply {
                    isDynamic = dynamic
                    liveConfiguration = if (live) MediaItem.LiveConfiguration.Builder().build() else null
                }
            }
        }
        val id = if (ad) MediaPeriodId("period", 0, 0, 0L) else MediaPeriodId("period")
        return LoadControl.Parameters(PlayerId.UNSET, timeline, id, 0, ms * 1000, speed,
            true, true, C.TIME_UNSET, C.TIME_UNSET)
    }
}
