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

/** DASH-only PCM boundary after MediaCodec and before the existing AudioTrack sink.
 * Encoded passthrough cannot satisfy sample clipping and is therefore not advertised.
 * A partially consumed buffer retains its identity and clipped limit until accepted. */
internal class YlDashPcmAudioSink(sink: AudioSink) : ForwardingAudioSink(sink) {
    private var window: YlDashPcmWindow? = null
    private var rate = 0
    private var bytesPerFrame = 0
    private var offsetUs = 0L
    private var pending: ByteBuffer? = null
    private var pendingLimit = 0
    private var pendingPts = 0L

    override fun supportsFormat(format: Format) = format.sampleMimeType == MimeTypes.AUDIO_RAW && super.supportsFormat(format)
    override fun getFormatSupport(format: Format) = if (format.sampleMimeType == MimeTypes.AUDIO_RAW) super.getFormatSupport(format) else AudioSink.SINK_FORMAT_UNSUPPORTED

    override fun configure(config: AudioSink.AudioSinkConfig) {
        val format = config.format
        val metadata = format.metadata
        val boundaries = metadata?.let { (0 until it.length()).map(it::get).filterIsInstance<YlDashPcmWindow>().distinct() }.orEmpty()
        check(boundaries.size <= 1)
        window = boundaries.singleOrNull()
        rate = format.sampleRate
        bytesPerFrame = if (format.sampleMimeType == MimeTypes.AUDIO_RAW) Util.getPcmFrameSize(format.pcmEncoding, format.channelCount) else 0
        super.configure(config)
    }

    override fun setOutputStreamOffsetUs(value: Long) { offsetUs = value; super.setOutputStreamOffsetUs(value) }

    override fun handleBuffer(buffer: ByteBuffer, presentationTimeUs: Long, encodedAccessUnitCount: Int): Boolean {
        val boundary = window ?: return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount)
        check(rate > 0 && bytesPerFrame > 0 && buffer.remaining() % bytesPerFrame == 0)
        if (pending == null) {
            val clip = boundary.clip(presentationTimeUs - offsetUs, buffer.remaining() / bytesPerFrame, rate)
            if (clip.count == 0) { buffer.position(buffer.limit()); return true }
            pending = buffer
            pendingLimit = buffer.limit()
            buffer.position(buffer.position() + clip.skip * bytesPerFrame)
            buffer.limit(buffer.position() + clip.count * bytesPerFrame)
            pendingPts = presentationTimeUs + YlDashTime.of(clip.skip.toLong(), rate.toLong()).units(1_000_000)
        } else check(pending === buffer)
        val consumed = super.handleBuffer(buffer, pendingPts, encodedAccessUnitCount)
        if (consumed) {
            buffer.limit(pendingLimit); buffer.position(pendingLimit)
            pending = null
        }
        return consumed
    }

    override fun flush() { pending = null; super.flush() }
    override fun reset() { pending = null; window = null; super.reset() }
}
