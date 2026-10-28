package dev.ylplayer.yl_player_android

import android.util.Log

internal data class YlPlaybackSpeedSample(
    val nowMs: Long,
    val speed: Float,
    val playing: Boolean,
    val bufferedMediaMs: Long,
    val allocatedBytes: Int,
    val targetBytes: Int,
    val tunnelingRequested: Boolean,
    val rebufferCount: Int,
    val droppedFrames: Int,
    val audioUnderruns: Int,
    val mediaPositionMs: Long = 0,
    val loading: Boolean = false,
    val videoBitrate: Int? = null,
)

/** Numeric observations only: one previous sample and one transfer measurement.
 * Evidence labels are hints, never a network/decoder root-cause verdict or recovery action. */
internal class YlPlaybackSpeedDiagnostics(
    private val writeLine: (String) -> Unit = { Log.d("YlPlayer", it); Unit },
) {
    private var lastReportMs: Long? = null
    private var rebuffers = 0
    private var drops = 0
    private var underruns = 0
    private var previous: YlPlaybackSpeedSample? = null
    private var transferAtMs: Long? = null
    private var transferBitsPerSecond: Long? = null

    fun reset() {
        lastReportMs = null; rebuffers = 0; drops = 0; underruns = 0
        discontinuity()
    }

    fun discontinuity() {
        previous = null; transferAtMs = null; transferBitsPerSecond = null
    }

    /** Measured transfer time, not wall-clock idle time or the bandwidth meter's estimate. */
    fun transfer(nowMs: Long, durationMs: Int, bytes: Long) {
        if (durationMs < 250 || bytes <= 0) return
        transferAtMs = nowMs
        transferBitsPerSecond = (bytes.toDouble() * 8_000 / durationMs).toLong()
    }

    fun record(sample: YlPlaybackSpeedSample) {
        val prior = previous
        previous = sample
        if (!sample.playing || !sample.speed.isFinite() || sample.speed <= 1f) {
            discontinuity()
            remember(sample)
            return
        }
        if (sample.rebufferCount < rebuffers || sample.droppedFrames < drops || sample.audioUnderruns < underruns) {
            reset(); remember(sample); return
        }
        if (sample.rebufferCount == rebuffers && sample.droppedFrames == drops && sample.audioUnderruns == underruns) return
        lastReportMs?.let { if (sample.nowMs >= it && sample.nowMs - it < 10_000) return }
        lastReportMs = sample.nowMs
        remember(sample)
        val buffered = sample.bufferedMediaMs.coerceAtLeast(0)
        val playout = (buffered / sample.speed.toDouble()).toLong()
        val byteLimited = sample.targetBytes > 0 && sample.allocatedBytes >= sample.targetBytes
        val measuredRate = transferAtMs?.takeIf { sample.nowMs - it in 0..10_000 }
            ?.let { transferBitsPerSecond }
        val videoDemand = sample.videoBitrate?.takeIf { it > 0 }?.let { it * sample.speed.toDouble() }
        val supplyEvidence = when {
            byteLimited -> "byteBudgetReached"
            !sample.loading -> "notLoading"
            measuredRate == null -> "unknown"
            playout <= 2_000 && videoDemand != null && measuredRate < videoDemand -> "belowVideoDemand"
            else -> "measured"
        }
        val elapsed = prior?.let { sample.nowMs - it.nowMs } ?: 0
        val consumed = prior?.let { sample.mediaPositionMs - it.mediaPositionMs } ?: -1
        // Reject pauses, clock jumps, speed changes and obvious seeks. No extrapolated frames.
        val continuous = prior != null && prior.playing && prior.speed == sample.speed &&
            elapsed in 1..10_000 && consumed >= 0 && consumed <= elapsed * sample.speed.toDouble() * 1.5 + 1_000
        val trend = if (!continuous) "unknown" else when {
            buffered < prior!!.bufferedMediaMs -> "shrinking"
            buffered > prior!!.bufferedMediaMs -> "growing"
            else -> "steady"
        }
        try {
            writeLine("speedHealth speed=${sample.speed} bufferedMediaMs=$buffered bufferedPlayoutMs=$playout " +
                "allocatorBytes=${sample.allocatedBytes} targetBytes=${sample.targetBytes} " +
                "tunnelingRequested=${sample.tunnelingRequested} rebufferCount=$rebuffers " +
                "droppedFrames=$drops audioUnderruns=$underruns " +
                "loading=${sample.loading} supplyEvidence=$supplyEvidence " +
                "transferBitsPerSecond=${measuredRate ?: "unknown"} bufferTrend=$trend " +
                "consumedMediaMs=${if (continuous) consumed else "unknown"}")
        } catch (_: Throwable) {
            // A diagnostic sink must not turn stuttering into a playback failure.
        }
    }

    private fun remember(sample: YlPlaybackSpeedSample) {
        rebuffers = sample.rebufferCount; drops = sample.droppedFrames; underruns = sample.audioUnderruns
    }
}
