package dev.ylplayer.yl_player_android

import androidx.media3.common.Metadata

/** Owned half-open coverage from the selected Representation's explicit segment timeline.
 * Endpoints remain rational until compared with Media3's period-relative clock. This is
 * declaration coverage, not proof of decoded pixels or a substitute for output observation. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal data class YlDashVideoCoverage(val ranges: List<Range>) : Metadata.Entry {
    data class Range(val start: YlDashTime, val end: YlDashTime)
    fun contains(positionUs: Long): Boolean {
        val point = YlDashTime.of(positionUs, 1_000_000)
        // Ranges are merged and ordered; bounded binary search avoids scanning a long MPD per tick.
        var low = 0; var high = ranges.size
        while (low < high) {
            val mid = (low + high) ushr 1
            if (ranges[mid].start <= point) low = mid + 1 else high = mid
        }
        return low > 0 && point < ranges[low - 1].end
    }
    companion object {
        fun merge(values: List<Range>, end: YlDashTime): YlDashVideoCoverage {
            val result = mutableListOf<Range>()
            for (value in values) {
                require(value.end > value.start)
                val start = maxOf(YlDashTime.ZERO, value.start)
                val stop = minOf(end, value.end)
                if (stop <= start) continue
                val previous = result.lastOrNull()
                require(previous == null || start >= previous.start)
                if (previous != null && start <= previous.end)
                    result[result.lastIndex] = Range(previous.start, maxOf(previous.end, stop))
                else result += Range(start, stop)
            }
            return YlDashVideoCoverage(result.toList())
        }
    }
}
