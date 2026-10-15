package dev.ylplayer.yl_player_android

import kotlin.test.*

class YlAnnexBTest {
    @Test fun `mixed start codes preserve all parameter SEI and picture payloads`() {
        val input=byteArrayOf(0,0,0,1,6,5,0,0,3,1,0,0,1,7,9,0,0,0,1,8,3,0,0,1,5,42)
        val expected=byteArrayOf(0,0,0,1,6,5,0,0,3,1,0,0,0,1,7,9,0,0,0,1,8,3,0,0,0,1,5,42)
        assertContentEquals(expected,canonicalAnnexB(input))
        assertContentEquals(byteArrayOf(0,0,0,1,5),canonicalAnnexB(byteArrayOf(0,0,1,5)))
    }
    @Test fun `canonical packet needs no copy and retains trailing bytes`() {
        val input=byteArrayOf(0,0,0,1,5,0,0,3,1,0,0)
        assertSame(input,canonicalAnnexB(input))
    }
}
