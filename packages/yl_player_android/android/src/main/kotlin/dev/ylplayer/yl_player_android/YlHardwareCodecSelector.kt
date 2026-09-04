package dev.ylplayer.yl_player_android

import androidx.annotation.OptIn
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector

internal data class YlCodecDescriptor(
    val name: String,
    val hardwareAccelerated: Boolean,
    val softwareOnly: Boolean,
)

internal data class YlVideoEnvelope(
    val maxWidth: Int?,
    val maxHeight: Int?,
    val maxFrameRate: Double?,
) {
    fun intersect(maxWidth: Int?, maxHeight: Int?): YlVideoEnvelope = copy(
        maxWidth = minimum(this.maxWidth, maxWidth),
        maxHeight = minimum(this.maxHeight, maxHeight),
    )
}

internal fun videoEnvelope(
    tier: YlDeviceTier,
    displayWidth: Int?,
    displayHeight: Int?,
    displayRate: Double?,
): YlVideoEnvelope = if (tier == YlDeviceTier.CONSTRAINED) {
    YlVideoEnvelope(
        maxWidth = minimum(1920, displayWidth),
        maxHeight = minimum(1080, displayHeight),
        maxFrameRate = minimum(30.0, displayRate),
    )
} else {
    YlVideoEnvelope(displayWidth, displayHeight, displayRate)
}

internal fun isHardwareCodecName(decoderName: String): Boolean {
    val name = decoderName.lowercase()
    if (
        name.startsWith("omx.google.") ||
        name.startsWith("c2.android.") ||
        name.contains("software") ||
        name.contains(".sw.") ||
        name.contains("ffmpeg")
    ) {
        return false
    }
    return name.startsWith("omx.") || name.startsWith("c2.")
}

internal fun shouldAcceptCodec(
    mimeType: String,
    name: String,
    hardwareAccelerated: Boolean,
    softwareOnly: Boolean,
): Boolean {
    if (!MimeTypes.isVideo(mimeType)) return true
    if (softwareOnly) return false
    return hardwareAccelerated || isHardwareCodecName(name)
}

internal fun hasExplicitHardwareDecoder(
    mimeType: String,
    candidates: List<YlCodecDescriptor>,
): Boolean = candidates.any {
    shouldAcceptCodec(mimeType, it.name, it.hardwareAccelerated, it.softwareOnly)
}

@OptIn(UnstableApi::class)
internal class YlHardwareCodecSelector(
    private val delegate: MediaCodecSelector = MediaCodecSelector.DEFAULT,
) : MediaCodecSelector {
    override fun getDecoderInfos(
        mimeType: String,
        requiresSecureDecoder: Boolean,
        requiresTunnelingDecoder: Boolean,
    ): List<MediaCodecInfo> = delegate.getDecoderInfos(
        mimeType,
        requiresSecureDecoder,
        requiresTunnelingDecoder,
    ).filter {
        shouldAcceptCodec(mimeType, it.name, it.hardwareAccelerated, it.softwareOnly)
    }
}

private fun minimum(first: Int?, second: Int?): Int? = when {
    first == null -> second
    second == null -> first
    else -> minOf(first, second)
}

private fun minimum(first: Double?, second: Double?): Double? = when {
    first == null -> second
    second == null -> first
    else -> minOf(first, second)
}
