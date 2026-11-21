package dev.ylplayer.yl_player_android

import android.media.AudioTrack
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.util.Util
import androidx.media3.exoplayer.audio.AudioOutput
import androidx.media3.exoplayer.audio.AudioOutputProvider
import androidx.media3.exoplayer.audio.AudioTrackAudioOutput
import androidx.media3.exoplayer.audio.ForwardingAudioOutput
import androidx.media3.exoplayer.audio.ForwardingAudioOutputProvider
import java.nio.ByteBuffer

internal class YlMiTvAudioOutputProvider(delegate: AudioOutputProvider) : ForwardingAudioOutputProvider(delegate) {
    override fun getAudioOutput(config: AudioOutputProvider.OutputConfig): AudioOutput {
        val output = super.getAudioOutput(config)
        if (output !is AudioTrackAudioOutput || config.isTunneling || config.isOffload || !Util.isEncodingLinearPcm(config.encoding)) return output
        val frameSize = Util.getPcmFrameSize(config.encoding, Integer.bitCount(config.channelMask))
        return YlMiTvPcmOutput(output, output.audioTrack, frameSize)
    }
}

/** Prime a newly opened high-rate track without waiting for its entire steady-state queue. */
internal class YlMiTvPcmOutput(output: AudioOutput, private val track: AudioTrack,
    private val bytesPerFrame: Int) : ForwardingAudioOutput(output) {
    private companion object { const val STARTUP_PLAYOUT_MS = 150 }

    private var hasWritten = false
    private var restoreFrames = 0
    private var remainingPrimeBytes = 0L
    private var playDeferred = false

    override fun setPlaybackParameters(parameters: PlaybackParameters) {
        super.setPlaybackParameters(parameters)
        if (parameters.speed != 3f) {
            startDeferredPlayback()
            restoreBuffer()
        } else if (!hasWritten && restoreFrames == 0) {
            val current = track.bufferSizeInFrames
            // Size the priming queue in playout time. At 3x, 6,000 frames of
            // 48 kHz PCM cover only 42 ms while the new decoder is filling it.
            val startupFrames = (track.sampleRate * parameters.speed * STARTUP_PLAYOUT_MS / 1_000).toInt()
            if (startupFrames in 1 until current) {
                val applied = track.setBufferSizeInFrames(startupFrames)
                if (applied in 1 until current) {
                    restoreFrames = current
                    remainingPrimeBytes = applied.toLong() * bytesPerFrame
                    android.util.Log.d("YlPlayer", "Mi TV PCM startup frames=$applied steadyFrames=$current")
                }
            }
        }
    }

    override fun play() {
        if (restoreFrames > 0 && remainingPrimeBytes > 0 && track.playState != AudioTrack.PLAYSTATE_PLAYING) {
            playDeferred = true
        } else {
            super.play()
        }
    }

    private fun startDeferredPlayback() {
        if (playDeferred) {
            playDeferred = false
            super.play()
            android.util.Log.d("YlPlayer", "Mi TV PCM play remainingPrimeBytes=${remainingPrimeBytes.coerceAtLeast(0)}")
        }
    }

    override fun pause() {
        playDeferred = false
        super.pause()
    }

    override fun stop() {
        // Short streams may finish before the priming target. Let the sink
        // drain their actual samples when it signals end of stream.
        if (hasWritten) startDeferredPlayback()
        playDeferred = false
        super.stop()
    }

    override fun write(buffer: ByteBuffer, encodedAccessUnitCount: Int, presentationTimeUs: Long): Boolean {
        hasWritten = true
        if (restoreFrames == 0) return super.write(buffer, encodedAccessUnitCount, presentationTimeUs)
        val before = buffer.remaining()
        val consumed = super.write(buffer, encodedAccessUnitCount, presentationTimeUs)
        remainingPrimeBytes -= before - buffer.remaining()
        if (remainingPrimeBytes <= 0 || !consumed) startDeferredPlayback()
        // PLAYSTATE_PLAYING can precede hardware consumption. Filling the
        // initial queue alone must not raise the TV's playback start threshold.
        // Accepting more than the full queue proves space has already freed
        // even when the vendor playback head has not reported its first update.
        if (track.playbackHeadPosition != 0 || remainingPrimeBytes < 0) restoreBuffer()
        return consumed
    }

    override fun flush() {
        playDeferred = false
        restoreBuffer()
        super.flush()
    }

    private fun restoreBuffer() {
        if (restoreFrames > 0) {
            val restored = track.setBufferSizeInFrames(restoreFrames)
            if (restored > 0) {
                restoreFrames = 0
                android.util.Log.d("YlPlayer", "Mi TV PCM restored frames=$restored")
            }
        }
    }
}
