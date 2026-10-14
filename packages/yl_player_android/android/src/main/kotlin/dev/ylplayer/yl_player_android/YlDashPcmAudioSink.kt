package dev.ylplayer.yl_player_android

import androidx.media3.common.Format
import androidx.media3.common.Metadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.Util
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.ForwardingAudioSink
import java.nio.ByteBuffer

/** Owned manifest metadata survives Media3's sample-format merge. Absolute rational
 * endpoints are projected once to the decoded sample grid, never once per AAC packet. */
internal data class YlDashPcmWindow(val start: YlDashTime, val end: YlDashTime) : Metadata.Entry {
    data class Clip(val skip: Int, val count: Int)
    fun frames(rate: Int): Long = end.units(rate.toLong(), true) - start.units(rate.toLong(), true)
    fun clip(relativePtsUs: Long, count: Int, rate: Int): Clip {
        // Media3 exposes microseconds, rounded from sample timestamps. Reconstruct the
        // nearest decoded sample index; ceil of each packet's duration adds a frame.
        val first = (YlDashTime.of(relativePtsUs, 1_000_000) + YlDashTime.of(1, rate.toLong() * 2)).units(rate.toLong())
        val skip = if (first <= -count.toLong()) count else (-first).coerceAtLeast(0).toInt()
        val available = (frames(rate) - first).coerceIn(0, count.toLong()).toInt()
        return Clip(skip, (available - skip).coerceAtLeast(0))
    }
}

/** Decode only a bounded preceding audio window; pathological declared rates
 * fail admission instead of silently dropping an oversized partial audio frame. */
internal fun dashAudioPrerollUs(format: Format): Long {
    val rate = format.sampleRate.takeIf { it > 0 } ?: 8000
    val samples = when (format.sampleMimeType) {
        "audio/mp4a-latm" -> 4096L
        "audio/flac" -> 65536L
        "audio/raw" -> 1L
        else -> 8192L
    }
    return YlDashTime.of(samples, rate.toLong()).units(1_000_000, true).also {
        require(it <= 8_192_000) { "Unsupported audio preroll duration" }
    }
}

/** DASH-only PCM boundary after MediaCodec and before the existing AudioTrack sink.
 * Encoded passthrough cannot satisfy sample clipping and is therefore not advertised.
 * A partially consumed buffer retains its identity and clipped limit until accepted. */
internal class YlDashPcmAudioSink(sink: AudioSink) : ForwardingAudioSink(sink) {
    private var window: YlDashPcmWindow? = null
    private var rate = 0
    private var bytesPerFrame = 0
    private var encoding = 0
    private var encoderDelay = 0
    private var activeDelay = 0
    private var trimRemaining = 0
    private var offsetUs = 0L
    private var incomingOffsetUs = 0L
    private var resetPositionUs = 0L
    private var cursor: Long? = null
    private var pending: ByteBuffer? = null
    private var pendingLimit = 0
    private var pendingPts = 0L
    private var pendingEnd = 0L
    private var nextConfig: AudioSink.AudioSinkConfig? = null
    private var discontinuity = false
    private var ending = false
    private var silence: ByteBuffer? = null
    private var silenceFrames = 0
    private var silencePts = 0L

    override fun supportsFormat(format: Format) = format.sampleMimeType == MimeTypes.AUDIO_RAW && super.supportsFormat(format)
    override fun getFormatSupport(format: Format) = if (format.sampleMimeType == MimeTypes.AUDIO_RAW) super.getFormatSupport(format) else AudioSink.SINK_FORMAT_UNSUPPORTED

    private fun boundary(config: AudioSink.AudioSinkConfig): YlDashPcmWindow? {
        val metadata = config.format.metadata
        val boundaries = metadata?.let { (0 until it.length()).map(it::get).filterIsInstance<YlDashPcmWindow>().distinct() }.orEmpty()
        check(boundaries.size <= 1)
        return boundaries.singleOrNull()
    }

    override fun configure(config: AudioSink.AudioSinkConfig) {
        // A new Period can be decoded before the prior AudioTrack drains. Finish
        // its bounded trailing silence using its own format/offset before switching.
        if (window != null && boundary(config) != window && cursor != null) nextConfig = config
        else applyConfiguration(config)
    }

    private fun applyConfiguration(config: AudioSink.AudioSinkConfig) {
        val format = config.format
        val next = boundary(config)
        val oldTime = if (next == window && rate > 0) cursor?.let { YlDashTime.of(it, rate.toLong()) } else null
        window = next
        rate = format.sampleRate
        encoding = format.pcmEncoding
        bytesPerFrame = if (format.sampleMimeType == MimeTypes.AUDIO_RAW) Util.getPcmFrameSize(encoding, format.channelCount) else 0
        cursor = oldTime?.units(rate.toLong(), true)
        offsetUs = incomingOffsetUs
        encoderDelay = format.encoderDelay
        ending = false
        super.setOutputStreamOffsetUs(offsetUs)
        // ClippingMediaPeriod clears encoder padding for a bounded end. Delay is
        // applied in our sample coordinates before gap insertion, not to silence.
        check(next == null || format.encoderPadding == 0)
        super.configure(if (next == null) config else AudioSink.AudioSinkConfig.Builder(format.buildUpon().setEncoderDelay(0).build())
            .setOutputChannelMapping(config.outputChannelMapping)
            .setPreferredBufferSizeOverride(config.preferredBufferSizeOverride)
            .setTimeline(config.timeline).setMediaPeriodId(config.mediaPeriodId).build())
    }

    override fun setOutputStreamOffsetUs(value: Long) {
        incomingOffsetUs = value
        if (cursor == null) { offsetUs = value; super.setOutputStreamOffsetUs(value) }
    }

    /** Renderer clock is absolute; subtract the actual output stream's offset,
     * not an input/read-ahead Period's offset. Called after every decoder seek flush. */
    fun resetPosition(positionUs: Long) {
        resetPositionUs = positionUs
        cursor = null
    }

    /** Media3 marks a whole decoded buffer as preroll by its first timestamp.
     * Keep a buffer crossing the seek point so the PCM window can slice its tail. */
    fun keepsPrerollTail(presentationTimeUs: Long, bytes: Int): Boolean {
        val bound = window ?: return false
        if (rate <= 0 || bytesPerFrame <= 0 || presentationTimeUs >= resetPositionUs) return false
        val first = (YlDashTime.of(presentationTimeUs - incomingOffsetUs, 1_000_000) +
            YlDashTime.of(1, rate.toLong() * 2)).units(rate.toLong()) - (if (resetPositionUs <= incomingOffsetUs) encoderDelay else 0)
        val target = YlDashTime.of((resetPositionUs - incomingOffsetUs).coerceAtLeast(0), 1_000_000).units(rate.toLong(), true)
        return first < bound.frames(rate) && first + bytes / bytesPerFrame > target
    }

    private fun begin() {
        if (cursor != null) return
        offsetUs = incomingOffsetUs
        super.setOutputStreamOffsetUs(offsetUs)
        val end = requireNotNull(window).frames(rate)
        activeDelay = if (resetPositionUs <= offsetUs) encoderDelay else 0
        trimRemaining = activeDelay
        cursor = YlDashTime.of((resetPositionUs - offsetUs).coerceAtLeast(0), 1_000_000).units(rate.toLong(), true).coerceIn(0, end)
    }

    /** Fill at most one <=100 ms / 32 KiB buffer per renderer poll. No gap-sized
     * allocation or busy loop, and partial AudioTrack writes keep the same buffer. */
    private fun fillUntil(target: Long): Boolean {
        begin()
        val at = requireNotNull(cursor)
        if (at >= target && silenceFrames == 0) return true
        if (silenceFrames == 0) {
            val frames = minOf(target - at, (rate / 10).coerceAtLeast(1).toLong(), (32768 / bytesPerFrame).toLong()).toInt()
            check(frames > 0)
            val buffer = silence ?: ByteBuffer.allocateDirect(32768).order(java.nio.ByteOrder.nativeOrder()).also { silence = it }
            buffer.clear(); buffer.limit(frames * bytesPerFrame)
            val zero = if (encoding == androidx.media3.common.C.ENCODING_PCM_8BIT) 0x80.toByte() else 0.toByte()
            while (buffer.hasRemaining()) buffer.put(zero)
            buffer.flip()
            silenceFrames = frames
            silencePts = offsetUs + YlDashTime.of(at, rate.toLong()).units(1_000_000)
        }
        if (super.handleBuffer(requireNotNull(silence), silencePts, 1)) {
            cursor = at + silenceFrames
            silenceFrames = 0
        }
        return requireNotNull(cursor) >= target && silenceFrames == 0
    }

    override fun handleBuffer(buffer: ByteBuffer, presentationTimeUs: Long, encodedAccessUnitCount: Int): Boolean {
        nextConfig?.let { config ->
            if (!fillUntil(requireNotNull(window).frames(rate))) return false
            nextConfig = null
            applyConfiguration(config)
        }
        if (discontinuity) { super.handleDiscontinuity(); discontinuity = false }
        val boundary = window ?: return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount)
        check(rate > 0 && bytesPerFrame in 1..32768)
        begin()
        if (pending == null) {
            check(buffer.remaining() % bytesPerFrame == 0)
            val count = buffer.remaining() / bytesPerFrame
            val relativeUs = presentationTimeUs - offsetUs
            val first = (YlDashTime.of(relativeUs, 1_000_000) + YlDashTime.of(1, rate.toLong() * 2)).units(rate.toLong()) - activeDelay
            val trim = minOf(count, trimRemaining)
            val at = maxOf(first + trim, requireNotNull(cursor))
            val skip = (at - first).coerceIn(0, count.toLong()).toInt()
            val kept = minOf((count - skip).toLong(), boundary.frames(rate) - at).coerceAtLeast(0).toInt()
            if (kept == 0) { trimRemaining -= trim; buffer.position(buffer.limit()); return true }
            if (!fillUntil(at)) return false
            trimRemaining -= trim
            pending = buffer
            pendingLimit = buffer.limit()
            buffer.position(buffer.position() + skip * bytesPerFrame)
            buffer.limit(buffer.position() + kept * bytesPerFrame)
            pendingPts = offsetUs + YlDashTime.of(at, rate.toLong()).units(1_000_000)
            pendingEnd = at + kept
        } else check(pending === buffer)
        val consumed = super.handleBuffer(buffer, pendingPts, encodedAccessUnitCount)
        if (consumed) {
            buffer.limit(pendingLimit); buffer.position(pendingLimit)
            pending = null; cursor = pendingEnd
        }
        return consumed
    }

    override fun handleDiscontinuity() { discontinuity = true }
    override fun playToEndOfStream() {
        ending = true
        if (window != null && !fillUntil(requireNotNull(window).frames(rate))) return
        super.playToEndOfStream()
    }
    override fun isEnded() = (window == null || !ending || (cursor ?: 0) >= requireNotNull(window).frames(rate)) && super.isEnded()
    override fun hasPendingData() = (ending && window != null && (cursor ?: 0) < requireNotNull(window).frames(rate)) || super.hasPendingData()
    override fun flush() {
        pending = null; silenceFrames = 0; cursor = null; ending = false; discontinuity = false
        nextConfig?.let { nextConfig = null; applyConfiguration(it) }
        super.flush()
    }
    override fun reset() {
        pending = null; silenceFrames = 0; silence = null; cursor = null; ending = false
        nextConfig = null; window = null; discontinuity = false; encoderDelay = 0
        super.reset()
    }
}
