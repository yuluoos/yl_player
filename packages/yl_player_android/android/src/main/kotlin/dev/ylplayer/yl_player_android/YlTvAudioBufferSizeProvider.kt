package dev.ylplayer.yl_player_android

import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.audio.DefaultAudioTrackBufferSizeProvider

/** A PCM scheduling cushion, not a replacement for the platform's minimum buffer.
 * Keep passthrough/offload and their codec-specific workarounds entirely upstream. */
internal class YlTvAudioBufferSizeProvider(private val platformRate: Boolean = false,
    private val isMiTv3xRequested: (() -> Boolean)? = null) : DefaultAudioSink.AudioTrackBufferSizeProvider {
    private val normal = DefaultAudioSink.AudioTrackBufferSizeProvider.DEFAULT
    private val cushioned = DefaultAudioTrackBufferSizeProvider.Builder()
        .setTargetPcmBufferDurationUs(750_000).build()
    private val highRate = DefaultAudioTrackBufferSizeProvider.Builder()
        .setTargetPcmBufferDurationUs(1_125_000).build()

    override fun getBufferSizeInBytes(minBufferSizeInBytes: Int, encoding: Int, outputMode: Int,
        pcmFrameSize: Int, sampleRate: Int, bitrate: Int, maxAudioTrackPlaybackSpeed: Double): Int {
        if (outputMode != DefaultAudioSink.OUTPUT_MODE_PCM) {
            return normal.getBufferSizeInBytes(minBufferSizeInBytes, encoding, outputMode,
                pcmFrameSize, sampleRate, bitrate, maxAudioTrackPlaybackSpeed)
        }
        // On the Mi TV the platform changes the clock rate. Scaling the entire
        // scheduling cushion for Media3's 8x maximum adds seconds to reprime.
        // Reserve the platform minimum at the public 4x limit, then let the
        // normal providers align frames and apply the same bounded cushion.
        val minimum = if (platformRate) {
            (minBufferSizeInBytes * 4L).coerceAtMost((Int.MAX_VALUE - pcmFrameSize + 1).toLong()).toInt()
        } else minBufferSizeInBytes
        val multiplier = if (platformRate) 1.0 else maxAudioTrackPlaybackSpeed
        val base = normal.getBufferSizeInBytes(minimum, encoding, outputMode,
            pcmFrameSize, sampleRate, bitrate, multiplier)
        val provider = if (platformRate && isMiTv3xRequested?.invoke() == true) highRate else cushioned
        val target = provider.getBufferSizeInBytes(minimum, encoding, outputMode,
            pcmFrameSize, sampleRate, bitrate, multiplier)
        val extra = (256 * 1024 / pcmFrameSize) * pcmFrameSize
        return minOf(target.toLong(), base.toLong() + extra).coerceAtLeast(base.toLong()).toInt()
    }
}
