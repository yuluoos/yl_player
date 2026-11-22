package dev.ylplayer.yl_player_android

import androidx.media3.common.Format
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.FormatHolder
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import androidx.media3.exoplayer.video.MediaCodecVideoRenderer

/** Allow AAC to fill its new PCM track while the TV opens the untunneled AVC decoder. */
internal class YlMiTvSpeedVideoRenderer(
    builder: MediaCodecVideoRenderer.Builder,
    observer: YlVideoOutputObserver,
    private val atTripleSpeed: () -> Boolean,
    private val handoff: YlDashCodecHandoff,
) : YlOutputVideoRenderer(builder, observer, atTripleSpeed, null, { null }, { false }) {
    private var input: Format? = null
    private var targetSpeed = 1f
    private var waitForRateUntilMs = 0L

    override fun onInputFormatChanged(holder: FormatHolder): DecoderReuseEvaluation? {
        if (input != holder.format) handoff.discard()
        input = holder.format
        return super.onInputFormatChanged(holder)
    }

    override fun shouldInitCodec(info: MediaCodecInfo): Boolean {
        if (!super.shouldInitCodec(info)) return false
        val format = input ?: return true
        if (!atTripleSpeed() || configuration.tunneling || info.name != "OMX.MS.AVC.Decoder" ||
            format.drmInitData != null || format.sampleMimeType != "video/avc") return true
        // Track reselection and the rate update are separate Media3 messages.
        // Building a 1x configuration here would immediately discard the new
        // codec when the queued 3x update arrives. If the sink clamps the
        // requested rate, retain Media3's ordinary initialization path.
        if (targetSpeed != 3f) {
            val now = clock.elapsedRealtime()
            if (waitForRateUntilMs == 0L) waitForRateUntilMs = now + 50
            return now >= waitForRateUntilMs
        }
        return handoff.ready {
            val rate = getCodecOperatingRateV23(targetSpeed, format, streamFormats)
            super.getMediaCodecConfiguration(info, format, null, if (rate > 0f) rate else -1f)
        }
    }

    override fun setPlaybackSpeed(current: Float, target: Float) {
        if (target != 3f && targetSpeed == 3f) handoff.discard()
        targetSpeed = target
        super.setPlaybackSpeed(current, target)
    }

    override fun handleMessage(messageType: Int, message: Any?) {
        if (messageType == Renderer.MSG_SET_VIDEO_OUTPUT) handoff.discard()
        super.handleMessage(messageType, message)
    }

    override fun onPositionReset(positionUs: Long, joining: Boolean, sampleStreamIsResetToKeyFrame: Boolean) {
        waitForRateUntilMs = 0L
        handoff.discard()
        super.onPositionReset(positionUs, joining, sampleStreamIsResetToKeyFrame)
    }

    override fun onDisabled() {
        handoff.discard()
        input = null
        super.onDisabled()
    }

    override fun onReset() {
        handoff.discard()
        super.onReset()
    }

    override fun onRelease() {
        try { handoff.discard() } finally { super.onRelease() }
    }
}
