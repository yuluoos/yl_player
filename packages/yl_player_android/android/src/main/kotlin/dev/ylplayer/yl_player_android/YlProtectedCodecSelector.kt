package dev.ylplayer.yl_player_android

import androidx.annotation.OptIn
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode

/** For the future protected renderer only. Media3 can retry a secure query with
 * requiresSecureDecoder=false when its first result is empty. This selector
 * never permits that downgrade, including for encrypted audio. Hardware video
 * metadata must also be positive; initialized decoder evidence is still a
 * separate admission gate in the candidate transaction.
 */
@OptIn(UnstableApi::class)
internal class YlProtectedCodecSelector(
    private val delegate: MediaCodecSelector = MediaCodecSelector.DEFAULT,
    private val evidence: YlDecoderEvidenceProvider = YlDecoderEvidenceProvider.collect(),
) : MediaCodecSelector {
    private val selected = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    fun provesInitialized(name: String) = name in selected && evidence.mode(name) == AndroidDecoderMode.HARDWARE
    override fun getDecoderInfos(mimeType: String, requiresSecureDecoder: Boolean,
        requiresTunnelingDecoder: Boolean): List<MediaCodecInfo> {
        val allowed = delegate.getDecoderInfos(mimeType, true, requiresTunnelingDecoder).filter {
            it.secure && (!MimeTypes.isVideo(mimeType) || evidence.mode(it.name) == AndroidDecoderMode.HARDWARE)
        }
        if (allowed.isEmpty()) throw YlBoundaryException(YlFailureKind.DRM_PROTECTION_INSUFFICIENT)
        if (MimeTypes.isVideo(mimeType)) selected.addAll(allowed.map { it.name })
        return allowed
    }
}
