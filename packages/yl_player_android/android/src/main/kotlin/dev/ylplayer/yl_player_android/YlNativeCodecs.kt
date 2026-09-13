package dev.ylplayer.yl_player_android

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.PlaybackParams
import android.os.Build
import android.view.Surface
import java.nio.ByteBuffer
import kotlin.math.max

internal object YlHardwareCodecProbe {
    fun findVideoDecoder(stream: YlNativeStreamInfo): String? {
        val mime = stream.codec.mimeType ?: return null
        val format = MediaFormat.createVideoFormat(mime, stream.width, stream.height).apply {
            if (stream.frameRate > 0) setFloat(MediaFormat.KEY_FRAME_RATE, stream.frameRate.toFloat())
        }
        return MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull { info ->
            !info.isEncoder && info.supportedTypes.any { it.equals(mime, ignoreCase = true) } &&
                isHardware(info) && runCatching {
                    val capabilities = info.getCapabilitiesForType(mime)
                    capabilities.isFormatSupported(format) && supportsProfile(capabilities, stream)
                }.getOrDefault(false)
        }?.name
    }

    private fun isHardware(info: MediaCodecInfo): Boolean = if (Build.VERSION.SDK_INT >= 29) {
        info.isHardwareAccelerated
    } else {
        val name = info.name.lowercase()
        !name.startsWith("omx.google.") && !name.startsWith("c2.android.") && !name.contains("sw")
    }

    private fun supportsProfile(capabilities: MediaCodecInfo.CodecCapabilities, stream: YlNativeStreamInfo): Boolean {
        val profile = when (stream.codec) {
            YlNativeCodec.H264 -> when (stream.profile) {
                66 -> MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline
                77 -> MediaCodecInfo.CodecProfileLevel.AVCProfileMain
                88 -> MediaCodecInfo.CodecProfileLevel.AVCProfileExtended
                100 -> MediaCodecInfo.CodecProfileLevel.AVCProfileHigh
                110 -> MediaCodecInfo.CodecProfileLevel.AVCProfileHigh10
                else -> null
            }
            YlNativeCodec.HEVC -> when (stream.profile) {
                1 -> MediaCodecInfo.CodecProfileLevel.HEVCProfileMain
                2 -> MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10
                else -> null
            }
            else -> null
        } ?: return true
        val level = androidLevel(stream)
        return capabilities.profileLevels.any { it.profile == profile && (level == null || it.level >= level) }
    }

    private fun androidLevel(stream: YlNativeStreamInfo): Int? = when (stream.codec) {
        YlNativeCodec.H264 -> when (stream.level) {
            10 -> MediaCodecInfo.CodecProfileLevel.AVCLevel1
            11 -> MediaCodecInfo.CodecProfileLevel.AVCLevel11
            12 -> MediaCodecInfo.CodecProfileLevel.AVCLevel12
            13 -> MediaCodecInfo.CodecProfileLevel.AVCLevel13
            20 -> MediaCodecInfo.CodecProfileLevel.AVCLevel2
            21 -> MediaCodecInfo.CodecProfileLevel.AVCLevel21
            22 -> MediaCodecInfo.CodecProfileLevel.AVCLevel22
            30 -> MediaCodecInfo.CodecProfileLevel.AVCLevel3
            31 -> MediaCodecInfo.CodecProfileLevel.AVCLevel31
            32 -> MediaCodecInfo.CodecProfileLevel.AVCLevel32
            40 -> MediaCodecInfo.CodecProfileLevel.AVCLevel4
            41 -> MediaCodecInfo.CodecProfileLevel.AVCLevel41
            42 -> MediaCodecInfo.CodecProfileLevel.AVCLevel42
            50 -> MediaCodecInfo.CodecProfileLevel.AVCLevel5
            51 -> MediaCodecInfo.CodecProfileLevel.AVCLevel51
            52 -> MediaCodecInfo.CodecProfileLevel.AVCLevel52
            else -> null
        }
        YlNativeCodec.HEVC -> when (stream.level) {
            30 -> MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel1
            60 -> MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel2
            63 -> MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel21
            90 -> MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel3
            93 -> MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel31
            120 -> MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel4
            123 -> MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel41
            150 -> MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel5
            153 -> MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel51
            156 -> MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel52
            180 -> MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel6
            183 -> MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel61
            186 -> MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel62
            else -> null
        }
        else -> null
    }
}

internal class YlHardwareVideoDecoder(
    stream: YlNativeStreamInfo,
    surface: Surface,
    codecName: String,
    codecConfig: ByteArray,
) : AutoCloseable {
    private val codec = MediaCodec.createByCodecName(codecName)
    private val info = MediaCodec.BufferInfo()
    init {
        val format = MediaFormat.createVideoFormat(checkNotNull(stream.codec.mimeType), stream.width, stream.height)
        if (stream.frameRate > 0) format.setFloat(MediaFormat.KEY_FRAME_RATE, stream.frameRate.toFloat())
        if (codecConfig.isNotEmpty()) format.setByteBuffer("csd-0", ByteBuffer.wrap(codecConfig))
        codec.configure(format, surface, null, 0)
        codec.start()
    }

    fun consume(packet: YlNativePacket): Boolean {
        var rendered = drainOutput()
        var inputIndex: Int
        do {
            inputIndex = codec.dequeueInputBuffer(5_000)
            if (inputIndex < 0) rendered = drainOutput() || rendered
        } while (inputIndex < 0)
        if (inputIndex >= 0) {
            val input = checkNotNull(codec.getInputBuffer(inputIndex))
            input.clear()
            if (packet.data.size > input.remaining()) throw YlBoundaryException(YlFailureKind.DECODER_UNSUPPORTED)
            input.put(packet.data)
            codec.queueInputBuffer(inputIndex, 0, packet.data.size,
                packet.presentationTimeUs.coerceAtLeast(0), if (packet.keyFrame) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
        }
        return drainOutput() || rendered
    }

    private fun drainOutput(): Boolean {
        var rendered = false
        while (true) {
            when (val outputIndex = codec.dequeueOutputBuffer(info, 0)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> return rendered
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> Unit
                else -> if (outputIndex >= 0) {
                    val render = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0
                    codec.releaseOutputBuffer(outputIndex, render)
                    rendered = rendered || render
                }
            }
        }
    }

    fun flush() = codec.flush()
    fun replaceSurface(surface: Surface) = codec.setOutputSurface(surface)
    override fun close() { runCatching { codec.stop() }; codec.release() }
}

internal class YlPcmAudioOutput(
    private val session: YlFfmpegSession,
    private val stream: YlNativeStreamInfo,
) : AutoCloseable {
    private var output: AudioTrack? = null
    private var firstPresentationUs = Long.MIN_VALUE
    private var writtenFrames = 0L
    private var volume = 1f
    private var speed = 1f
    private var playing = false
    private var playbackRateParametersApplied = false

    init {
        if (!session.configureSoftwareAudio(stream.index)) throw YlBoundaryException(YlFailureKind.DECODER_UNSUPPORTED)
    }

    fun consume(packet: YlNativePacket) {
        val pcm = session.decodeSoftwareAudio(packet) ?: return
        val audio = output ?: create(pcm).also { output = it }
        if (firstPresentationUs == Long.MIN_VALUE) firstPresentationUs = pcm.presentationTimeUs.coerceAtLeast(0)
        var offset = 0
        while (offset < pcm.data.size) {
            val count = audio.write(pcm.data, offset, pcm.data.size - offset, AudioTrack.WRITE_BLOCKING)
            if (count <= 0) throw YlBoundaryException(YlFailureKind.PLATFORM_FAILURE)
            offset += count
        }
        writtenFrames += pcm.data.size / (pcm.channelCount * 2L)
    }

    private fun create(pcm: YlNativePcmChunk): AudioTrack {
        val channels = if (pcm.channelCount == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
        val minimum = AudioTrack.getMinBufferSize(pcm.sampleRate, channels, AudioFormat.ENCODING_PCM_16BIT)
        return AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
            .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(pcm.sampleRate).setChannelMask(channels).build())
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(max(minimum, pcm.sampleRate * pcm.channelCount * 2 / 2))
            .build().also { applyParameters(it); if (playing) it.play() }
    }

    fun play() { playing = true; output?.play() }
    fun pause() { playing = false; output?.pause() }
    fun flush() {
        output?.let { audio -> audio.pause(); audio.flush() }
        firstPresentationUs = Long.MIN_VALUE
        writtenFrames = 0
    }
    fun setVolume(value: Double) { volume = value.toFloat(); output?.setVolume(volume) }
    fun setSpeed(value: Double) { speed = value.toFloat(); output?.let(::applyParameters) }
    private fun applyParameters(audio: AudioTrack) {
        audio.setVolume(volume)
        if (!YlAudioPlaybackRatePolicy.shouldApply(speed, playbackRateParametersApplied)) return
        runCatching {
            audio.playbackParams = PlaybackParams().setSpeed(speed).setPitch(1f)
                .setAudioFallbackMode(PlaybackParams.AUDIO_FALLBACK_MODE_DEFAULT)
        }.onSuccess { playbackRateParametersApplied = true }
    }

    fun positionUs(): Long? {
        val audio = output ?: return null
        if (firstPresentationUs == Long.MIN_VALUE || stream.sampleRate <= 0) return null
        return firstPresentationUs + audio.playbackHeadPosition.toLong() * 1_000_000L / stream.sampleRate
    }

    override fun close() {
        output?.let { runCatching { it.stop() }; it.release() }
        output = null
        playbackRateParametersApplied = false
    }
}
