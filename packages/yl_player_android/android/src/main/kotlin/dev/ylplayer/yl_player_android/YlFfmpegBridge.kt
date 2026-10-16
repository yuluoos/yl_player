package dev.ylplayer.yl_player_android

import android.view.Surface

internal class YlFfmpegSession private constructor(
    private var handle: Long,
    private val source: YlNativeByteSource,
) : AutoCloseable {
    private var software: YlSoftwareDecodeLease? = null
    val mediaInfo: YlNativeMediaInfo

    init {
        val count = YlFfmpegBridge.nativeStreamCount(handle)
        val streams = (0 until count).map(::streamInfo)
        mediaInfo = YlNativeMediaInfo(
            YlFfmpegBridge.nativeDurationUs(handle),
            YlFfmpegBridge.nativeIsSeekable(handle),
            streams,
        )
    }

    private fun streamInfo(index: Int): YlNativeStreamInfo {
        val values = YlFfmpegBridge.nativeStreamInfo(handle, index)
        return decodeStreamMetadata(index, values,
            YlFfmpegBridge.nativeStreamLanguage(handle, index),
            YlFfmpegBridge.nativeStreamCodecConfig(handle, index))
    }

    fun configureHardwareVideo(streamIndex: Int): Boolean =
        YlFfmpegBridge.nativeConfigureHardwareVideo(handle, streamIndex)

    fun hardwareCodecConfig(): ByteArray = YlFfmpegBridge.nativeHardwareCodecConfig(handle)

    fun configureSoftwareVideo(streamIndex: Int, surface: Surface, lease: YlSoftwareDecodeLease): Boolean {
        software = lease
        val result = lease.measured { YlFfmpegBridge.nativeConfigureSoftwareVideoV2(handle, streamIndex, surface,
            longArrayOf(1, lease.limits.maxOwnedBytes, lease.limits.maxFrames.toLong(),
                lease.limits.maxPacketBytes.toLong(), lease.key.threads.toLong(), 6), lease.budget) }
        if (!result) checkSoftwareFailure()
        return result
    }

    private fun checkSoftwareFailure() {
        if (YlFfmpegBridge.nativeSoftwareBudgetExhausted(handle)) throw YlBoundaryException(YlFailureKind.RESOURCE_EXHAUSTED)
    }

    fun configureSoftwareAudio(streamIndex: Int): Boolean =
        YlFfmpegBridge.nativeConfigureSoftwareAudio(handle, streamIndex)

    fun readPacket(): YlNativePacket? {
        val metadata = YlFfmpegBridge.nativeReadPacket(handle) ?: return null
        if (metadata[0] == -2L) throw YlBoundaryException(YlFailureKind.RESOURCE_EXHAUSTED)
        if (metadata[0] < 0) throw YlBoundaryException(YlFailureKind.NETWORK_FAILED)
        if (metadata.size != 6 || metadata[5] !in 1..Int.MAX_VALUE.toLong()) throw YlBoundaryException(YlFailureKind.DECODER_UNAVAILABLE)
        val ownership = software?.budget?.reservePacket(metadata[5].toInt())
        try {
            val bytes = YlFfmpegBridge.nativeTakePacketData(handle)
            return YlNativePacket(metadata[0].toInt(), bytes, metadata[1], metadata[2], metadata[3], metadata[4] != 0L, ownership)
        } catch (failure: Throwable) { ownership?.close(); throw failure }
    }

    fun decodeSoftwareVideo(packet: YlNativePacket): LongArray {
        val lease = checkNotNull(software)
        return lease.measured { YlFfmpegBridge.nativeDecodeSoftwareVideo(handle, packet.data,
            packet.presentationTimeUs, packet.decodeTimeUs) } ?: run {
            checkSoftwareFailure(); throw YlBoundaryException(YlFailureKind.DECODER_UNSUPPORTED)
        }
    }

    fun finishSoftwareVideo(): LongArray =
        checkNotNull(software).measured { YlFfmpegBridge.nativeFinishSoftwareVideo(handle) }
            ?: run { checkSoftwareFailure(); throw YlBoundaryException(YlFailureKind.DECODER_UNSUPPORTED) }

    fun renderSoftwareVideoFrame(): Boolean =
        YlFfmpegBridge.nativeRenderSoftwareVideoFrame(handle)

    /** Decodes the selected stream with retained codec history. This returns
     * untrimmed PCM; YlPcmAudioOutput removes seek/initial preroll before enqueue.
     * Reconfiguration/flush resets history and requires feeding preroll again. */
    fun decodeSoftwareAudio(packet: YlNativePacket): YlNativePcmChunk? {
        val metadata = YlFfmpegBridge.nativeDecodeSoftwareAudio(handle, packet.data, packet.presentationTimeUs) ?: return null
        return YlNativePcmChunk(YlFfmpegBridge.nativeTakePcmData(handle), metadata[0].toInt(), metadata[1].toInt(), metadata[2])
    }

    fun seekTo(positionUs: Long): Boolean = YlFfmpegBridge.nativeSeek(handle, positionUs)
    fun flush() = YlFfmpegBridge.nativeFlush(handle)
    fun cancel() = source.cancel()

    override fun close() {
        val value = handle
        if (value == 0L) return
        handle = 0
        source.cancel()
        YlFfmpegBridge.nativeClose(value)
        source.close()
        software?.close(); software = null
    }

    companion object {
        fun open(source: YlNativeByteSource): YlFfmpegSession {
            if (!YlFfmpegBridge.available) throw YlBoundaryException(YlFailureKind.PLATFORM_UNAVAILABLE)
            val handle = YlFfmpegBridge.nativeOpen(source)
            if (handle == 0L) {
                source.close()
                throw YlBoundaryException(YlFailureKind.CONTAINER_UNSUPPORTED)
            }
            return try { YlFfmpegSession(handle, source) }
            catch (failure: Throwable) { YlFfmpegBridge.nativeClose(handle); source.close(); throw failure }
        }
    }
}

internal object YlFfmpegBridge {
    val available: Boolean = runCatching { System.loadLibrary("yl_player_ffmpeg") }.isSuccess

    external fun nativeOpen(source: YlNativeByteSource): Long
    external fun nativeStreamCount(handle: Long): Int
    external fun nativeDurationUs(handle: Long): Long
    external fun nativeIsSeekable(handle: Long): Boolean
    external fun nativeStreamInfo(handle: Long, index: Int): LongArray
    external fun nativeStreamLanguage(handle: Long, index: Int): String?
    external fun nativeStreamCodecConfig(handle: Long, index: Int): ByteArray
    external fun nativeConfigureHardwareVideo(handle: Long, streamIndex: Int): Boolean
    external fun nativeHardwareCodecConfig(handle: Long): ByteArray
    external fun nativeConfigureSoftwareVideoV2(handle: Long, streamIndex: Int, surface: Surface, limits: LongArray, budget: YlSoftwareDecodeBudget): Boolean
    external fun nativeSoftwareBudgetExhausted(handle: Long): Boolean
    external fun nativeConfigureSoftwareAudio(handle: Long, streamIndex: Int): Boolean
    external fun nativeReadPacket(handle: Long): LongArray?
    external fun nativeTakePacketData(handle: Long): ByteArray
    external fun nativeDecodeSoftwareVideo(
        handle: Long,
        data: ByteArray,
        presentationTimeUs: Long,
        decodeTimeUs: Long,
    ): LongArray?
    external fun nativeFinishSoftwareVideo(handle: Long): LongArray?
    external fun nativeRenderSoftwareVideoFrame(handle: Long): Boolean
    external fun nativeDecodeSoftwareAudio(handle: Long, data: ByteArray, presentationTimeUs: Long): LongArray?
    external fun nativeTakePcmData(handle: Long): ByteArray
    external fun nativeSeek(handle: Long, positionUs: Long): Boolean
    external fun nativeFlush(handle: Long)
    external fun nativeClose(handle: Long)
}

/** Copies JNI stream metadata; protocol validation is kept at the boundary. */
internal fun decodeStreamMetadata(index: Int, values: LongArray, language: String? = null,
    codecConfig: ByteArray = byteArrayOf()): YlNativeStreamInfo {
    // Exact length and version prevent an older/replaced JNI library from
    // treating arbitrary appended fields as an admission descriptor.
    if (values.size != 20 || values[11] != 2L || values[12] != 20L || index < 0 ||
        values[0] !in 0L until YlNativeStreamKind.entries.size.toLong() ||
        values[1] !in 0L until YlNativeCodec.entries.size.toLong() ||
        listOf(2, 3, 5, 6, 7, 8, 13, 14, 15, 16, 17, 18, 19).any { values[it] !in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong() }) {
        throw YlBoundaryException(YlFailureKind.DECODER_UNAVAILABLE)
    }
    return YlNativeStreamInfo(index,
        YlNativeStreamKind.entries.getOrElse(values[0].toInt()) { YlNativeStreamKind.UNKNOWN },
        YlNativeCodec.entries.getOrElse(values[1].toInt()) { YlNativeCodec.UNKNOWN },
        width = values[2].toInt(), height = values[3].toInt(), frameRate = if (values[13] > 0 && values[14] > 0) values[13].toDouble() / values[14] else 0.0,
        profile = values[5].toInt(), level = values[6].toInt(), sampleRate = values[7].toInt(),
        channelCount = values[8].toInt(), bitrate = values[9], durationUs = values[10],
        language = language, codecConfig = codecConfig,
        fpsNumerator = values[13].toInt(), fpsDenominator = values[14].toInt(),
        bitDepth = values[15].toInt(), chroma = values[16].toInt(), colorRange = values[17].toInt(),
        colorSpace = values[18].toInt(), colorTransfer = values[19].toInt())
}
