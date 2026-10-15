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

    // A vendor-looking name is not proof on older Android releases.
    private fun isHardware(info: MediaCodecInfo): Boolean = Build.VERSION.SDK_INT >= 29 &&
        info.isHardwareAccelerated && !info.isSoftwareOnly

    private fun supportsProfile(capabilities: MediaCodecInfo.CodecCapabilities, stream: YlNativeStreamInfo): Boolean {
        val profile = when (stream.codec) {
            YlNativeCodec.H264 -> when (stream.profile) {
                66, 578 -> MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline
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
        } ?: return false
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
    private val cancelled: () -> Boolean = { false },
) : AutoCloseable {
    private val codec = MediaCodec.createByCodecName(codecName)
    private val info = MediaCodec.BufferInfo()
    private val configuration = codecConfig.copyOf()
    private var resendConfiguration = false
    private var observedOutput = false
    private var presentationFloorUs = 0L
    private var reachedEos = false
    /** Identity of the initialized codec, rather than its discovery candidate. */
    val decoderIdentity: String get() = codec.name
    init {
      try {
        val actual = codec.codecInfo
        if (Build.VERSION.SDK_INT < 29 || !actual.isHardwareAccelerated || actual.isSoftwareOnly) {
            throw YlBoundaryException(YlFailureKind.DECODER_UNAVAILABLE)
        }
        val format = MediaFormat.createVideoFormat(checkNotNull(stream.codec.mimeType), stream.width, stream.height)
        if (stream.frameRate > 0) format.setFloat(MediaFormat.KEY_FRAME_RATE, stream.frameRate.toFloat())
        if (codecConfig.isNotEmpty()) {
            if (stream.codec == YlNativeCodec.H264) {
                val units = androidx.media3.common.util.CodecSpecificDataUtil.splitNalUnits(codecConfig)
                    ?: throw YlBoundaryException(YlFailureKind.DECODER_UNSUPPORTED)
                val sps = units.filter { (if (it.size > 4) it[4].toInt() and 31 else -1) == 7 }.fold(byteArrayOf()) { a,b -> a+b }
                val pps = units.filter { (if (it.size > 4) it[4].toInt() and 31 else -1) == 8 }.fold(byteArrayOf()) { a,b -> a+b }
                if (sps.isEmpty() || pps.isEmpty()) throw YlBoundaryException(YlFailureKind.DECODER_UNSUPPORTED)
                format.setByteBuffer("csd-0", ByteBuffer.wrap(sps))
                format.setByteBuffer("csd-1", ByteBuffer.wrap(pps))
            } else format.setByteBuffer("csd-0", ByteBuffer.wrap(codecConfig))
        }
        codec.configure(format, surface, null, 0)
        codec.start()
      } catch (error: Throwable) {
        codec.release()
        throw error
      }
    }

    private fun queue(bytes: ByteArray, pts: Long, flags: Int): Boolean {
        val deadline = System.nanoTime()+5_000_000_000L
        var rendered = false
        while (true) {
            if (cancelled() || Thread.currentThread().isInterrupted) throw kotlinx.coroutines.CancellationException()
            if (System.nanoTime() >= deadline) throw YlBoundaryException(YlFailureKind.DECODER_UNAVAILABLE)
            val index=codec.dequeueInputBuffer(5_000)
            if (index < 0) { rendered=drainOutput() || rendered; continue }
            val input=checkNotNull(codec.getInputBuffer(index)); input.clear()
            if (bytes.size>input.remaining()) throw YlBoundaryException(YlFailureKind.DECODER_UNSUPPORTED)
            input.put(bytes);codec.queueInputBuffer(index,0,bytes.size,pts,flags)
            return drainOutput() || rendered
        }
    }
    fun consume(packet: YlNativePacket): Boolean {
        var rendered=drainOutput()
        if (resendConfiguration) {
            rendered=queue(configuration,0,MediaCodec.BUFFER_FLAG_CODEC_CONFIG) || rendered
            resendConfiguration=false
        }
        return queue(canonicalAnnexB(packet.data),packet.presentationTimeUs.coerceAtLeast(0),
            if(packet.keyFrame) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0) || rendered
    }
    /** Drain reordered output before publishing completion; cancellation remains bounded. */
    fun finish(): Boolean {
        if (reachedEos) return false
        var rendered=queue(byteArrayOf(),0,MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        val deadline=System.nanoTime()+5_000_000_000L
        while (!reachedEos) {
            if (cancelled()) throw kotlinx.coroutines.CancellationException()
            if (System.nanoTime()>=deadline) throw YlBoundaryException(YlFailureKind.DECODER_UNAVAILABLE)
            rendered=drainOutput() || rendered
            if (!reachedEos) Thread.sleep(1)
        }
        return rendered
    }

    private fun drainOutput(): Boolean {
        var rendered = false
        while (true) {
            when (val outputIndex = codec.dequeueOutputBuffer(info, 0)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> return rendered
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> { observedOutput=true }
                else -> if (outputIndex >= 0) {
                    observedOutput=true
                    reachedEos = reachedEos || info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    val render = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 &&
                        !(info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0 && info.size == 0) &&
                        info.presentationTimeUs >= presentationFloorUs
                    codec.releaseOutputBuffer(outputIndex, render)
                    rendered = rendered || render
                }
            }
        }
    }

    fun flush(targetUs: Long = 0) {
        // Android MediaCodec documents CSD loss on flush before first output.
        resendConfiguration = !observedOutput && configuration.isNotEmpty()
        codec.flush(); reachedEos=false; presentationFloorUs=targetUs
    }
    fun replaceSurface(surface: Surface) = codec.setOutputSurface(surface)
    override fun close() { runCatching { codec.stop() }; codec.release() }
}

internal class YlPcmAudioOutput(
    private val session: YlFfmpegSession,
    private val stream: YlNativeStreamInfo,
) : AutoCloseable {
    private var output: AudioTrack? = null
    private val pendingWrite = YlPendingPcmWrite()
    private var firstPresentationUs = Long.MIN_VALUE
    private var presentationFloorUs = 0L
    private var writtenFrames = 0L
    private var outputChannelCount = 0
    private var clockFramePosition = 0L
    private var clockTimestampNs = 0L
    private var volume = 1f
    private var speed = 1f
    private var playing = false
    private var playbackRateParametersApplied = false

    init {
        if (!session.configureSoftwareAudio(stream.index)) throw YlBoundaryException(YlFailureKind.DECODER_UNSUPPORTED)
    }

    val hasPendingData: Boolean get() = pendingWrite.hasData
    val hasQueuedPlayback: Boolean get() = output?.let {
        (it.playbackHeadPosition.toLong() and 0xffffffffL) < writtenFrames
    } ?: false

    fun consume(packet: YlNativePacket) {
        check(!pendingWrite.hasData)
        val pcm = session.decodeSoftwareAudio(packet)?.let { trimNativePcm(it,presentationFloorUs) } ?: return
        if (firstPresentationUs == Long.MIN_VALUE) firstPresentationUs = pcm.presentationTimeUs.coerceAtLeast(0)
        outputChannelCount = pcm.channelCount.coerceAtLeast(1)
        output ?: create(pcm).also { output = it }
        pendingWrite.enqueue(pcm.data)
    }

    fun drainPending(): Int {
        val audio = output ?: return 0
        val written = pendingWrite.writeAvailable { data, offset, length ->
            audio.write(data, offset, length, AudioTrack.WRITE_NON_BLOCKING).also {
                if (it < 0) throw YlBoundaryException(YlFailureKind.PLATFORM_FAILURE)
            }
        }
        writtenFrames += written / (outputChannelCount * 2L)
        return written
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
            .build().also {
                applyParameters(it)
                if (playing) {
                    it.play()
                    resetClockAnchor(it)
                }
            }
    }

    fun play() {
        playing = true
        output?.let {
            it.play()
            resetClockAnchor(it)
        }
    }
    fun pause() { playing = false; output?.pause() }
    fun flush(targetUs: Long = 0) {
        presentationFloorUs=targetUs
        output?.let { audio ->
            audio.pause()
            audio.flush()
            if (playing) {
                audio.play()
                resetClockAnchor(audio)
            }
        }
        pendingWrite.clear()
        firstPresentationUs = Long.MIN_VALUE
        writtenFrames = 0
        outputChannelCount = 0
        clockFramePosition = 0
        clockTimestampNs = 0
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
        val coarseFramePosition = audio.playbackHeadPosition.toLong() and 0xffffffffL
        if (!playing) {
            return firstPresentationUs + coarseFramePosition * 1_000_000L / stream.sampleRate
        }
        if (clockTimestampNs == 0L) resetClockAnchor(audio)
        val nowNs = System.nanoTime()
        val estimated = YlAudioClockEstimator.positionUs(
            firstPresentationUs = firstPresentationUs,
            sampleRate = stream.sampleRate,
            hardwareFramePosition = clockFramePosition,
            hardwareTimestampNs = clockTimestampNs,
            nowNs = nowNs,
            speed = speed.toDouble(),
            writtenFrames = writtenFrames,
        )
        val lastWrittenPositionUs = firstPresentationUs + writtenFrames * 1_000_000L / stream.sampleRate
        if (estimated == lastWrittenPositionUs) {
            clockFramePosition = writtenFrames
            clockTimestampNs = nowNs
        }
        return estimated
    }

    private fun resetClockAnchor(audio: AudioTrack) {
        clockFramePosition = audio.playbackHeadPosition.toLong() and 0xffffffffL
        clockTimestampNs = System.nanoTime()
    }

    override fun close() {
        pendingWrite.clear()
        output?.let { runCatching { it.stop() }; it.release() }
        output = null
        playbackRateParametersApplied = false
        clockFramePosition = 0
        clockTimestampNs = 0
    }
}
