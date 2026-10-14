package dev.ylplayer.yl_player_android

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.TrackGroup
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import dev.ylplayer.yl_player_android.pigeon.AndroidVideoSelectionMessage

/** Native quality identity deliberately excludes manifest IDs and ordering. No mutable Format data
 * crosses the application/playback thread boundary or is retained in a restore point. */
internal data class YlVideoQualityIdentity(
    val mime: String?, val codecs: String?, val width: Int, val height: Int,
    val averageBitrate: Int, val peakBitrate: Int, val bitrate: Int, val frameRate: Float,
    val roleFlags: Int, val selectionFlags: Int, val language: String?,
    val colorSpace: Int?, val colorRange: Int?, val colorTransfer: Int?, val lumaBitdepth: Int?, val chromaBitdepth: Int?,
    val rotation: Int, val pixelRatio: Float,
)
internal data class YlFixedVideoIntent(
    val quality: YlVideoQualityIdentity,
    val constraints: AndroidQualityConstraint,
    val envelope: YlVideoEnvelope,
)
internal data class YlFixedVideoState(
    val quality: YlVideoQualityIdentity? = null,
    val fixedTrackId: String? = null,
    val reason: String = "initial",
) {
    fun message() = AndroidVideoSelectionMessage(fixedTrackId, reason)
}
internal data class YlVideoCandidate(val id: String, val group: TrackGroup, val index: Int, val supported: Boolean) {
    val format: Format get() = group.getFormat(index)
}

internal object YlVideoSelectionPolicy {
    fun candidates(tracks: Tracks): List<YlVideoCandidate> = tracks.groups.flatMapIndexed { groupIndex, group ->
        if (group.type != C.TRACK_TYPE_VIDEO) emptyList() else (0 until group.length).map { index ->
            val format = group.getTrackFormat(index)
            YlVideoCandidate(format.id?.takeIf(String::isNotBlank) ?: "video-$groupIndex-$index", group.mediaTrackGroup, index, group.isTrackSupported(index))
        }
    }

    fun identity(format: Format): YlVideoQualityIdentity {
        requireCompatible(format)
        return uncheckedIdentity(format)
    }

    private fun uncheckedIdentity(format: Format): YlVideoQualityIdentity {
        return YlVideoQualityIdentity(format.sampleMimeType, format.codecs?.lowercase(), format.width, format.height,
            format.averageBitrate, format.peakBitrate, format.bitrate, format.frameRate,
            format.roleFlags, format.selectionFlags, format.language, format.colorInfo?.colorSpace,
            format.colorInfo?.colorRange, format.colorInfo?.colorTransfer, format.colorInfo?.lumaBitdepth, format.colorInfo?.chromaBitdepth, format.rotationDegrees, format.pixelWidthHeightRatio)
    }

    private fun requireCompatible(format: Format) {
        val codec = format.codecs?.lowercase()
        val profile = codec?.takeIf { Regex("avc[13]\\.[0-9a-f]{6}").matches(it) }?.substring(5, 7)
        // The initial fixed-quality path accepts 8-bit SDR AVC and HEVC Main. Codec/profile
        // validation is independent of device support, which must also be FORMAT_HANDLED.
        // Main10, Dolby and unknown profiles are not evidence of an SDR rendition.
        val avc = format.sampleMimeType == "video/avc" && profile in setOf("42", "4d", "58", "64")
        val hevc = format.sampleMimeType == "video/hevc" && codec != null &&
            Regex("(?:hvc1|hev1)\\.1\\.[0-9a-f]{1,8}\\.[lh](?:30|60|63|90|93|120|123|150|153|156|180|183|186)(?:\\.[0-9a-f]{2}){0,6}").matches(codec)
        if ((!avc && !hevc) || format.colorInfo?.hdrStaticInfo != null ||
            format.colorInfo?.lumaBitdepth?.let { it != Format.NO_VALUE && it != 8 } == true ||
            format.colorInfo?.chromaBitdepth?.let { it != Format.NO_VALUE && it != 8 } == true ||
            format.colorInfo?.colorTransfer?.let { it != Format.NO_VALUE && it != C.COLOR_TRANSFER_SDR } == true) unsupported()
    }

    fun validate(quality: YlVideoQualityIdentity, caps: AndroidQualityConstraint, envelope: YlVideoEnvelope) {
        fun fits(value: Int, limit: Int?) = limit == null || value > 0 && value <= limit
        if (!fits(quality.width, caps.maxWidth) || !fits(quality.width, envelope.maxWidth) ||
            !fits(quality.height, caps.maxHeight) || !fits(quality.height, envelope.maxHeight) ||
            !fits(quality.bitrate, caps.maxBitrate) ||
            envelope.maxFrameRate?.let { quality.frameRate <= 0 || !quality.frameRate.isFinite() || quality.frameRate > it } == true) unsupported()
    }

    fun select(tracks: Tracks, id: String?, caps: AndroidQualityConstraint, envelope: YlVideoEnvelope): YlFixedVideoState {
        if (id == null) return YlFixedVideoState(reason = "user")
        val catalog = candidates(tracks)
        val chosen = catalog.filter { it.id == id }.singleOrNull()
            ?: throw YlBoundaryException(YlFailureKind.SOURCE_MISSING)
        val quality = identity(chosen.format)
        resolve(quality, catalog, caps, envelope) ?: unsupported()
        if (!chosen.supported) unsupported()
        return YlFixedVideoState(quality, id, "user")
    }

    /** Used both at playback-thread selection time (including lookahead) and current publication.
     * Absence alone permits PD-01. Ambiguous, incompatible, or newly ineligible quality fails. */
    fun resolve(quality: YlVideoQualityIdentity, catalog: List<YlVideoCandidate>, caps: AndroidQualityConstraint,
        envelope: YlVideoEnvelope): YlVideoCandidate? {
        val matches = catalog.filter { uncheckedIdentity(it.format) == quality }
        if (matches.size > 1) unsupported()
        val candidate = matches.singleOrNull() ?: return null
        requireCompatible(candidate.format)
        if (!candidate.supported || catalog.count { it.id == candidate.id } != 1) unsupported()
        validate(quality, caps, envelope)
        return candidate
    }

    fun reconcile(tracks: Tracks, previous: YlFixedVideoState, caps: AndroidQualityConstraint, envelope: YlVideoEnvelope): YlFixedVideoState {
        val quality = previous.quality ?: return previous
        if (tracks.groups.isEmpty()) return previous // stop/reprepare and buffering are not absence evidence
        val candidate = resolve(quality, candidates(tracks), caps, envelope)
            ?: return YlFixedVideoState(reason = "trackUnavailable")
        return previous.copy(fixedTrackId = candidate.id)
    }

    fun parameters(parameters: DefaultTrackSelector.Parameters, tracks: Tracks, selection: YlFixedVideoState): DefaultTrackSelector.Parameters {
        val builder = parameters.buildUpon().clearOverridesOfType(C.TRACK_TYPE_VIDEO)
        selection.fixedTrackId?.let { id ->
            val candidate = candidates(tracks).singleOrNull { it.id == id } ?: return parameters
            builder.addOverride(TrackSelectionOverride(candidate.group, candidate.index))
        }
        return builder.build()
    }
    private fun unsupported(): Nothing = throw YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED)
}
