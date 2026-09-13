package dev.ylplayer.yl_player_android

import android.view.Surface

internal class YlFfmpegSession private constructor(
    private var handle: Long,
    private val source: YlNativeByteSource,
) : AutoCloseable {
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
        check(values.size >= 11)
        return YlNativeStreamInfo(
            index,
            YlNativeStreamKind.entries.getOrElse(values[0].toInt()) { YlNativeStreamKind.UNKNOWN },
            YlNativeCodec.entries.getOrElse(values[1].toInt()) { YlNativeCodec.UNKNOWN },
            width = values[2].toInt(),
            height = values[3].toInt(),
            frameRate = values[4] / 1000.0,
            profile = values[5].toInt(),
            level = values[6].toInt(),
            sampleRate = values[7].toInt(),
            channelCount = values[8].toInt(),
            bitrate = values[9],
            durationUs = values[10],
            language = YlFfmpegBridge.nativeStreamLanguage(handle, index),
            codecConfig = YlFfmpegBridge.nativeStreamCodecConfig(handle, index),
        )
    }

    fun configureHardwareVideo(streamIndex: Int): Boolean =
        YlFfmpegBridge.nativeConfigureHardwareVideo(handle, streamIndex)

    fun hardwareCodecConfig(): ByteArray = YlFfmpegBridge.nativeHardwareCodecConfig(handle)

    fun configureSoftwareVideo(streamIndex: Int, surface: Surface): Boolean =
        YlFfmpegBridge.nativeConfigureSoftwareVideo(handle, streamIndex, surface)

    fun configureSoftwareAudio(streamIndex: Int): Boolean =
        YlFfmpegBridge.nativeConfigureSoftwareAudio(handle, streamIndex)

    fun readPacket(): YlNativePacket? {
        val metadata = YlFfmpegBridge.nativeReadPacket(handle) ?: return null
        if (metadata[0] < 0) throw YlBoundaryException(YlFailureKind.NETWORK_FAILED)
        val bytes = YlFfmpegBridge.nativeTakePacketData(handle)
        return YlNativePacket(metadata[0].toInt(), bytes, metadata[1], metadata[2], metadata[3], metadata[4] != 0L)
    }

    fun decodeSoftwareVideo(packet: YlNativePacket): Int =
        YlFfmpegBridge.nativeDecodeSoftwareVideo(handle, packet.data, packet.presentationTimeUs)

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
    }

    companion object {
        fun open(source: YlNativeByteSource): YlFfmpegSession {
            if (!YlFfmpegBridge.available) throw YlBoundaryException(YlFailureKind.PLATFORM_UNAVAILABLE)
            val handle = YlFfmpegBridge.nativeOpen(source)
            if (handle == 0L) {
                source.close()
                throw YlBoundaryException(YlFailureKind.CONTAINER_UNSUPPORTED)
            }
            return YlFfmpegSession(handle, source)
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
    external fun nativeConfigureSoftwareVideo(handle: Long, streamIndex: Int, surface: Surface): Boolean
    external fun nativeConfigureSoftwareAudio(handle: Long, streamIndex: Int): Boolean
    external fun nativeReadPacket(handle: Long): LongArray?
    external fun nativeTakePacketData(handle: Long): ByteArray
    external fun nativeDecodeSoftwareVideo(handle: Long, data: ByteArray, presentationTimeUs: Long): Int
    external fun nativeDecodeSoftwareAudio(handle: Long, data: ByteArray, presentationTimeUs: Long): LongArray?
    external fun nativeTakePcmData(handle: Long): ByteArray
    external fun nativeSeek(handle: Long, positionUs: Long): Boolean
    external fun nativeFlush(handle: Long)
    external fun nativeClose(handle: Long)
}
