package dev.ylplayer.yl_player_android

import android.os.Handler
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.decoder.*
import androidx.media3.exoplayer.audio.*

/** Last audio renderer on legacy TVs: retain Media3's clock and tunneled video
 * when the platform has no E-AC-3 decoder. Existing system renderers win ties. */
internal class YlEac3AudioRenderer(handler: Handler, listener: AudioRendererEventListener, sink: AudioSink) :
    DecoderAudioRenderer<YlEac3AudioDecoder>(handler, listener, sink) {
    override fun getName() = "YlEac3AudioRenderer"
    override fun supportsFormatInternal(format: Format): Int = when {
        !accepts(format) || !YlFfmpegBridge.available -> C.FORMAT_UNSUPPORTED_SUBTYPE
        !sinkSupportsFormat(pcmFormat(format.sampleRate)) -> C.FORMAT_UNSUPPORTED_SUBTYPE
        else -> C.FORMAT_HANDLED
    }
    override fun createDecoder(format: Format, cryptoConfig: CryptoConfig?): YlEac3AudioDecoder {
        if (cryptoConfig != null || !accepts(format)) throw DecoderException("Unsupported clear E-AC-3 format")
        return YlEac3AudioDecoder.create(format.sampleRate, format.channelCount)
    }
    override fun getOutputFormat(decoder: YlEac3AudioDecoder): Format = pcmFormat(decoder.sampleRate)
    companion object {
        fun accepts(format: Format): Boolean = format.sampleMimeType == MimeTypes.AUDIO_E_AC3 &&
            format.cryptoType == C.CRYPTO_TYPE_NONE && format.drmInitData == null &&
            format.sampleRate in listOf(32000, 44100, 48000) && format.channelCount in 1..8
        private fun pcmFormat(rate: Int) = Format.Builder().setSampleMimeType(MimeTypes.AUDIO_RAW)
            .setSampleRate(rate).setChannelCount(2).setPcmEncoding(C.ENCODING_PCM_16BIT).build()
    }
}

/** Media3 owns a bounded decode thread and handles preroll, EOS and sink timing.
 * Native state is closed only after SimpleDecoder has joined that thread. */
@Suppress("UNCHECKED_CAST") // SimpleDecoder fills both arrays before exposing them.
internal class YlEac3AudioDecoder private constructor(private var handle: Long, val sampleRate: Int) :
    SimpleDecoder<DecoderInputBuffer, SimpleDecoderOutputBuffer, DecoderException>(
        arrayOfNulls<DecoderInputBuffer>(8) as Array<DecoderInputBuffer>,
        arrayOfNulls<SimpleDecoderOutputBuffer>(8) as Array<SimpleDecoderOutputBuffer>) {
    init { setInitialInputBufferSize(16 * 1024) }
    override fun getName() = "yl-ffmpeg-eac3"
    override fun createInputBuffer() = DecoderInputBuffer(DecoderInputBuffer.BUFFER_REPLACEMENT_MODE_NORMAL)
    override fun createOutputBuffer() = SimpleDecoderOutputBuffer { releaseOutputBuffer(it) }
    override fun createUnexpectedDecodeException(error: Throwable) = DecoderException("E-AC-3 decode failed", error)
    override fun decode(input: DecoderInputBuffer, output: SimpleDecoderOutputBuffer, reset: Boolean): DecoderException? {
        val data = input.data ?: return DecoderException("Missing E-AC-3 packet")
        if (input.isEncrypted || data.remaining() !in 1..MAX_PACKET_BYTES) return DecoderException("Invalid E-AC-3 packet")
        val packet = ByteArray(data.remaining()).also(data::get)
        val pcm = YlFfmpegBridge.nativeDecodeEac3(handle, packet, reset)
            ?: return DecoderException("E-AC-3 decoder rejected packet")
        output.init(input.timeUs, pcm.size).put(pcm).flip()
        if (pcm.isEmpty()) output.shouldBeSkipped = true
        return null
    }
    override fun release() {
        super.release()
        val old = handle; handle = 0
        if (old != 0L) YlFfmpegBridge.nativeCloseEac3(old)
    }
    companion object {
        private const val MAX_PACKET_BYTES = 1024 * 1024
        fun create(sampleRate: Int, channels: Int): YlEac3AudioDecoder {
            if (!YlFfmpegBridge.available) throw DecoderException("Native audio decoder unavailable")
            val handle = YlFfmpegBridge.nativeCreateEac3(sampleRate, channels)
            if (handle == 0L) throw DecoderException("E-AC-3 initialization failed")
            return YlEac3AudioDecoder(handle, sampleRate)
        }
    }
}
