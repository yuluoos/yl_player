package dev.ylplayer.yl_player_android

import android.content.Context
import androidx.media3.common.ColorInfo
import androidx.media3.common.DebugViewProvider
import androidx.media3.common.Format
import androidx.media3.common.VideoGraph
import androidx.media3.common.util.Size
import androidx.media3.effect.FrameCache
import androidx.media3.effect.SingleInputVideoGraph
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.FormatHolder
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import androidx.media3.exoplayer.video.MediaCodecVideoRenderer
import androidx.media3.exoplayer.video.PlaybackVideoGraphWrapper
import androidx.media3.exoplayer.video.VideoFrameReleaseControl
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future

/** During this TV's serial codec change the playback looper must keep rendering the
 * already-decoded AVC pictures. Media3 owns their timestamps, seeks, output and release. */
internal class YlDashTransitionRenderer(
    builder: MediaCodecVideoRenderer.Builder,
    observer: YlVideoOutputObserver,
    private val sizing: YlDashDecoderSizing,
    private val audioPosition: () -> Long?,
    private val waiting: () -> Boolean,
    private val wantsPlayback: () -> Boolean,
    private val handoff: YlDashCodecHandoff,
) : YlOutputVideoRenderer(builder, observer, null, sizing, audioPosition, waiting) {
    private var outputSize: Size? = null
    private var appliedSize: Size? = null
    private var incoming: Format? = null
    private var targetSpeed = 1f
    private val graphStartup = YlDashStartupFrameGate()
    private var awaitingFirstGraphFrame = true
    private val pendingFrames = ArrayDeque<() -> Unit>()
    private var firstAvailableMs = 0L
    private var startupReadyUntilMs = 0L
    override fun gateDecoderStartup() = outputSize == null

    override fun onEnabled(joining: Boolean, mayRenderStartOfStream: Boolean) {
        val size = sizing.transitionOutputSize.takeUnless { configuration.tunneling }
        if (size != null) {
            awaitingFirstGraphFrame = true
            graphStartup.cancelWait()
            super.handleMessage(Renderer.MSG_SET_VIDEO_EFFECTS, listOf(FrameCache(8)))
            surface?.let {
                val actual = YlVideoSurfaceSize.get(it) ?: size
                super.handleMessage(Renderer.MSG_SET_VIDEO_OUTPUT_RESOLUTION, actual)
                appliedSize = actual
            }
        } else if (outputSize != null) {
            super.handleMessage(Renderer.MSG_SET_VIDEO_EFFECTS, emptyList<androidx.media3.common.Effect>())
        }
        outputSize = size
        super.onEnabled(joining, mayRenderStartOfStream)
    }

    override fun createPlaybackVideoGraphWrapper(context: Context, control: VideoFrameReleaseControl): PlaybackVideoGraphWrapper {
        control.setEarlySchedulingThresholdUs(10_000L)
        val factory = object : VideoGraph.Factory {
            private val delegate = SingleInputVideoGraph.Factory()
            override fun supportsMultipleInputs() = false
            override fun create(context: Context, color: ColorInfo, debug: DebugViewProvider, listener: VideoGraph.Listener,
                executor: Executor, initialOffsetUs: Long, automatic: Boolean): VideoGraph {
                // Media3 delivers these callbacks on the playback looper. Wait only after
                // the first composited picture exists; codec input remains free to preroll.
                val observed = object : VideoGraph.Listener by listener {
                    override fun onOutputFrameAvailableForRendering(ptsUs: Long, redraw: Boolean) {
                        if (!awaitingFirstGraphFrame) return listener.onOutputFrameAvailableForRendering(ptsUs, redraw)
                        if (pendingFrames.isEmpty()) firstAvailableMs = clock.elapsedRealtime()
                        pendingFrames.addLast { listener.onOutputFrameAvailableForRendering(ptsUs, redraw) }
                    }
                }
                return delegate.create(context, color, debug, observed, executor, initialOffsetUs, automatic)
            }
        }
        return PlaybackVideoGraphWrapper.Builder(context, control).setVideoGraphFactory(factory)
            .setEnablePlaylistMode(true).setClock(clock).build()
    }

    override fun render(positionUs: Long, elapsedRealtimeUs: Long) {
        if (outputSize != null) surface?.let { target ->
            val actual = YlVideoSurfaceSize.get(target)
            if (actual != null && actual != appliedSize) {
                super.handleMessage(Renderer.MSG_SET_VIDEO_OUTPUT_RESOLUTION, actual)
                appliedSize = actual
            }
        }
        if (pendingFrames.isNotEmpty()) {
            val now = clock.elapsedRealtime()
            val hold = wantsPlayback() && now - firstAvailableMs < 650L &&
                (waiting() || graphStartup.awaitAudio(audioPosition(), state == Renderer.STATE_STARTED, now))
            if (!hold) {
                startupReadyUntilMs = now + 100L
                forwardGraphFrames()
            }
        }
        super.render(positionUs, elapsedRealtimeUs)
    }

    override fun isReady() = super.isReady() || (surface != null &&
        (pendingFrames.isNotEmpty() || clock.elapsedRealtime() < startupReadyUntilMs))

    private fun forwardGraphFrames() {
        awaitingFirstGraphFrame = false
        while (pendingFrames.isNotEmpty()) pendingFrames.removeFirst().invoke()
    }

    override fun onInputFormatChanged(holder: FormatHolder): DecoderReuseEvaluation? {
        if (holder.format != incoming) handoff.discard()
        incoming = holder.format
        handoff.switching = outputSize != null && incoming?.sampleMimeType == "video/hevc" && state == Renderer.STATE_STARTED
        return super.onInputFormatChanged(holder)
    }

    override fun shouldInitCodec(info: MediaCodecInfo): Boolean {
        if (!super.shouldInitCodec(info)) return false
        val format = incoming ?: return true
        if (!handoff.switching || info.name != "OMX.MS.HEVC.Decoder" || format.drmInitData != null) return true
        return handoff.ready {
            // Use the same operating rate as the pinned Media3 builder (minimum is zero).
            val rate = getCodecOperatingRateV23(targetSpeed, format, streamFormats)
            super.getMediaCodecConfiguration(info, format, null, if (rate > 0f) rate else -1f)
        }
    }

    override fun setPlaybackSpeed(current: Float, target: Float) {
        if (targetSpeed != target) handoff.discard()
        targetSpeed = target
        super.setPlaybackSpeed(current, target)
    }

    override fun handleMessage(messageType: Int, message: Any?) {
        if (messageType == Renderer.MSG_SET_VIDEO_OUTPUT) {
            if (pendingFrames.isNotEmpty()) forwardGraphFrames()
            appliedSize = null
            handoff.discard()
        }
        // A raw Surface does not tell ExoPlayer its dimensions. SurfaceHolder-provided
        // positive dimensions take priority over the common-aspect programme size.
        val size = outputSize
        if (messageType == Renderer.MSG_SET_VIDEO_OUTPUT_RESOLUTION && message is Size &&
            (message.width < 0 || message.height < 0) && size != null && surface != null) {
            val actual = surface?.let(YlVideoSurfaceSize::get) ?: size
            super.handleMessage(messageType, actual)
            appliedSize = actual
        } else {
            super.handleMessage(messageType, message)
            if (messageType == Renderer.MSG_SET_VIDEO_OUTPUT_RESOLUTION && message is Size) appliedSize = message
        }
    }

    override fun onPositionReset(positionUs: Long, joining: Boolean, sampleStreamIsResetToKeyFrame: Boolean) {
        if (pendingFrames.isNotEmpty()) forwardGraphFrames()
        startupReadyUntilMs = 0L
        handoff.discard()
        super.onPositionReset(positionUs, joining, sampleStreamIsResetToKeyFrame)
    }

    override fun onDisabled() {
        if (pendingFrames.isNotEmpty()) forwardGraphFrames()
        startupReadyUntilMs = 0L
        handoff.discard()
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

/** Accessed by the playback looper. A single worker releases the old hardware decoder
 * before constructing its successor. Ordinary codec creation and teardown stay synchronous. */
internal class YlDashCodecHandoff(private val delegate: MediaCodecAdapter.Factory) : MediaCodecAdapter.Factory {
    var switching = false
    private var worker: ExecutorService? = null
    private var release: Future<*>? = null
    private var prepared: Future<MediaCodecAdapter>? = null
    private var expected: MediaCodecAdapter.Configuration? = null

    private fun worker() = worker ?: Executors.newSingleThreadExecutor { Thread(it, "yl-dash-codec") }.also { worker = it }

    fun ready(configuration: () -> MediaCodecAdapter.Configuration): Boolean {
        prepared?.let { return it.isDone }
        val config = configuration()
        val previousRelease = release
        expected = config
        prepared = worker().submit<MediaCodecAdapter> {
            previousRelease?.get()
            delegate.createAdapter(config)
        }
        return false
    }

    override fun createAdapter(config: MediaCodecAdapter.Configuration): MediaCodecAdapter {
        val future = prepared
        if (future != null) {
            val previous = expected
            prepared = null
            expected = null
            val codec = try { future.get() } catch (error: ExecutionException) {
                throw java.io.IOException("DASH decoder preparation failed", error.cause)
            }
            if (previous?.format == config.format && previous.codecInfo.name == config.codecInfo.name &&
                previous.surface === config.surface && previous.crypto === config.crypto) return codec
            codec.release()
        }
        release?.get()
        val codec = delegate.createAdapter(config)
        if (config.codecInfo.name != "OMX.MS.AVC.Decoder") return codec
        return object : MediaCodecAdapter by codec {
            override fun release() {
                if (switching) release = worker().submit { codec.release() } else codec.release()
            }
        }
    }

    fun discard() {
        switching = false
        val future = prepared
        prepared = null
        expected = null
        try {
            // A discarded failed construction has no adapter to release.
            val unused = try { future?.get() } catch (_: ExecutionException) { null }
            unused?.release()
            release?.get()
        } finally {
            release = null
            worker?.shutdown()
            worker = null
        }
    }
}
