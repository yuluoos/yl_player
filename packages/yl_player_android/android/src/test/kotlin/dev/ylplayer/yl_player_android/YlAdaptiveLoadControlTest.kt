package dev.ylplayer.yl_player_android

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class YlAdaptiveLoadControlTest {
    private val profile = YlBufferProfile(
        minBufferMs = 4_000,
        maxBufferMs = 15_000,
        targetBufferBytes = 24 * MIB,
    )

    @Test
    fun `loading continues below minimum while byte budget remains`() {
        assertTrue(shouldContinueLoading(1_000, 8 * MIB, profile))
    }

    @Test
    fun `byte ceiling wins over additional buffer time`() {
        assertFalse(shouldContinueLoading(1_000, 24 * MIB, profile))
        assertFalse(shouldContinueLoading(8_000, 24 * MIB, profile))
    }

    @Test
    fun `loading stops at maximum duration`() {
        assertFalse(shouldContinueLoading(15_000, 8 * MIB, profile))
        assertFalse(shouldContinueLoading(16_000, 8 * MIB, profile))
    }

    @Test
    fun `loading continues between duration limits while bytes remain`() {
        assertTrue(shouldContinueLoading(8_000, 8 * MIB, profile))
    }

    @Test
    fun `playback start uses bounded initial and rebuffer thresholds`() {
        assertFalse(shouldStartPlayback(999, playbackSpeed = 1f, rebuffering = false, profile))
        assertTrue(shouldStartPlayback(1_000, playbackSpeed = 1f, rebuffering = false, profile))
        assertFalse(shouldStartPlayback(1_999, playbackSpeed = 1f, rebuffering = true, profile))
        assertTrue(shouldStartPlayback(2_000, playbackSpeed = 1f, rebuffering = true, profile))
    }

    @Test
    fun `playback speed reduces playout duration`() {
        assertFalse(shouldStartPlayback(1_500, playbackSpeed = 2f, rebuffering = false, profile))
        assertTrue(shouldStartPlayback(2_000, playbackSpeed = 2f, rebuffering = false, profile))
    }

    @Test
    fun `memory shrink is idempotent until restore`() {
        val control = YlAdaptiveLoadControl(profile)

        control.shrinkForMemoryPressure()
        assertEquals(18 * MIB, control.targetBufferBytes)
        control.shrinkForMemoryPressure()
        assertEquals(18 * MIB, control.targetBufferBytes)

        control.restoreProfile()
        assertEquals(24 * MIB, control.targetBufferBytes)
    }

    @Test
    fun `new source profile replaces pressure state`() {
        val control = YlAdaptiveLoadControl(profile)
        control.shrinkForMemoryPressure()

        control.updateProfile(YlBufferProfile(2_000, 5_000, 12 * MIB))

        assertEquals(12 * MIB, control.targetBufferBytes)
        assertEquals(2_000, control.currentProfile.minBufferMs)
        assertEquals(5_000, control.currentProfile.maxBufferMs)
    }

    private companion object {
        const val MIB = 1024 * 1024
    }
}
