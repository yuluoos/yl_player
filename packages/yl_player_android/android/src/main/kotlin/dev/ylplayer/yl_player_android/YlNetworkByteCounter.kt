package dev.ylplayer.yl_player_android

import java.util.concurrent.atomic.AtomicLong

/** One load owns this counter, including retries, seeks and backend replacement.
 * Only transport reads add bytes; an idle connection never invents progress. */
internal class YlNetworkByteCounter {
    private val received = AtomicLong()
    val bytesReceived: Long get() = received.get()
    fun received(count: Long) {
        if (count > 0) received.updateAndGet { previous ->
            if (count > Long.MAX_VALUE - previous) Long.MAX_VALUE else previous + count
        }
    }
}
