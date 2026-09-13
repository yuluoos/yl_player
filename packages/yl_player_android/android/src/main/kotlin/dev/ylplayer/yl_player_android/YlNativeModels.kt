package dev.ylplayer.yl_player_android

internal enum class YlNativeStreamKind { UNKNOWN, VIDEO, AUDIO }

internal enum class YlNativeCodec(val mimeType: String?) {
    UNKNOWN(null),
    H264("video/avc"),
    HEVC("video/hevc"),
    AAC("audio/mp4a-latm"),
    MP3("audio/mpeg"),
    AC3("audio/ac3"),
    EAC3("audio/eac3"),
    DTS("audio/vnd.dts"),
    FLAC("audio/flac"),
    OPUS("audio/opus"),
    VORBIS("audio/vorbis"),
    VP9("video/x-vnd.on2.vp9"),
}

internal data class YlNativeStreamInfo(
    val index: Int,
    val kind: YlNativeStreamKind,
    val codec: YlNativeCodec,
    val width: Int = 0,
    val height: Int = 0,
    val frameRate: Double = 0.0,
    val profile: Int = 0,
    val level: Int = 0,
    val sampleRate: Int = 0,
    val channelCount: Int = 0,
    val bitrate: Long = 0,
    val language: String? = null,
    val durationUs: Long = -1,
    val codecConfig: ByteArray = byteArrayOf(),
)

internal data class YlNativeMediaInfo(
    val durationUs: Long,
    val seekable: Boolean,
    val streams: List<YlNativeStreamInfo>,
)

internal data class YlNativePacket(
    val streamIndex: Int,
    val data: ByteArray,
    val presentationTimeUs: Long,
    val decodeTimeUs: Long,
    val durationUs: Long,
    val keyFrame: Boolean,
)

internal data class YlNativePcmChunk(
    val data: ByteArray,
    val sampleRate: Int,
    val channelCount: Int,
    val presentationTimeUs: Long,
)

internal enum class YlNativeVideoPath { HARDWARE, SOFTWARE, UNSUPPORTED }

internal enum class YlVideoPacingAction { WAIT, PRESENT }

internal object YlVideoPacingPolicy {
    private const val EARLY_TOLERANCE_US = 12_000L

    fun action(presentationTimeUs: Long, clockUs: Long): YlVideoPacingAction =
        if (presentationTimeUs != Long.MIN_VALUE && presentationTimeUs - clockUs > EARLY_TOLERANCE_US) {
            YlVideoPacingAction.WAIT
        } else {
            YlVideoPacingAction.PRESENT
        }
}

internal class YlSoftwareVideoFrames(
    private val decodeFrameTimestamps: (YlNativePacket) -> LongArray,
    private val renderNextFrame: (Long) -> Boolean,
    private val finishDecoding: () -> LongArray = { longArrayOf() },
) {
    private val pendingPresentationTimesUs = ArrayDeque<Long>()

    val bufferedCount: Int get() = pendingPresentationTimesUs.size
    val nextPresentationTimeUs: Long? get() = pendingPresentationTimesUs.firstOrNull()

    fun decode(packet: YlNativePacket): Int = enqueue(decodeFrameTimestamps(packet))

    fun finish(): Int = enqueue(finishDecoding())

    fun renderDue(clockUs: Long): Int {
        var rendered = 0
        while (pendingPresentationTimesUs.isNotEmpty() &&
            YlVideoPacingPolicy.action(pendingPresentationTimesUs.first(), clockUs) == YlVideoPacingAction.PRESENT
        ) {
            renderNext()
            rendered++
        }
        return rendered
    }

    fun renderNext() {
        val presentationTimeUs = pendingPresentationTimesUs.removeFirst()
        if (!renderNextFrame(presentationTimeUs)) {
            throw YlBoundaryException(YlFailureKind.PLATFORM_FAILURE)
        }
    }

    fun clear() = pendingPresentationTimesUs.clear()

    private fun enqueue(timestamps: LongArray): Int {
        timestamps.forEach(pendingPresentationTimesUs::addLast)
        return timestamps.size
    }
}

internal class YlPendingPcmWrite {
    private var data: ByteArray? = null
    private var offset = 0

    val hasData: Boolean get() = data != null

    fun enqueue(bytes: ByteArray) {
        check(data == null) { "Previous PCM data has not been written" }
        if (bytes.isNotEmpty()) data = bytes
    }

    fun writeAvailable(writer: (ByteArray, Int, Int) -> Int): Int {
        val current = data ?: return 0
        val remaining = current.size - offset
        val written = writer(current, offset, remaining)
        require(written in 0..remaining) { "PCM writer returned an invalid byte count" }
        offset += written
        if (offset == current.size) clear()
        return written
    }

    fun clear() {
        data = null
        offset = 0
    }
}

internal object YlAudioClockEstimator {
    fun positionUs(
        firstPresentationUs: Long,
        sampleRate: Int,
        hardwareFramePosition: Long,
        hardwareTimestampNs: Long,
        nowNs: Long,
        speed: Double,
        writtenFrames: Long,
    ): Long {
        if (sampleRate <= 0) return firstPresentationUs
        val hardwarePositionUs = firstPresentationUs +
            hardwareFramePosition * 1_000_000L / sampleRate
        val elapsedUs = ((nowNs - hardwareTimestampNs).coerceAtLeast(0) / 1000 * speed).toLong()
        val lastWrittenPositionUs = firstPresentationUs + writtenFrames * 1_000_000L / sampleRate
        return (hardwarePositionUs + elapsedUs).coerceIn(firstPresentationUs, lastWrittenPositionUs)
    }
}

internal object YlAudioPlaybackRatePolicy {
    fun shouldApply(speed: Float, parametersWereApplied: Boolean): Boolean =
        parametersWereApplied || speed != 1f
}

/** Keeps software decoding deliberately bounded; higher HLS variants are selected down first. */
internal class YlNativePlaybackPlanner(
    private val supportsHardwareConfiguration: (YlNativeStreamInfo) -> Boolean,
) {
    fun chooseVideoPath(stream: YlNativeStreamInfo): YlNativeVideoPath {
        if (stream.codec !in setOf(YlNativeCodec.H264, YlNativeCodec.HEVC)) {
            return YlNativeVideoPath.UNSUPPORTED
        }
        if (supportsHardwareConfiguration(stream)) return YlNativeVideoPath.HARDWARE
        val inEnvelope = stream.width in 1..1920 && stream.height in 1..1080 &&
            (stream.frameRate <= 0.0 || stream.frameRate <= 30.0)
        return if (inEnvelope) YlNativeVideoPath.SOFTWARE else YlNativeVideoPath.UNSUPPORTED
    }
}
