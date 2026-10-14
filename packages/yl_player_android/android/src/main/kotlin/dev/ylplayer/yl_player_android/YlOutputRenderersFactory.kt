package dev.ylplayer.yl_player_android

import android.content.Context
import android.media.MediaFormat
import android.os.Handler
import androidx.media3.common.Format
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.MediaSource.MediaPeriodId
import androidx.media3.exoplayer.video.MediaCodecVideoRenderer
import androidx.media3.exoplayer.video.VideoRendererEventListener
import dev.ylplayer.yl_player_android.pigeon.AndroidVideoGeometryMessage
import java.util.concurrent.atomic.AtomicLong

/** Pinned to Media3 1.11's output-format queue and output-stream clock, never its input Format.
 * All mutable observations live on the playback thread. Only changed immutable values are posted
 * to the application handler; the atomic generation also fences already queued lifecycle work. */
internal class YlVideoOutputObserver(
    private val post: (() -> Unit) -> Unit,
    private val receive: (Any?, AndroidVideoGeometryMessage?) -> Unit,
) {
    var dashVideoFamily: YlDashVideoFamilyPolicy? = null
    private data class Stream(val startUs: Long, val offsetUs: Long)
    private data class Entry(val uid: Any, val generation: Long)
    private val generation = AtomicLong()
    private val streams = linkedMapOf<Stream, Entry>()
    private var geometry: AndroidVideoGeometryMessage? = null
    private var last: Pair<Entry, AndroidVideoGeometryMessage>? = null

    // Application thread: do not touch playback-thread collections here.
    fun invalidate() { generation.incrementAndGet() }

    fun stream(startUs: Long, offsetUs: Long, uid: Any) {
        streams[Stream(startUs, offsetUs)] = Entry(uid, generation.get())
        // Bound even pathological sequences of replaced streams with no rendered frames.
        while (streams.size > 64) streams.remove(streams.keys.first())
    }

    fun reset(startUs: Long? = null, offsetUs: Long? = null, uid: Any? = null) {
        val epoch = generation.incrementAndGet()
        streams.clear()
        if (startUs != null && offsetUs != null && uid != null) stream(startUs, offsetUs, uid)
        last = null
        post { if (generation.get() == epoch) receive(null, null) }
    }

    fun outputFormat(format: Format, mediaFormat: MediaFormat?) {
        dashVideoFamily?.verifyOutput(format, mediaFormat?.takeIf { it.containsKey(MediaFormat.KEY_COLOR_TRANSFER) }
            ?.getInteger(MediaFormat.KEY_COLOR_TRANSFER))
        // Same calculation as 1.11 MediaCodecVideoRenderer.onOutputFormatChanged. The Core
        // does not enable tunneling or a VideoSink; MediaFormat describes the decoded crop.
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

    fun rendered(startUs: Long, offsetUs: Long) {
        val stream = streams[Stream(startUs, offsetUs)] ?: return
        val value = geometry ?: return
        if (stream.generation != generation.get()) return
        if (last?.first == stream && last?.second == value) return // No per-frame Handler work, Format/MediaFormat never cross threads.
        last = stream to value
        post { if (stream.generation == generation.get()) receive(stream.uid, value) }
    }
}

/** Preserves the existing factory's audio/text/etc and the pinned video Builder defaults.
 * Core uses extensions OFF, no prewarming/VideoSink/tunneling, and only configures decoder policy. */
internal open class YlOutputRenderersFactory(context: Context, private val observer: YlVideoOutputObserver) : DefaultRenderersFactory(context) {
    override fun buildAudioSink(context: Context, enableFloatOutput: Boolean, enableAudioOutputPlaybackParams: Boolean): androidx.media3.exoplayer.audio.AudioSink? {
        val sink = super.buildAudioSink(context, enableFloatOutput, enableAudioOutputPlaybackParams) ?: return null
        return if (observer.dashVideoFamily != null) YlDashPcmAudioSink(sink) else sink
    }

    override fun buildAudioRenderers(context: Context, extensionRendererMode: Int, mediaCodecSelector: MediaCodecSelector,
        enableDecoderFallback: Boolean, audioSink: androidx.media3.exoplayer.audio.AudioSink, eventHandler: Handler,
        eventListener: androidx.media3.exoplayer.audio.AudioRendererEventListener, out: ArrayList<Renderer>) {
        if (audioSink !is YlDashPcmAudioSink) {
            super.buildAudioRenderers(context, extensionRendererMode, mediaCodecSelector, enableDecoderFallback, audioSink, eventHandler, eventListener, out)
            return
        }
        check(extensionRendererMode == EXTENSION_RENDERER_MODE_OFF)
        out.add(object : androidx.media3.exoplayer.audio.MediaCodecAudioRenderer(context, codecAdapterFactory,
            mediaCodecSelector, enableDecoderFallback, eventHandler, eventListener, audioSink) {
            override fun onPositionReset(positionUs: Long, joining: Boolean, sampleStreamIsResetToKeyFrame: Boolean) {
                super.onPositionReset(positionUs, joining, sampleStreamIsResetToKeyFrame)
                audioSink.resetPosition(positionUs)
            }
            override fun processOutputBuffer(positionUs: Long, elapsedRealtimeUs: Long, codec: MediaCodecAdapter?,
                buffer: java.nio.ByteBuffer?, bufferIndex: Int, bufferFlags: Int, sampleCount: Int,
                bufferPresentationTimeUs: Long, isDecodeOnlyBuffer: Boolean, isLastBuffer: Boolean, format: Format): Boolean {
                val keepTail = isDecodeOnlyBuffer && buffer != null &&
                    bufferFlags and android.media.MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 &&
                    audioSink.keepsPrerollTail(bufferPresentationTimeUs, buffer.remaining())
                return super.processOutputBuffer(positionUs, elapsedRealtimeUs, codec, buffer, bufferIndex,
                    bufferFlags, sampleCount, bufferPresentationTimeUs, isDecodeOnlyBuffer && !keepTail, isLastBuffer, format)
            }
        })
    }

    override fun buildVideoRenderers(context: Context, extensionRendererMode: Int, mediaCodecSelector: MediaCodecSelector,
        enableDecoderFallback: Boolean, eventHandler: Handler, eventListener: VideoRendererEventListener,
        allowedVideoJoiningTimeMs: Long, out: ArrayList<Renderer>) {
        check(extensionRendererMode == EXTENSION_RENDERER_MODE_OFF)
        val builder = MediaCodecVideoRenderer.Builder(context)
            .setCodecAdapterFactory(codecAdapterFactory)
            .setMediaCodecSelector(mediaCodecSelector)
            .setAllowedJoiningTimeMs(allowedVideoJoiningTimeMs)
            .setEnableDecoderFallback(enableDecoderFallback)
            .setEventHandler(eventHandler).setEventListener(eventListener)
            .setMaxDroppedFramesToNotify(MAX_DROPPED_VIDEO_FRAME_COUNT_TO_NOTIFY)
        out.add(YlOutputVideoRenderer(builder, observer))
    }
}

internal class YlOutputVideoRenderer(builder: Builder, private val observer: YlVideoOutputObserver) : MediaCodecVideoRenderer(builder) {
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
        super.onPositionReset(positionUs, joining, sampleStreamIsResetToKeyFrame)
        observer.reset(outputStreamStartPositionUs, outputStreamOffsetUs, mediaPeriodId?.periodUid)
    }
    override fun onDisabled() {
        observer.reset()
        super.onDisabled()
    }
    override fun onOutputFormatChanged(format: Format, mediaFormat: MediaFormat?) {
        super.onOutputFormatChanged(format, mediaFormat)
        observer.outputFormat(format, mediaFormat)
    }
    override fun renderOutputBuffer(codec: MediaCodecAdapter, index: Int, presentationTimeUs: Long) {
        super.renderOutputBuffer(codec, index, presentationTimeUs)
        observer.rendered(outputStreamStartPositionUs, outputStreamOffsetUs)
    }
    override fun renderOutputBufferV21(codec: MediaCodecAdapter, index: Int, presentationTimeUs: Long, releaseTimeNs: Long) {
        super.renderOutputBufferV21(codec, index, presentationTimeUs, releaseTimeNs)
        observer.rendered(outputStreamStartPositionUs, outputStreamOffsetUs)
    }
}
