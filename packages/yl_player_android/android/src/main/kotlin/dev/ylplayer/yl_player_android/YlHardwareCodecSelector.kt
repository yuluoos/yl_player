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
    val canonicalName: String = name,
    val supportedTypes: List<String> = emptyList(),
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
    return hardwareAccelerated
}

internal fun hasExplicitHardwareDecoder(
    mimeType: String,
    candidates: List<YlCodecDescriptor>,
    apiLevel: Int = android.os.Build.VERSION.SDK_INT,
): Boolean = !MimeTypes.isVideo(mimeType) || YlDecoderEvidenceProvider(apiLevel, candidates).hardwareAttainable

@OptIn(UnstableApi::class)
internal class YlHardwareCodecSelector(
    delegate: MediaCodecSelector = MediaCodecSelector.DEFAULT,
    evidence: YlDecoderEvidenceProvider = YlDecoderEvidenceProvider.collect(),
) : MediaCodecSelector {
    private val delegate = YlPolicyCodecSelector(dev.ylplayer.yl_player_android.pigeon.AndroidDecoderPolicy.HARDWARE_REQUIRED, delegate, evidence)
    override fun getDecoderInfos(
        mimeType: String,
        requiresSecureDecoder: Boolean,
        requiresTunnelingDecoder: Boolean,
    ): List<MediaCodecInfo> = delegate.getDecoderInfos(
        mimeType,
        requiresSecureDecoder,
        requiresTunnelingDecoder,
    )
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

/** v2 selection preference, deliberately separate from positive hardware evidence. */
@OptIn(UnstableApi::class)
internal class YlPolicyCodecSelector(
    private val policy: dev.ylplayer.yl_player_android.pigeon.AndroidDecoderPolicy,
    private val delegate: MediaCodecSelector = MediaCodecSelector.DEFAULT,
    private val evidence: YlDecoderEvidenceProvider = YlDecoderEvidenceProvider.collect(),
) : MediaCodecSelector {
    override fun getDecoderInfos(mimeType: String, requiresSecureDecoder: Boolean, requiresTunnelingDecoder: Boolean): List<MediaCodecInfo> {
        val codecs = delegate.getDecoderInfos(mimeType, requiresSecureDecoder, requiresTunnelingDecoder)
        if (!MimeTypes.isVideo(mimeType)) return codecs
        return when (policy) {
            dev.ylplayer.yl_player_android.pigeon.AndroidDecoderPolicy.SYSTEM_DEFAULT -> codecs
            dev.ylplayer.yl_player_android.pigeon.AndroidDecoderPolicy.HARDWARE_REQUIRED -> codecs.filter {
                evidence.mode(it.name) == dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode.HARDWARE
            }
            // Stable sorting preserves all software/system fallback candidates. Names rank only.
            dev.ylplayer.yl_player_android.pigeon.AndroidDecoderPolicy.HARDWARE_PREFERRED -> codecs.sortedBy {
                when {
                    evidence.mode(it.name) == dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode.HARDWARE -> 0
                    !it.softwareOnly && (it.hardwareAccelerated || isHardwareCodecName(it.name)) -> 1
                    else -> 2
                }
            }
        }
    }
}

/** API metadata is proof only when it matches the decoder actually initialized. */
internal class YlDecoderEvidenceProvider(val apiLevel: Int, private val records: List<YlCodecDescriptor>) {
    val hardwareAttainable get() = records.any { mode(it.name) == dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode.HARDWARE }
    val capability get() = if (apiLevel >= 29 && records.isNotEmpty()) dev.ylplayer.yl_player_android.pigeon.AndroidDecoderEvidence.HARDWARE_AND_SOFTWARE else dev.ylplayer.yl_player_android.pigeon.AndroidDecoderEvidence.NONE
    val hardwareCodecs get() = records.filter { mode(it.name) == dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode.HARDWARE }
        .flatMap { it.supportedTypes }.map(String::lowercase)
        .filter { Regex("video/[a-z0-9][a-z0-9._+-]{0,121}").matches(it) }.distinct().sorted()
    fun mode(initializedName: String?): dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode {
        val unknown = dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode.UNKNOWN
        if (apiLevel < 29 || initializedName == null) return unknown
        val canonical = records.filter { it.name == initializedName || it.canonicalName == initializedName }.map { it.canonicalName }.toSet()
        val matched = records.filter { it.canonicalName in canonical }
        if (matched.isEmpty()) return unknown
        return when {
            matched.all { it.softwareOnly && !it.hardwareAccelerated } -> dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode.SOFTWARE
            matched.all { it.hardwareAccelerated && !it.softwareOnly } -> dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode.HARDWARE
            else -> unknown
        }
    }
    fun satisfiesRequired(hasVideo: Boolean, initializedName: String?) = !hasVideo || mode(initializedName) == dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode.HARDWARE
    companion object {
        fun collect(api: Int = android.os.Build.VERSION.SDK_INT,
            codecInfos: () -> Array<android.media.MediaCodecInfo> = { android.media.MediaCodecList(android.media.MediaCodecList.ALL_CODECS).codecInfos },
        ): YlDecoderEvidenceProvider {
            val records = if (api >= 29) runCatching {
                codecInfos()
                    .filter { !it.isEncoder && it.supportedTypes.any { type -> type.lowercase().startsWith("video/") } }
                    .map { YlCodecDescriptor(it.name, it.isHardwareAccelerated, it.isSoftwareOnly, it.canonicalName, it.supportedTypes.toList()) }
            }.getOrDefault(emptyList()) else emptyList()
            return YlDecoderEvidenceProvider(api, records)
        }
    }
}


/** Worker-owned READY/evidence latch, reset for every decoder acquisition. The lease authority
 * owns its deadline; this gate never acquires a decoder or publishes a session. */
internal class YlInitializedDecoderGate(private val policy: dev.ylplayer.yl_player_android.pigeon.AndroidDecoderPolicy) {
    var ready = kotlinx.coroutines.CompletableDeferred<YlEngineSnapshot>()
        private set
    fun reset() { ready = kotlinx.coroutines.CompletableDeferred() }
    fun fail(kind: YlFailureKind) { ready.completeExceptionally(YlBoundaryException(kind)) }
    fun accept(snapshot: YlEngineSnapshot) {
        if (snapshot.status !in listOf(dev.ylplayer.yl_player_android.pigeon.AndroidPlaybackStatus.READY, dev.ylplayer.yl_player_android.pigeon.AndroidPlaybackStatus.PLAYING)) return
        if (policy == dev.ylplayer.yl_player_android.pigeon.AndroidDecoderPolicy.HARDWARE_REQUIRED) {
            if (snapshot.videoTracks.isEmpty() && snapshot.audioTracks.isNotEmpty()) { ready.complete(snapshot); return }
            if (snapshot.decoderIdentity == null) return
            if (snapshot.decoderMode != dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode.HARDWARE) { fail(YlFailureKind.DECODER_UNAVAILABLE); return }
        }
        ready.complete(snapshot)
    }
}
