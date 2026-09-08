package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import java.net.URI
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** Decoder-free decision shared by Assess and Load. Compatibility is route/policy support,
 * not an assertion that remote media exists or that a codec has initialized. */
internal class YlSourceAssessment(private val evidence: YlDecoderEvidenceProvider) {
    fun assess(source: AndroidSourceMessage, options: AndroidLoadOptionsMessage, decoder: AndroidDecoderPolicy, hasVideo: Boolean? = null, initializedName: String? = null): AndroidAssessmentReply {
        fun reject(kind: YlFailureKind) = AndroidAssessmentReply(AndroidAssessmentOutcome.INCOMPATIBLE, AndroidEngine.MEDIA3,
            emptyList(), emptyList(), YlFailureMapper().toMessage(YlBoundaryException(kind)))
        try { YlBoundaryValidation.load(source, options) }
        catch (error: YlBoundaryException) { return reject(error.kind) }
        val uri = runCatching { URI(source.locator) }.getOrNull()
        val valid = when (source.kind) {
            AndroidSourceKind.NETWORK -> uri?.scheme?.lowercase() in listOf("http", "https") && !uri?.host.isNullOrBlank() && uri?.userInfo == null && source.locator.toHttpUrlOrNull() != null
            AndroidSourceKind.FILE -> (uri?.scheme == "file" && !uri.path.isNullOrBlank()) || (uri?.scheme == null && source.locator.startsWith('/'))
            AndroidSourceKind.CONTENT -> uri?.scheme == "content" && !uri.authority.isNullOrBlank() && !uri.path.isNullOrBlank()
        }
        if (!valid || source.locator.isBlank() || (options.startPositionMs ?: 0) < 0) return reject(YlFailureKind.SOURCE_INVALID)
        if (runCatching {
                okhttp3.Headers.Builder().apply {
                    source.request?.headers?.forEach { (key, value) -> add(key, value) }
                    source.request?.credentials?.forEach { (key, value) -> add(key, value) }
                }.build()
            }.isFailure) return reject(YlFailureKind.SOURCE_INVALID)
        if (options.bufferStrategy.kind == AndroidBufferKind.BOUNDED) return reject(YlFailureKind.POLICY_UNSUPPORTED)
        val network = source.networkPolicy
        if (decoder == AndroidDecoderPolicy.HARDWARE_REQUIRED && hasVideo == true && !evidence.hardwareAttainable) return reject(YlFailureKind.DECODER_UNAVAILABLE)
        if (decoder == AndroidDecoderPolicy.HARDWARE_REQUIRED && hasVideo == true && initializedName != null &&
            !evidence.satisfiesRequired(true, initializedName)) return reject(YlFailureKind.DECODER_UNAVAILABLE)
        val known = hasVideo != null || source.format != AndroidMediaFormat.AUTOMATIC || uri?.path?.lowercase()?.substringAfterLast('.') in
            listOf("mp4", "m4v", "mov", "mkv", "webm", "m3u8", "ts", "mpg", "mpeg", "flv", "avi", "mp3", "aac", "wav", "flac", "ogg", "m4a")
        val strictPending = decoder == AndroidDecoderPolicy.HARDWARE_REQUIRED && (hasVideo == null || !evidence.satisfiesRequired(hasVideo, initializedName))
        val inspect = !known || strictPending
        val limitations = buildList {
            if (!known) add("source.requiresInspection")
            if (decoder == AndroidDecoderPolicy.HARDWARE_PREFERRED || strictPending) add("decoder.modeUnknown")
            if (strictPending && !evidence.hardwareAttainable) add("codec.requiresInspection")
        }
        val satisfied = buildList {
            if (source.kind == AndroidSourceKind.NETWORK) add(if (network?.kind == AndroidNetworkPolicyKind.MANAGED) "network.managed" else "network.platformDefault")
            add(when (options.bufferStrategy.kind) {
                AndroidBufferKind.LOW_LATENCY -> "buffer.lowLatency"
                AndroidBufferKind.SMOOTH_PLAYBACK -> "buffer.smoothPlayback"
                else -> "buffer.automatic"
            })
            when (decoder) {
                AndroidDecoderPolicy.SYSTEM_DEFAULT -> add("decoder.systemDefault")
                AndroidDecoderPolicy.HARDWARE_PREFERRED -> add("decoder.hardwarePreferred")
                AndroidDecoderPolicy.HARDWARE_REQUIRED -> if (!strictPending) add("decoder.hardwareRequired")
            }
        }
        return AndroidAssessmentReply(if (inspect) AndroidAssessmentOutcome.REQUIRES_INSPECTION else AndroidAssessmentOutcome.COMPATIBLE,
            AndroidEngine.MEDIA3, satisfied, limitations)
    }
}
