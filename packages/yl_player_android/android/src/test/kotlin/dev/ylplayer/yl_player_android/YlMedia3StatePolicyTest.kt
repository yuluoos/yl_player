package dev.ylplayer.yl_player_android

import androidx.media3.common.Player
import kotlin.test.Test
import kotlin.test.assertEquals

class YlMedia3StatePolicyTest {
    @Test
    fun `a paused seek remains paused when buffering finishes`() {
        assertEquals("paused", YlMedia3StatePolicy.status("buffering", Player.STATE_READY, false, pausedAfterPlayback = true))
        assertEquals("ready", YlMedia3StatePolicy.status("opening", Player.STATE_READY, false))
        assertEquals("completed", YlMedia3StatePolicy.status("paused", Player.STATE_ENDED, false, pausedAfterPlayback = true))
    }

    @Test
    fun `initial buffering does not establish readiness`() {
        assertEquals("opening", YlMedia3StatePolicy.status("opening", Player.STATE_BUFFERING, false, false))
        assertEquals("buffering", YlMedia3StatePolicy.status("ready", Player.STATE_BUFFERING, false, true))
    }

    @Test
    fun `terminal error survives later ready and idle callbacks`() {
        assertEquals(
            "error",
            YlMedia3StatePolicy.status("error", Player.STATE_READY, isPlaying = false),
        )
        assertEquals(
            "error",
            YlMedia3StatePolicy.status("error", Player.STATE_IDLE, isPlaying = false),
        )
        assertEquals(
            "error",
            YlMedia3StatePolicy.readyStatus("error", isPlaying = false),
        )
    }
}
