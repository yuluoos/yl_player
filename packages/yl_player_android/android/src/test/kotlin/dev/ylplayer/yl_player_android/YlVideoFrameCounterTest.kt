package dev.ylplayer.yl_player_android

import androidx.media3.exoplayer.DecoderCounters
import kotlin.test.*

class YlVideoFrameCounterTest {
    @Test fun `unknown is distinct from measured zero and snapshots do not invent progress`() {
        val counter = YlVideoFrameCounter()
        assertFalse(counter.snapshot().observed)
        val decoder = DecoderCounters()
        counter.enabled(decoder)
        assertEquals(YlVideoFrameCounts(0, 0, true), counter.snapshot())
        decoder.renderedOutputBufferCount = 1350
        decoder.droppedBufferCount = 50
        assertEquals(YlVideoFrameCounts(1350, 50, true), counter.snapshot())
        repeat(10) { assertEquals(YlVideoFrameCounts(1350, 50, true), counter.snapshot()) }
    }

    @Test fun `decoder replacement preserves final frames and ignores late disable from old decoder`() {
        val counter = YlVideoFrameCounter()
        val first = DecoderCounters().apply { renderedOutputBufferCount = 200; droppedBufferCount = 2 }
        counter.enabled(first)
        counter.snapshot()
        first.renderedOutputBufferCount = 210
        val next = DecoderCounters().apply { renderedOutputBufferCount = 15; droppedBufferCount = 1 }
        counter.enabled(next)
        counter.disabled(first)
        assertEquals(YlVideoFrameCounts(225, 3, true), counter.snapshot())
        next.renderedOutputBufferCount = 20
        counter.disabled(next)
        next.renderedOutputBufferCount = 999
        assertEquals(YlVideoFrameCounts(230, 3, true), counter.snapshot())
    }

    @Test fun `duplicate enable and counter reset do not double count historical frames`() {
        val counter = YlVideoFrameCounter()
        val decoder = DecoderCounters().apply { renderedOutputBufferCount = 100; droppedBufferCount = 10 }
        counter.enabled(decoder)
        counter.snapshot()
        counter.enabled(decoder)
        assertEquals(YlVideoFrameCounts(100, 10, true), counter.snapshot())
        decoder.renderedOutputBufferCount = 5
        decoder.droppedBufferCount = 1
        assertEquals(YlVideoFrameCounts(105, 11, true), counter.snapshot())
        counter.reset()
        counter.disabled(decoder)
        assertEquals(YlVideoFrameCounts(), counter.snapshot())
    }
}
