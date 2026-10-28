package dev.ylplayer.yl_player_android

import androidx.media3.exoplayer.DecoderCounters

internal data class YlVideoFrameCounts(val rendered: Long = 0, val dropped: Long = 0, val observed: Boolean = false)

/** One decoder reference and cumulative totals, read only on the application thread. */
internal class YlVideoFrameCounter {
    private var counters: DecoderCounters? = null
    private var rendered = 0
    private var dropped = 0
    private var total = YlVideoFrameCounts()

    fun enabled(value: DecoderCounters) {
        if (counters === value) return
        snapshot()
        counters = value
        rendered = 0
        dropped = 0
    }

    fun disabled(value: DecoderCounters) {
        if (counters !== value) return
        snapshot()
        counters = null
    }

    fun snapshot(): YlVideoFrameCounts {
        val current = counters ?: return total
        current.ensureUpdated()
        val nextRendered = current.renderedOutputBufferCount.coerceAtLeast(0)
        val nextDropped = current.droppedBufferCount.coerceAtLeast(0)
        // A renderer replacement or counter reset must never create negative deltas.
        total = YlVideoFrameCounts(
            total.rendered + if (nextRendered >= rendered) nextRendered - rendered else nextRendered,
            total.dropped + if (nextDropped >= dropped) nextDropped - dropped else nextDropped,
            true,
        )
        rendered = nextRendered
        dropped = nextDropped
        return total
    }

    fun reset() {
        counters = null
        rendered = 0
        dropped = 0
        total = YlVideoFrameCounts()
    }
}
