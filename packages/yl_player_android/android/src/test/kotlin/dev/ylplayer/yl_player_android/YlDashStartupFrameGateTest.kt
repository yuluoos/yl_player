package dev.ylplayer.yl_player_android

import androidx.media3.exoplayer.audio.AudioSink
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class YlDashStartupFrameGateTest {
    @Test fun waitsForBothStartAndClockAdvance() {
        val gate = YlDashStartupFrameGate()
        assertTrue(gate.awaitAudio(100, false, 10))
        assertTrue(gate.awaitAudio(101, false, 15))
        assertTrue(gate.awaitAudio(100, true, 20))
        assertFalse(gate.awaitAudio(101, true, 25))
        gate.rendered()
        assertFalse(gate.awaitAudio(100, false, 30))
    }

    @Test fun stationaryClockHasOneDeadline() {
        val gate = YlDashStartupFrameGate()
        assertTrue(gate.awaitAudio(0, false, 10))
        assertTrue(gate.awaitAudio(0, true, 659))
        assertFalse(gate.awaitAudio(0, true, 660))
        assertFalse(gate.awaitAudio(0, true, 690))
    }

    @Test fun previewCancellationAndMissingClockReleaseTheHeldFrame() {
        val gate = YlDashStartupFrameGate()
        assertTrue(gate.awaitAudio(200, false, 1))
        assertFalse(gate.awaitAudio(null, false, 10))
        assertFalse(gate.holding)
        assertFalse(gate.awaitAudio(AudioSink.CURRENT_POSITION_NOT_SET, true, 20))
        assertTrue(gate.awaitAudio(300, true, 30))
        gate.cancelWait()
        assertFalse(gate.holding)
        assertTrue(gate.awaitAudio(500, true, 40))
        assertFalse(gate.awaitAudio(501, true, 45))
    }
}
