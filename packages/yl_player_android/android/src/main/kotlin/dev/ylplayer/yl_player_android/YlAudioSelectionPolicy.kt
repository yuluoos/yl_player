package dev.ylplayer.yl_player_android

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.TrackGroup
import androidx.media3.common.Tracks
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.Locale

/** One content choice per Media3 group. Renditions never become competing audio programs. */
internal data class YlAudioCandidate(val id: String, val group: TrackGroup, val supportedIndices: List<Int>) {
    // Explicit selection is fixed to one supported rendition, as the previous index command was.
    // Bitrate ranks renditions within this content; it never defines content identity.
    fun selectedIndex(): Int = supportedIndices.maxWithOrNull(compareBy<Int> { group.getFormat(it).bitrate }
        .thenBy { group.getFormat(it).id.orEmpty() }) ?: throw YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED)
}

/** Immutable across application/playback threads and captured by rollback before observed ACKs. */
internal data class YlAudioIntent(val id: String, val dash: Boolean)

internal object YlAudioSelectionPolicy {
    private const val MAX_GROUPS = 128
    private const val MAX_FORMATS = 4096
    private const val MAX_TEXT = 1024

    fun candidates(tracks: Tracks, dash: Boolean): List<YlAudioCandidate> = candidates(
        tracks.groups.filter { it.type == C.TRACK_TYPE_AUDIO }.map { group ->
            group.mediaTrackGroup to (0 until group.length).filter { group.isTrackSupported(it) }
        }, dash)

    fun candidates(groups: List<Pair<TrackGroup, List<Int>>>, dash: Boolean): List<YlAudioCandidate> {
        if (groups.size > MAX_GROUPS || groups.sumOf { it.first.length.toLong() } > MAX_FORMATS) exhausted()
        val result = groups.map { (group, supported) -> YlAudioCandidate(identity(group, dash), group, supported.toList()) }
        if (result.map { it.id }.toSet().size != result.size) throw YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED)
        return result
    }

    fun resolve(candidates: List<YlAudioCandidate>, id: String): YlAudioCandidate =
        candidates.singleOrNull { it.id == id }?.also { it.selectedIndex() }
            ?: throw YlBoundaryException(YlFailureKind.TRACK_NOT_FOUND)

    private fun text(value: String?): String = value.orEmpty().also { if (it.length > MAX_TEXT) exhausted() }
    private fun normalized(value: String?): String = text(value).lowercase(Locale.ROOT)
    private fun digest(parts: List<String>): String {
        val hash = MessageDigest.getInstance("SHA-256")
        parts.forEach {
            val bytes = it.toByteArray(Charsets.UTF_8)
            hash.update(ByteBuffer.allocate(4).putInt(bytes.size).array()); hash.update(bytes)
        }
        return hash.digest().joinToString("") { "%02x".format(it) }
    }
    private fun identity(group: TrackGroup, dash: Boolean): String {
        // Media3 1.11 DASH group IDs are declared numeric AdaptationSet IDs or
        // "unset:<position>". Never promote its generated positional fallback to content identity.
        val content = if (dash) text(group.id).toLongOrNull()?.takeUnless { it == -1L }?.toString().orEmpty()
            else digest((0 until group.length).map { text(group.getFormat(it).id) }.distinct().sorted())
        val signatures = (0 until group.length).map { index ->
            val f = group.getFormat(index)
            digest(listOf(normalized(f.language), f.roleFlags.toString(), normalized(f.sampleMimeType),
                normalized(f.codecs), f.sampleRate.toString(), f.channelCount.toString(), f.pcmEncoding.toString()))
        }.distinct().sorted()
        return "audio-" + digest(listOf(if (dash) "dash" else "media", content) + signatures)
    }
    fun label(format: Format): String? {
        if (!format.label.isNullOrBlank()) return format.label
        val role = when {
            format.roleFlags and C.ROLE_FLAG_COMMENTARY != 0 -> "commentary"
            format.roleFlags and C.ROLE_FLAG_DESCRIBES_VIDEO != 0 -> "description"
            format.roleFlags and C.ROLE_FLAG_MAIN != 0 -> "main"
            else -> null
        }
        return listOfNotNull(format.language, role).joinToString(" · ").ifEmpty { null }
    }
    private fun exhausted(): Nothing = throw YlBoundaryException(YlFailureKind.RESOURCE_EXHAUSTED)
}
