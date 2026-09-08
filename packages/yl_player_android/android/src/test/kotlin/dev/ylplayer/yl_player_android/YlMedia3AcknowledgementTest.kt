package dev.ylplayer.yl_player_android

import kotlin.test.*

class YlMedia3AcknowledgementTest {
    @Test fun `normal native return with synchronous timeout callback is not acknowledged`() {
        val acknowledgement = YlMedia3Acknowledgement()
        assertFalse(acknowledgement.perform { acknowledgement.onTimeout() })
        assertFalse(acknowledgement.isSafe)
    }
    @Test fun `successful output operation cannot clear earlier unknown release`() {
        val acknowledgement = YlMedia3Acknowledgement()
        acknowledgement.onTimeout()
        assertFalse(acknowledgement.perform { })
    }
    @Test fun `throwing native operation remains unsafe and successful operation is acknowledged`() {
        assertTrue(YlMedia3Acknowledgement().perform { })
        val failed = YlMedia3Acknowledgement()
        assertFalse(failed.perform { throw IllegalStateException() })
        assertFalse(failed.isSafe)
    }
}
