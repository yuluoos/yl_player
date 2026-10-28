package dev.ylplayer.yl_player_android

import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.audio.DefaultAudioTrackBufferSizeProvider

/** A PCM scheduling cushion, not a replacement for the platform's minimum buffer.
 * Keep passthrough/offload and their codec-specific workarounds entirely upstream. */
internal class YlTvAudioBufferSizeProvider : DefaultAudioSink.AudioTrackBufferSizeProvider {
    private val normal = DefaultAudioSink.AudioTrackBufferSizeProvider.DEFAULT
    private val cushioned = DefaultAudioTrackBufferSizeProvider.Builder()
        .setTargetPcmBufferDurationUs(750_000).build()

    override fun getBufferSizeInBytes(minBufferSizeInBytes: Int, encoding: Int, outputMode: Int,
        pcmFrameSize: Int, sampleRate: Int, bitrate: Int, maxAudioTrackPlaybackSpeed: Double): Int {
        val base = normal.getBufferSizeInBytes(minBufferSizeInBytes, encoding, outputMode,
            pcmFrameSize, sampleRate, bitrate, maxAudioTrackPlaybackSpeed)
        if (outputMode != DefaultAudioSink.OUTPUT_MODE_PCM) return base
        val target = cushioned.getBufferSizeInBytes(minBufferSizeInBytes, encoding, outputMode,
            pcmFrameSize, sampleRate, bitrate, maxAudioTrackPlaybackSpeed)
        val extra = (256 * 1024 / pcmFrameSize) * pcmFrameSize
        return minOf(target.toLong(), base.toLong() + extra).coerceAtLeast(base.toLong()).toInt()
    }
}
