package dev.ylplayer.yl_player_android

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class YlPlaybackStallWatchdogTest {
    @Test
    fun `first frame timeout reports network failure`() {
        var scheduledDelayMs: Long? = null
        var scheduledAction: (() -> Unit)? = null
        val watchdog = YlPlaybackStallWatchdog { delayMs, action ->
            scheduledDelayMs = delayMs
            scheduledAction = action
        }
        var failure: YlStableError? = null
        var diagnostic: String? = null

        watchdog.update(
            active = true,
            wantsToPlay = true,
            hasCurrentItem = true,
            isBuffering = false,
            firstFrameRendered = false,
            timeoutMs = 12_000,
            playbackState = "playing",
        ) { error, details ->
            failure = error
            diagnostic = details
        }

        assertEquals(12_000L, scheduledDelayMs)
        scheduledAction?.invoke()
        assertEquals("network", failure?.category)
        assertEquals("media3.first_frame_timeout", failure?.code)
        assertEquals(
            "Media3(phase=firstFrame, timeoutMs=12000, state=playing)",
            diagnostic,
        )
    }

    @Test
    fun `rebuffer timeout reports network failure after first frame`() {
        var scheduledAction: (() -> Unit)? = null
        val watchdog = YlPlaybackStallWatchdog { _, action -> scheduledAction = action }
        var failure: YlStableError? = null
        var diagnostic: String? = null

        watchdog.update(
            active = true,
            wantsToPlay = true,
            hasCurrentItem = true,
            isBuffering = true,
            firstFrameRendered = true,
            timeoutMs = 15_000,
            playbackState = "buffering",
        ) { error, details ->
            failure = error
            diagnostic = details
        }

        scheduledAction?.invoke()
        assertEquals("network", failure?.category)
        assertEquals("media3.stall_timeout", failure?.code)
        assertEquals(
            "Media3(phase=rebuffer, timeoutMs=15000, state=buffering)",
            diagnostic,
        )
    }

    @Test
    fun `playback recovery cancels pending rebuffer failure`() {
        var scheduledAction: (() -> Unit)? = null
        val watchdog = YlPlaybackStallWatchdog { _, action -> scheduledAction = action }
        val failures = mutableListOf<YlStableError>()

        watchdog.update(
            active = true,
            wantsToPlay = true,
            hasCurrentItem = true,
            isBuffering = true,
            firstFrameRendered = true,
            timeoutMs = 15_000,
            playbackState = "buffering",
        ) { error, _ -> failures += error }
        watchdog.update(
            active = true,
            wantsToPlay = true,
            hasCurrentItem = true,
            isBuffering = false,
            firstFrameRendered = true,
            timeoutMs = 15_000,
            playbackState = "playing",
        ) { error, _ -> failures += error }

        scheduledAction?.invoke()
        assertTrue(failures.isEmpty())
    }

    @Test
    fun `repeated refresh keeps original first frame deadline`() {
        val scheduledActions = mutableListOf<() -> Unit>()
        val watchdog = YlPlaybackStallWatchdog { _, action -> scheduledActions += action }
        val failures = mutableListOf<YlStableError>()

        repeat(2) {
            watchdog.update(
                active = true,
                wantsToPlay = true,
                hasCurrentItem = true,
                isBuffering = false,
                firstFrameRendered = false,
                timeoutMs = 15_000,
                playbackState = "playing",
            ) { error, _ -> failures += error }
        }

        assertEquals(1, scheduledActions.size)
        scheduledActions.first().invoke()
        assertEquals(listOf("media3.first_frame_timeout"), failures.map(YlStableError::code))
    }

    @Test
    fun `play intent cancellation suppresses pending timeout`() {
        var scheduledAction: (() -> Unit)? = null
        val watchdog = YlPlaybackStallWatchdog { _, action -> scheduledAction = action }
        val failures = mutableListOf<YlStableError>()

        watchdog.update(
            active = true,
            wantsToPlay = true,
            hasCurrentItem = true,
            isBuffering = true,
            firstFrameRendered = true,
            timeoutMs = 15_000,
            playbackState = "buffering",
        ) { error, _ -> failures += error }
        watchdog.update(
            active = true,
            wantsToPlay = false,
            hasCurrentItem = true,
            isBuffering = true,
            firstFrameRendered = true,
            timeoutMs = 15_000,
            playbackState = "paused",
        ) { error, _ -> failures += error }

        scheduledAction?.invoke()
        assertTrue(failures.isEmpty())
    }
}
