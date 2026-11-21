package dev.ylplayer.yl_player_android

import android.os.SystemClock
import androidx.media3.common.Format
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.analytics.AnalyticsListener.EventTime
import org.json.JSONObject

/** Store sparse events in memory so logcat I/O stays out of the render path. */
internal class YlDashTimingTrace : AnalyticsListener {
    private val events = mutableListOf<JSONObject>()

    @Synchronized fun mark(event: String, vararg fields: Pair<String, Any?>) {
        val row = JSONObject().put("event", event).put("hostNs", System.nanoTime())
        for ((key, value) in fields) row.put(key, value ?: JSONObject.NULL)
        events.add(row)
    }

    override fun onVideoDecoderInitialized(
        eventTime: EventTime, decoderName: String, initializedTimestampMs: Long, initializationDurationMs: Long,
    ) {
        // The callback can be delivered later on the app looper. Preserve the decoder's own timestamp.
        mark("videoDecoderInitialized", "decoder" to decoderName, "durationMs" to initializationDurationMs,
            "initializedElapsedMs" to initializedTimestampMs, "callbackElapsedNs" to SystemClock.elapsedRealtimeNanos())
    }

    override fun onVideoDecoderReleased(eventTime: EventTime, decoderName: String) {
        mark("videoDecoderReleased", "decoder" to decoderName)
    }

    override fun onVideoInputFormatChanged(eventTime: EventTime, format: Format, reuse: DecoderReuseEvaluation?) {
        mark("videoFormat", "id" to format.id, "mime" to format.sampleMimeType, "width" to format.width,
            "height" to format.height, "reuseResult" to reuse?.result, "discardReasons" to reuse?.discardReasons)
    }

    @Synchronized fun log(fixture: String, run: Int) {
        for (row in events) {
            android.util.Log.i("P01_AV_EVENT", row.put("fixture", fixture).put("run", run).toString())
        }
    }
}
