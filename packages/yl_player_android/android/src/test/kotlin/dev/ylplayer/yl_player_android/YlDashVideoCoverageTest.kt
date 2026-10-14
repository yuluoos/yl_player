package dev.ylplayer.yl_player_android

import kotlin.test.*

class YlDashVideoCoverageTest {
    @Test fun `coverage clips merges and keeps half open holes without timestamp overflow`() {
        fun range(a: Long, b: Long) = YlDashVideoCoverage.Range(YlDashTime.of(a), YlDashTime.of(b))
        val coverage = YlDashVideoCoverage.merge(listOf(range(-2, 1), range(1, 2), range(3, 8)), YlDashTime.of(4))
        assertEquals(listOf(range(0, 2), range(3, 4)), coverage.ranges)
        assertFalse(coverage.contains(-1)); assertTrue(coverage.contains(0))
        assertFalse(coverage.contains(2_000_000)); assertTrue(coverage.contains(3_000_000))
        assertFalse(coverage.contains(4_000_000)); assertFalse(coverage.contains(Long.MAX_VALUE))
        assertFalse(YlDashVideoCoverage.merge(emptyList(), YlDashTime.of(4)).contains(0))
        assertFailsWith<IllegalArgumentException> { YlDashVideoCoverage.merge(listOf(range(3, 4), range(1, 2)), YlDashTime.of(4)) }
    }
}
