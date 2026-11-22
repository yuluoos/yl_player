package dev.ylplayer.yl_player_android

import androidx.media3.exoplayer.audio.AudioSink

/** Playback-thread state for a decoded start frame on this TV. A stationary
 * AudioTrack can report its starting position before Media3 starts playback.
 * While holding that frame the video renderer is ready for playback to start. */
internal class YlDashStartupFrameGate {
    private var firstAudioUs: Long? = null
    private var beganMs = 0L
    private var firstFrameRendered = false
    var holding = false
        private set

    fun awaitAudio(audioUs: Long?, started: Boolean, nowMs: Long): Boolean {
        if (firstFrameRendered || audioUs == null || audioUs == AudioSink.CURRENT_POSITION_NOT_SET) {
            cancelWait()
            return false
        }
        val initial = firstAudioUs ?: audioUs.also {
            firstAudioUs = it
            beganMs = nowMs
        }
        holding = nowMs - beganMs < MAX_WAIT_MS && (!started || audioUs <= initial)
        return holding
    }

    fun cancelWait() {
        firstAudioUs = null
        holding = false
    }

    fun rendered() {
        firstFrameRendered = true
        cancelWait()
    }

    private companion object { const val MAX_WAIT_MS = 650L }
}
