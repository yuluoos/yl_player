package dev.ylplayer.yl_player_android

import java.net.URI

internal data class YlByteRange(val offset: Long, val length: Long)
internal data class YlHlsKey(val uri: String, val iv: ByteArray, val hasExplicitIv: Boolean)
internal data class YlHlsResource(val uri: String, val range: YlByteRange? = null)
internal data class YlHlsSegment(
    val uri: String,
    val sequence: Long,
    val durationUs: Long,
    val range: YlByteRange? = null,
    val key: YlHlsKey? = null,
    val discontinuity: Boolean = false,
)
internal data class YlHlsVariant(
    val uri: String,
    val bandwidth: Long,
    val width: Int,
    val height: Int,
    val frameRate: Double,
) {
    val fitsSoftwareEnvelope: Boolean
        get() = width in 1..1280 && height in 1..720 && (frameRate <= 0.0 || frameRate <= 30.0)
}
internal data class YlHlsPlaylist(
    val variants: List<YlHlsVariant> = emptyList(),
    val segments: List<YlHlsSegment> = emptyList(),
    val initialization: YlHlsResource? = null,
    val mediaSequence: Long = 0,
    val targetDurationUs: Long = 6_000_000,
    val isLive: Boolean = true,
)

internal object YlHlsPlaylistParser {
    fun parse(text: String, baseUri: String): YlHlsPlaylist {
        val lines = text.lineSequence().map(String::trim).filter(String::isNotEmpty).toList()
        if (lines.firstOrNull() != "#EXTM3U") throw YlBoundaryException(YlFailureKind.CONTAINER_UNSUPPORTED)
        var mediaSequence = 0L
        var targetDurationUs = 6_000_000L
        var endList = false
        var pendingVariant: Map<String, String>? = null
        var pendingDurationUs = 0L
        var pendingRange: YlByteRange? = null
        var nextRangeOffset = 0L
        var key: YlHlsKey? = null
        var initialization: YlHlsResource? = null
        var discontinuity = false
        val variants = mutableListOf<YlHlsVariant>()
        val segments = mutableListOf<YlHlsSegment>()

        lines.drop(1).forEach { line ->
            when {
                line.startsWith("#EXT-X-STREAM-INF:") -> pendingVariant = attributes(line.substringAfter(':'))
                line.startsWith("#EXT-X-MEDIA-SEQUENCE:") -> mediaSequence = line.substringAfter(':').toLongOrNull() ?: 0L
                line.startsWith("#EXT-X-TARGETDURATION:") -> targetDurationUs =
                    ((line.substringAfter(':').toDoubleOrNull() ?: 6.0) * 1_000_000).toLong()
                line.startsWith("#EXT-X-MAP:") -> {
                    val values = attributes(line.substringAfter(':'))
                    val uri = values["URI"] ?: throw YlBoundaryException(YlFailureKind.SOURCE_INVALID)
                    initialization = YlHlsResource(resolve(baseUri, uri), values["BYTERANGE"]?.let { parseRange(it, 0) })
                }
                line.startsWith("#EXT-X-KEY:") -> {
                    val values = attributes(line.substringAfter(':'))
                    when (values["METHOD"]?.uppercase()) {
                        "NONE" -> key = null
                        "AES-128" -> {
                            val uri = values["URI"] ?: throw YlBoundaryException(YlFailureKind.SOURCE_INVALID)
                            key = YlHlsKey(resolve(baseUri, uri), parseIv(values["IV"]), values["IV"] != null)
                        }
                        else -> throw YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED)
                    }
                }
                line.startsWith("#EXT-X-BYTERANGE:") -> {
                    val range = parseRange(line.substringAfter(':'), nextRangeOffset)
                    pendingRange = range
                    nextRangeOffset = range.offset + range.length
                }
                line.startsWith("#EXTINF:") -> pendingDurationUs =
                    ((line.substringAfter(':').substringBefore(',').toDoubleOrNull() ?: 0.0) * 1_000_000).toLong()
                line == "#EXT-X-DISCONTINUITY" -> discontinuity = true
                line == "#EXT-X-ENDLIST" -> endList = true
                line.startsWith('#') -> Unit
                pendingVariant != null -> {
                    val values = checkNotNull(pendingVariant)
                    val resolution = values["RESOLUTION"]?.split('x').orEmpty()
                    variants += YlHlsVariant(
                        resolve(baseUri, line),
                        values["BANDWIDTH"]?.toLongOrNull() ?: 0,
                        resolution.getOrNull(0)?.toIntOrNull() ?: 0,
                        resolution.getOrNull(1)?.toIntOrNull() ?: 0,
                        values["FRAME-RATE"]?.toDoubleOrNull() ?: 0.0,
                    )
                    pendingVariant = null
                }
                else -> {
                    val sequence = mediaSequence + segments.size
                    val resolvedKey = key?.let { configured ->
                        if (configured.hasExplicitIv) configured
                        else configured.copy(iv = sequenceIv(sequence))
                    }
                    segments += YlHlsSegment(resolve(baseUri, line), sequence, pendingDurationUs,
                        pendingRange, resolvedKey, discontinuity)
                    pendingDurationUs = 0
                    pendingRange = null
                    discontinuity = false
                }
            }
        }
        return YlHlsPlaylist(variants, segments, initialization, mediaSequence, targetDurationUs, !endList)
    }

    private fun resolve(base: String, child: String): String = URI(base).resolve(child).toString()

    private fun parseRange(value: String, defaultOffset: Long): YlByteRange {
        val parts = value.trim('"').split('@', limit = 2)
        return YlByteRange(parts.getOrNull(1)?.toLongOrNull() ?: defaultOffset,
            parts[0].toLongOrNull() ?: throw YlBoundaryException(YlFailureKind.SOURCE_INVALID))
    }

    private fun parseIv(value: String?): ByteArray {
        if (value == null) return ByteArray(16)
        val hex = value.removePrefix("0x").removePrefix("0X").padStart(32, '0')
        if (hex.length != 32) throw YlBoundaryException(YlFailureKind.SOURCE_INVALID)
        return ByteArray(16) { index -> hex.substring(index * 2, index * 2 + 2).toInt(16).toByte() }
    }

    private fun sequenceIv(sequence: Long): ByteArray = ByteArray(16).also { bytes ->
        for (index in 0 until 8) bytes[15 - index] = (sequence ushr (index * 8)).toByte()
    }

    private fun attributes(value: String): Map<String, String> {
        val result = linkedMapOf<String, String>()
        var start = 0
        var quoted = false
        fun accept(end: Int) {
            val entry = value.substring(start, end)
            val separator = entry.indexOf('=')
            if (separator > 0) result[entry.substring(0, separator).trim().uppercase()] =
                entry.substring(separator + 1).trim().trim('"')
        }
        value.forEachIndexed { index, char ->
            if (char == '"') quoted = !quoted
            if (char == ',' && !quoted) { accept(index); start = index + 1 }
        }
        accept(value.length)
        return result
    }
}
