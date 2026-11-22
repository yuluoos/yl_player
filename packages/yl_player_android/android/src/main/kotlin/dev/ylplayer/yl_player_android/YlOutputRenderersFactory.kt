package dev.ylplayer.yl_player_android

import android.content.Context
import android.media.MediaFormat
import android.os.Handler
import android.os.SystemClock
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.AudioTrackAudioOutputProvider
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.audio.ForwardingAudioSink
import java.nio.ByteBuffer
import androidx.media3.common.Format
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.mediacodec.DefaultMediaCodecAdapterFactory
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.MediaSource.MediaPeriodId
import androidx.media3.exoplayer.video.MediaCodecVideoRenderer
import androidx.media3.exoplayer.video.VideoRendererEventListener
import dev.ylplayer.yl_player_android.pigeon.AndroidVideoGeometryMessage
import java.util.concurrent.atomic.AtomicLong

/** Pinned to Media3 1.11's output-format queue and output-stream clock, never its input Format.
 * All mutable observations live on the playback thread. Only changed immutable values are posted
 * to the application handler; the atomic generation also fences already queued lifecycle work. */
internal class YlVideoOutputObserver private constructor(
    private val post: (() -> Unit) -> Unit,
    private val receive: (Any?, AndroidVideoGeometryMessage?, YlDashVideoCoverage?) -> Unit,
    private val output: Output,
) {
    constructor(post: (() -> Unit) -> Unit, receive: (Any?, AndroidVideoGeometryMessage?, YlDashVideoCoverage?) -> Unit)
        : this(post, receive, Output()) { output.owner = this }

    // Both renderers may decode at once. Only the renderer holding Media3's
    // display surface can publish, and each keeps its own stream/format queue.
    private class Output {
        lateinit var owner: YlVideoOutputObserver
        val generation = AtomicLong()
        val publication = AtomicLong()
        var family: YlDashVideoFamilyPolicy? = null
    }

    var dashVideoFamily: YlDashVideoFamilyPolicy?
        get() = output.family
        set(value) { output.family = value }

    fun forPrewarming() = YlVideoOutputObserver(post, receive, output)

    fun takeOutput() {
        output.publication.incrementAndGet()
        output.owner = this
        last = null
    }

    private data class Stream(val startUs: Long, val offsetUs: Long)
    private data class Entry(val uid: Any, val generation: Long)
    private var pendingFormat: Format? = null
    private var pendingTransfer: Int? = null
    private val streams = linkedMapOf<Stream, Entry>()
    private var geometry: AndroidVideoGeometryMessage? = null
    private var coverage: YlDashVideoCoverage? = null
    private var last: Triple<Entry, AndroidVideoGeometryMessage, YlDashVideoCoverage?>? = null

    // Application thread: do not touch playback-thread collections here.
    fun invalidate() {
        output.generation.incrementAndGet()
        output.publication.incrementAndGet()
    }

    fun stream(startUs: Long, offsetUs: Long, uid: Any) {
        streams[Stream(startUs, offsetUs)] = Entry(uid, output.generation.get())
        // Bound even pathological sequences of replaced streams with no rendered frames.
        while (streams.size > 64) streams.remove(streams.keys.first())
    }

    fun reset(startUs: Long? = null, offsetUs: Long? = null, uid: Any? = null) {
        streams.clear()
        if (startUs != null && offsetUs != null && uid != null) stream(startUs, offsetUs, uid)
        last = null
        if (output.owner === this) {
            val epoch = output.publication.incrementAndGet()
            post { if (output.publication.get() == epoch) receive(null, null, null) }
        }
    }

    fun outputFormat(format: Format, mediaFormat: MediaFormat?) {
        coverage = format.metadata?.let { metadata ->
            (0 until metadata.length()).mapNotNull { metadata[it] as? YlDashVideoCoverage }.distinct().also {
                check(it.size <= 1) { "Conflicting DASH video coverage" }
            }.singleOrNull()
        }
        pendingTransfer = mediaFormat?.takeIf { it.containsKey(MediaFormat.KEY_COLOR_TRANSFER) }
            ?.getInteger(MediaFormat.KEY_COLOR_TRANSFER)
        pendingFormat = format
        verifyFormatBeforeRelease()
        // Same calculation as 1.11 MediaCodecVideoRenderer.onOutputFormatChanged. The Core
        // does not enable a VideoSink; MediaFormat describes the decoded crop.
        var width = format.width
        var height = format.height
        if (mediaFormat != null) {
            val cropped = listOf("crop-left", "crop-right", "crop-top", "crop-bottom").all(mediaFormat::containsKey)
            width = if (cropped) mediaFormat.getInteger("crop-right") - mediaFormat.getInteger("crop-left") + 1
                else mediaFormat.getInteger(MediaFormat.KEY_WIDTH)
            height = if (cropped) mediaFormat.getInteger("crop-bottom") - mediaFormat.getInteger("crop-top") + 1
                else mediaFormat.getInteger(MediaFormat.KEY_HEIGHT)
        }
        var ratio = format.pixelWidthHeightRatio
        if (format.rotationDegrees == 90 || format.rotationDegrees == 270) {
            val oldWidth = width; width = height; height = oldWidth
            ratio = 1f / ratio
        }
        geometry = media3VideoGeometry(VideoSize(width, height, ratio), format)
    }

    fun verifyFormatBeforeRelease() {
        if (output.owner !== this) return
        pendingFormat?.let { dashVideoFamily?.verifyOutput(it, pendingTransfer) }
        pendingFormat = null
    }

    fun rendered(startUs: Long, offsetUs: Long) {
        val stream = streams[Stream(startUs, offsetUs)] ?: return
        val value = geometry ?: return
        if (output.owner !== this || stream.generation != output.generation.get()) return
        if (last?.first == stream && last?.second == value && last?.third == coverage) return // No per-frame Handler work, Format/MediaFormat never cross threads.
        val window = coverage
        last = Triple(stream, value, window)
        val epoch = output.publication.get()
        post {
            if (stream.generation == output.generation.get() && output.publication.get() == epoch)
                receive(stream.uid, value, window)
        }
    }
}

/** Preserves the existing factory's audio/text/etc and the pinned video Builder defaults.
 * DASH may allocate a second video renderer for Media3 to prepare a following Period. */
internal open class YlOutputRenderersFactory(context: Context, private val observer: YlVideoOutputObserver) : DefaultRenderersFactory(context) {
    var allowDashPrewarming = true
    var dashPlayWhenReady: () -> Boolean = { false }
    private var dashStartupAudioPosition: (() -> Long?)? = null
    var dashDecoderSizing: YlDashDecoderSizing? = null
    private var dashAudioWaiting: (() -> Boolean)? = null
    var allowEac3SoftwareAudio = false
    var useConstrainedTvAudioBuffer = false
    var useMiTvPlatformRate = false
    var isMiTv3xRequested: (() -> Boolean)? = null
    // Keep the Google AAC input queue fed while video output and the audio
    // sink compete for playback-thread time at high rates.
    private val miTvAdapters by lazy {
        val ordinary = super.getCodecAdapterFactory()
        val asyncAac = DefaultMediaCodecAdapterFactory(context).forceEnableAsynchronous()
        MediaCodecAdapter.Factory { config ->
            if (config.codecInfo.name.equals("OMX.google.aac.decoder", ignoreCase = true)) {
                asyncAac.createAdapter(config)
            } else ordinary.createAdapter(config)
        }
    }

    override fun getCodecAdapterFactory(): MediaCodecAdapter.Factory =
        if (useMiTvPlatformRate) miTvAdapters else super.getCodecAdapterFactory()

    @Suppress("DEPRECATION")
    override fun buildAudioSink(context: Context, enableFloatOutput: Boolean, enableAudioOutputPlaybackParams: Boolean): androidx.media3.exoplayer.audio.AudioSink? {
        val platformRate = enableAudioOutputPlaybackParams || useMiTvPlatformRate
        val sink = if (useConstrainedTvAudioBuffer) {
            val builder = DefaultAudioSink.Builder(context)
                .setEnableFloatOutput(enableFloatOutput)
                .setEnableAudioOutputPlaybackParameters(platformRate)
            val sizes = YlTvAudioBufferSizeProvider(useMiTvPlatformRate, isMiTv3xRequested)
            if (useMiTvPlatformRate) {
                val provider = AudioTrackAudioOutputProvider.Builder(context).setAudioTrackBufferSizeProvider(sizes).build()
                val playbackSink = builder.setAudioOutputProvider(YlMiTvAudioOutputProvider(provider)).build()
                // DefaultAudioSink can only query capabilities from an unwrapped AudioTrack provider.
                object : ForwardingAudioSink(playbackSink) {
                    override fun getAudioCapabilities() = provider.audioCapabilities
                }
            } else builder.setAudioTrackBufferSizeProvider(sizes).build()
        } else super.buildAudioSink(context, enableFloatOutput, platformRate) ?: return null
        return if (observer.dashVideoFamily != null) YlDashPcmAudioSink(sink) else sink
    }

    override fun buildAudioRenderers(context: Context, extensionRendererMode: Int, mediaCodecSelector: MediaCodecSelector,
        enableDecoderFallback: Boolean, audioSink: androidx.media3.exoplayer.audio.AudioSink, eventHandler: Handler,
        eventListener: androidx.media3.exoplayer.audio.AudioRendererEventListener, out: ArrayList<Renderer>) {
        if (audioSink !is YlDashPcmAudioSink) {
            // Media3 renders in array order. Give the TV's AAC decoder and PCM
            // sink a turn before the synchronous video codec starts or drains.
            val audio = if (useMiTvPlatformRate) ArrayList<Renderer>() else out
            super.buildAudioRenderers(context, extensionRendererMode, mediaCodecSelector, enableDecoderFallback, audioSink, eventHandler, eventListener, audio)
            if (allowEac3SoftwareAudio) audio.add(YlEac3AudioRenderer(eventHandler, eventListener, audioSink))
            if (useMiTvPlatformRate) out.addAll(0, audio)
            return
        }
        check(extensionRendererMode == EXTENSION_RENDERER_MODE_OFF)
        val renderer = object : androidx.media3.exoplayer.audio.MediaCodecAudioRenderer(context, codecAdapterFactory,
            mediaCodecSelector, enableDecoderFallback, eventHandler, eventListener, audioSink) {
            override fun onPositionReset(positionUs: Long, joining: Boolean, sampleStreamIsResetToKeyFrame: Boolean) {
                super.onPositionReset(positionUs, joining, sampleStreamIsResetToKeyFrame)
                audioSink.resetPosition(positionUs)
            }
            override fun processOutputBuffer(positionUs: Long, elapsedRealtimeUs: Long, codec: MediaCodecAdapter?,
                buffer: ByteBuffer?, bufferIndex: Int, bufferFlags: Int, sampleCount: Int,
                bufferPresentationTimeUs: Long, isDecodeOnlyBuffer: Boolean, isLastBuffer: Boolean, format: Format): Boolean {
                val keepTail = isDecodeOnlyBuffer && buffer != null &&
                    bufferFlags and android.media.MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 &&
                    audioSink.keepsPrerollTail(bufferPresentationTimeUs, buffer.remaining())
                return super.processOutputBuffer(positionUs, elapsedRealtimeUs, codec, buffer, bufferIndex,
                    bufferFlags, sampleCount, bufferPresentationTimeUs, isDecodeOnlyBuffer && !keepTail, isLastBuffer, format)
            }
        }
        out.add(renderer)
        if (dashDecoderSizing != null) dashStartupAudioPosition = {
            if (renderer.state == Renderer.STATE_DISABLED || renderer.isEnded) null
            else audioSink.getCurrentPositionUs(false)
        }
        dashAudioWaiting = {
            renderer.state != Renderer.STATE_DISABLED && !renderer.isEnded &&
                audioSink.getCurrentPositionUs(false) == AudioSink.CURRENT_POSITION_NOT_SET
        }
    }

    override fun buildVideoRenderers(context: Context, extensionRendererMode: Int, mediaCodecSelector: MediaCodecSelector,
        enableDecoderFallback: Boolean, eventHandler: Handler, eventListener: VideoRendererEventListener,
        allowedVideoJoiningTimeMs: Long, out: ArrayList<Renderer>) {
        check(extensionRendererMode == EXTENSION_RENDERER_MODE_OFF)
        out.add(videoRenderer(context, mediaCodecSelector, enableDecoderFallback, eventHandler, eventListener, allowedVideoJoiningTimeMs, observer))
    }

    override fun buildSecondaryVideoRenderer(renderer: Renderer, context: Context, extensionRendererMode: Int,
        mediaCodecSelector: MediaCodecSelector, enableDecoderFallback: Boolean, eventHandler: Handler,
        eventListener: VideoRendererEventListener, allowedVideoJoiningTimeMs: Long): Renderer? {
        if (!allowDashPrewarming || renderer !is YlOutputVideoRenderer || dashAudioWaiting == null) return null
        return videoRenderer(context, mediaCodecSelector, enableDecoderFallback, eventHandler, eventListener, allowedVideoJoiningTimeMs, observer.forPrewarming())
    }

    private fun videoRenderer(context: Context, mediaCodecSelector: MediaCodecSelector, enableDecoderFallback: Boolean,
        eventHandler: Handler, eventListener: VideoRendererEventListener, allowedVideoJoiningTimeMs: Long, rendererObserver: YlVideoOutputObserver): YlOutputVideoRenderer {
        val sizing = dashDecoderSizing
        val handoff = sizing?.let { YlDashCodecHandoff(codecAdapterFactory) }
        val builder = MediaCodecVideoRenderer.Builder(context)
            .setCodecAdapterFactory(handoff ?: codecAdapterFactory)
            .setMediaCodecSelector(mediaCodecSelector)
            .setAllowedJoiningTimeMs(allowedVideoJoiningTimeMs)
            .setEnableDecoderFallback(enableDecoderFallback)
            .setEventHandler(eventHandler).setEventListener(eventListener)
            .setMaxDroppedFramesToNotify(MAX_DROPPED_VIDEO_FRAME_COUNT_TO_NOTIFY)
        val audioPosition = { if (dashPlayWhenReady()) dashStartupAudioPosition?.invoke() else null }
        val waiting = { dashAudioWaiting?.invoke() == true }
        return if (handoff != null) {
            YlDashTransitionRenderer(builder, rendererObserver, sizing, audioPosition, waiting, dashPlayWhenReady, handoff)
        } else YlOutputVideoRenderer(builder, rendererObserver, isMiTv3xRequested, sizing, audioPosition, waiting)
    }
}

internal open class YlOutputVideoRenderer(builder: Builder, private val observer: YlVideoOutputObserver,
    private val isMiTv3xRequested: (() -> Boolean)?, private val dashDecoderSizing: YlDashDecoderSizing?,
    private val startupAudioPosition: () -> Long?, private val waitingForAudio: () -> Boolean) : MediaCodecVideoRenderer(builder) {
    // Poll on ordinary renderer iterations. A missing/late audio stream must never
    // prevent a preview, a seek or a video-only Period from producing a frame.
    private companion object { const val MAX_FIRST_FRAME_AUDIO_WAIT_MS = 250L }
    private var firstOutputPending = true
    private var firstOutputWaitStartMs = 0L
    private var startupPollDeadlineMs = 0L
    private val startupGate = YlDashStartupFrameGate()
    protected open fun gateDecoderStartup() = true

    override fun isReady() = super.isReady() || (startupGate.holding && surface != null && codec != null)

    override fun getDurationToProgressUs(positionUs: Long, elapsedRealtimeUs: Long, hasBufferAvailableListener: Boolean): Long {
        val normal = super.getDurationToProgressUs(positionUs, elapsedRealtimeUs, hasBufferAvailableListener)
        if (!firstOutputPending || hasBufferAvailableListener || normal <= 2_000 ||
            isMiTv3xRequested?.invoke() != true || codec == null || configuration.tunneling) return normal
        val now = clock.elapsedRealtime()
        if (startupPollDeadlineMs == 0L) {
            startupPollDeadlineMs = now + 500
            android.util.Log.d("YlPlayer", "Mi TV polling for first untunneled 3x frame")
        }
        return if (now < startupPollDeadlineMs) 2_000 else normal
    }

    override fun processOutputBuffer(positionUs: Long, elapsedRealtimeUs: Long, codec: MediaCodecAdapter?,
        buffer: ByteBuffer?, bufferIndex: Int, bufferFlags: Int, sampleCount: Int,
        bufferPresentationTimeUs: Long, isDecodeOnlyBuffer: Boolean, isLastBuffer: Boolean, format: Format): Boolean {
        if (firstOutputPending && gateDecoderStartup() && surface != null && !isDecodeOnlyBuffer && !isLastBuffer &&
            startupGate.awaitAudio(startupAudioPosition(), state == Renderer.STATE_STARTED, SystemClock.elapsedRealtime())) {
            return false
        }
        if (firstOutputPending && gateDecoderStartup() && surface != null && !isDecodeOnlyBuffer && !isLastBuffer && waitingForAudio()) {
            val now = SystemClock.elapsedRealtime()
            if (firstOutputWaitStartMs == 0L) firstOutputWaitStartMs = now
            if (now - firstOutputWaitStartMs < MAX_FIRST_FRAME_AUDIO_WAIT_MS) return false
        }
        return super.processOutputBuffer(positionUs, elapsedRealtimeUs, codec, buffer, bufferIndex, bufferFlags,
            sampleCount, bufferPresentationTimeUs, isDecodeOnlyBuffer, isLastBuffer, format)
    }

    override fun handleMessage(messageType: Int, message: Any?) {
        super.handleMessage(messageType, message)
        if (messageType == Renderer.MSG_TRANSFER_RESOURCES && message is YlOutputVideoRenderer) {
            message.observer.takeOutput()
        }
    }

    override fun getCodecMaxValues(codecInfo: MediaCodecInfo,
        format: Format, streamFormats: Array<Format>): CodecMaxValues {
        val original = super.getCodecMaxValues(codecInfo, format, streamFormats)
        val next = dashDecoderSizing?.nextFormat(format)
        if (next == null || !codecInfo.adaptive || codecInfo.secure ||
            !codecInfo.isVideoSizeAndRateSupported(next.width, next.height, next.frameRate.toDouble())) {
            return original
        }
        val expanded = super.getCodecMaxValues(codecInfo, format, streamFormats + next)
        return CodecMaxValues(maxOf(original.width, expanded.width), maxOf(original.height, expanded.height),
            maxOf(original.inputSize, expanded.inputSize))
    }

    override fun codecNeedsSetOutputSurfaceWorkaround(codecName: String): Boolean =
        super.codecNeedsSetOutputSurfaceWorkaround(codecName) ||
            needsLegacyHevcSurfaceRestart(codecName)
    override fun onProcessedTunneledBuffer(presentationTimeUs: Long) {
        super.onProcessedTunneledBuffer(presentationTimeUs)
        observer.rendered(outputStreamStartPositionUs, outputStreamOffsetUs)
    }
    override fun getDecoderInfos(selector: MediaCodecSelector, format: Format, requiresSecureDecoder: Boolean): List<androidx.media3.exoplayer.mediacodec.MediaCodecInfo> {
        val candidates = super.getDecoderInfos(selector, format, requiresSecureDecoder)
        // Media3 may offer HEVC/AVC base-layer fallback for Dolby. DASH programme
        // compatibility promises the full selected path, so do not silently downgrade it.
        return if (observer.dashVideoFamily != null && format.sampleMimeType == "video/dolby-vision")
            candidates.filter { it.mimeType == "video/dolby-vision" } else candidates
    }
    override fun onStreamChanged(formats: Array<Format>, startPositionUs: Long, offsetUs: Long, mediaPeriodId: MediaPeriodId) {
        observer.stream(startPositionUs, offsetUs, mediaPeriodId.periodUid)
        super.onStreamChanged(formats, startPositionUs, offsetUs, mediaPeriodId)
    }
    override fun onPositionReset(positionUs: Long, joining: Boolean, sampleStreamIsResetToKeyFrame: Boolean) {
        firstOutputPending = true
        startupGate.cancelWait()
        firstOutputWaitStartMs = 0L
        startupPollDeadlineMs = 0L
        super.onPositionReset(positionUs, joining, sampleStreamIsResetToKeyFrame)
        observer.reset(outputStreamStartPositionUs, outputStreamOffsetUs, mediaPeriodId?.periodUid)
    }
    override fun onDisabled() {
        startupGate.cancelWait()
        observer.reset()
        super.onDisabled()
    }
    override fun onOutputFormatChanged(format: Format, mediaFormat: MediaFormat?) {
        super.onOutputFormatChanged(format, mediaFormat)
        observer.outputFormat(format, mediaFormat)
    }
    override fun renderOutputBuffer(codec: MediaCodecAdapter, index: Int, presentationTimeUs: Long) {
        firstOutputPending = false
        startupGate.rendered()
        observer.verifyFormatBeforeRelease()
        super.renderOutputBuffer(codec, index, presentationTimeUs)
        observer.rendered(outputStreamStartPositionUs, outputStreamOffsetUs)
    }
    override fun renderOutputBufferV21(codec: MediaCodecAdapter, index: Int, presentationTimeUs: Long, releaseTimeNs: Long) {
        firstOutputPending = false
        startupGate.rendered()
        observer.verifyFormatBeforeRelease()
        super.renderOutputBufferV21(codec, index, presentationTimeUs, releaseTimeNs)
        observer.rendered(outputStreamStartPositionUs, outputStreamOffsetUs)
    }
}
