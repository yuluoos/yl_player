package dev.ylplayer.yl_player_android

/** Exact measured identity. Geometry is pixels, fps a positive rational; no family matching.
 * outputPixelFormat=1 identifies the native 8-bit limited BT.601 -> opaque GL RGBX contract. */
internal data class YlSoftwareDecodeKey(
    val model: String, val osBuild: String, val decoderBuild: String,
    val codec: Int, val profile: Int, val bitDepth: Int, val chroma: Int,
    val width: Int, val height: Int, val fpsNumerator: Int, val fpsDenominator: Int,
    val threads: Int, val outputPixelFormat: Int,
) {
    val valid: Boolean get() = model.isNotBlank() && osBuild.isNotBlank() && decoderBuild.isNotBlank() &&
        codec > 0 && profile >= 0 && bitDepth in listOf(8, 10, 12) && chroma in listOf(400, 420, 422, 444) &&
        width > 0 && height > 0 && width.toLong() * height <= Long.MAX_VALUE / 8 &&
        fpsNumerator > 0 && fpsDenominator > 0 && threads in 1..16 && outputPixelFormat > 0
}

/** Owned bytes/frame counts; process CPU, rolling window and call latency are nanoseconds. */
internal data class YlSoftwareDecodeLimits(
    val maxOwnedBytes: Long, val maxFrames: Int, val maxPacketBytes: Int,
    val windowNs: Long, val maxCpuNs: Long, val maxDecodeWallNs: Long,
) {
    val valid get() = maxOwnedBytes > 0 && maxFrames > 0 && maxPacketBytes > 0 &&
        maxPacketBytes <= maxOwnedBytes && windowNs > 0 && maxCpuNs > 0 && maxDecodeWallNs > 0
}

/** Production is deliberately empty until independent physical-device evidence qualifies. */
internal class YlSoftwareDecodeAdmission(private val entries: Map<YlSoftwareDecodeKey, YlSoftwareDecodeLimits> = emptyMap()) {
    fun limits(key: YlSoftwareDecodeKey): YlSoftwareDecodeLimits? =
        if (key.valid) entries[key]?.takeIf { it.valid } else null
}
