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
    @Test fun `large HEVC access units preserve payload across mixed prefixes and incomplete suffix`() {
        val payload = ByteArray(512 * 1024) { (it % 253 + 2).toByte() }
        val input = byteArrayOf(0,0,1,38) + payload + byteArrayOf(0,0,0,1,40) +
            payload + byteArrayOf(0,0,1,42,0,0)
        val expected = byteArrayOf(0,0,0,1,38) + payload + byteArrayOf(0,0,0,1,40) +
            payload + byteArrayOf(0,0,0,1,42,0,0)
        assertContentEquals(expected, canonicalAnnexB(input))
        assertContentEquals(byteArrayOf(), canonicalAnnexB(byteArrayOf()))
        assertContentEquals(byteArrayOf(0,0), canonicalAnnexB(byteArrayOf(0,0)))
    }
    @Test fun `sparse scan agrees with bytewise prefixes at every alignment`() {
        val random = kotlin.random.Random(237)
        repeat(500) {
            val input = ByteArray(random.nextInt(0, 4096)) { random.nextInt(0, 8).toByte() }
            val expected = java.io.ByteArrayOutputStream()
            var index = 0
            while (index < input.size) {
                val prefix = if (index + 2 < input.size && input[index] == 0.toByte() && input[index+1] == 0.toByte()) {
                    if (input[index+2] == 1.toByte()) 3
                    else if (index+3 < input.size && input[index+2] == 0.toByte() && input[index+3] == 1.toByte()) 4 else 0
                } else 0
                if (prefix == 3) expected.write(0)
                val count = if (prefix == 0) 1 else prefix
                expected.write(input, index, count)
                index += count
            }
            assertContentEquals(expected.toByteArray(), canonicalAnnexB(input))
        }
    }
}
