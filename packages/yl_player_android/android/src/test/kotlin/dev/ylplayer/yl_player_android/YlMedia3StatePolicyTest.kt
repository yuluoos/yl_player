package dev.ylplayer.yl_player_android

import androidx.media3.common.Player
import kotlin.test.Test
import kotlin.test.assertEquals

class YlMedia3StatePolicyTest {
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
