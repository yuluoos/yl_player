package dev.ylplayer.yl_player_android

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class YlFirstFrameGateTest {
    @Test
    fun `only first current-generation callback is accepted`() {
        val gate = YlFirstFrameGate()
        gate.reset(4)

        assertTrue(gate.markRendered(4))
        assertFalse(gate.markRendered(4))
        assertFalse(gate.markRendered(3))
    }

    @Test
    fun `new source generation admits one new first frame`() {
        val gate = YlFirstFrameGate()
        gate.reset(4)
        assertTrue(gate.markRendered(4))

        gate.reset(5)

        assertTrue(gate.markRendered(5))
        assertFalse(gate.markRendered(5))
    }
}
