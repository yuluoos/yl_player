package dev.ylplayer.yl_player_android

import androidx.media3.common.MimeTypes
import androidx.media3.common.Tracks

internal object YlAndroidChannel {
    private const val protocolVersion = 1

    val supportedFormats = listOf(
        "automatic",
        "hls",
        "httpFlv",
        "mp4",
        "mov",
        "matroska",
        "webm",
        "mpegTs",
        "mpegPs",
        "flv",
        "avi",
    )

    fun mimeType(formatHint: String?): String? = when (formatHint) {
        "hls" -> MimeTypes.APPLICATION_M3U8
        "httpFlv", "flv" -> MimeTypes.VIDEO_FLV
        "mp4" -> MimeTypes.VIDEO_MP4
        "mov" -> "video/quicktime"
        "matroska" -> MimeTypes.VIDEO_MATROSKA
        "webm" -> MimeTypes.VIDEO_WEBM
        "mpegTs" -> MimeTypes.VIDEO_MP2T
        "mpegPs" -> MimeTypes.VIDEO_MPEG2
        "avi" -> "video/x-msvideo"
        else -> null
    }

    fun capabilities(
        hardwareVideoCodecs: List<String>,
        maxWidth: Int?,
        maxHeight: Int?,
    ): Map<String, Any?> = mapOf(
        "hardwareVideoCodecs" to hardwareVideoCodecs
            .map(String::lowercase)
            .filter { it.startsWith("video/") }
            .distinct()
            .sorted(),
        "supportedFormats" to supportedFormats,
        "maxConcurrentVideoDecoders" to 1,
        "maxWidth" to maxWidth,
        "maxHeight" to maxHeight,
    )

    fun fullStateEnvelope(
        playerId: Long,
        generation: Long,
        state: Map<String, Any?>,
    ): Map<String, Any?> = mapOf(
        "playerId" to playerId,
        "protocolVersion" to protocolVersion,
        "generation" to generation,
        "type" to "state",
        "state" to state,
    )

    fun stateDeltaEnvelope(
        playerId: Long,
        generation: Long,
        delta: Map<String, Any?>,
    ): Map<String, Any?> = mapOf(
        "playerId" to playerId,
        "protocolVersion" to protocolVersion,
        "generation" to generation,
        "type" to "stateDelta",
        "delta" to delta,
    )
}

internal data class AudioSelection(val group: Tracks.Group, val trackIndex: Int)

internal data class AndroidQualityConstraint(
    val maxWidth: Int? = null,
    val maxHeight: Int? = null,
    val maxBitrate: Int? = null,
)

internal data class PlayerConfiguration(
    val bufferMode: String,
    val decoderPolicy: String,
    val minBufferMs: Int?,
    val maxBufferMs: Int?,
    val maxBufferBytes: Int?,
    val positionEventIntervalMs: Long,
    val network: NetworkConfiguration,
) {
    fun bufferRequest() = YlBufferRequest(
        mode = bufferMode,
        minBufferMs = minBufferMs,
        maxBufferMs = maxBufferMs,
        maxBufferBytes = maxBufferBytes,
    )

    companion object {
        fun from(map: Map<String, Any?>): PlayerConfiguration {
            val network = map["network"].asStringMap()
            return PlayerConfiguration(
                bufferMode = map["bufferMode"] as? String ?: "automatic",
                decoderPolicy = map["decoderPolicy"] as? String ?: "hardwareOnly",
                minBufferMs = (map["minBufferMs"] as? Number)?.toInt(),
                maxBufferMs = (map["maxBufferMs"] as? Number)?.toInt(),
                maxBufferBytes = (map["maxBufferBytes"] as? Number)?.toInt(),
                positionEventIntervalMs = ((map["positionEventIntervalMs"] as? Number)?.toLong() ?: 250L)
                    .coerceIn(100L, 2_000L),
                network = NetworkConfiguration(
                    connectTimeoutMs = (network["connectTimeoutMs"] as? Number)?.toInt() ?: 10_000,
                    readTimeoutMs = (network["readTimeoutMs"] as? Number)?.toInt() ?: 15_000,
                    maxRetries = (network["maxRetries"] as? Number)?.toInt() ?: 3,
                    baseRetryDelayMs = (network["baseRetryDelayMs"] as? Number)?.toLong() ?: 500L,
                    maxRetryDelayMs = (network["maxRetryDelayMs"] as? Number)?.toLong() ?: 8_000L,
                    maxRedirects = (network["maxRedirects"] as? Number)?.toInt() ?: 5,
                ),
            )
        }
    }
}

internal fun errorMap(
    category: String,
    code: String,
    message: String,
    diagnostic: String? = null,
): Map<String, Any?> = mapOf(
    "category" to category,
    "code" to code,
    "message" to message,
    "platformDiagnostic" to diagnostic,
)

internal fun Any?.asStringMap(): Map<String, Any?> {
    val source = this as? Map<*, *> ?: return emptyMap()
    return source.entries.associate { it.key.toString() to it.value }
}
