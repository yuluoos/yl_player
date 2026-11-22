package dev.ylplayer.yl_player_android

import android.os.Build
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.exoplayer.dash.manifest.DashManifest
import java.util.IdentityHashMap

/** The source and the renderer use the playback looper. Match the parser-owned
 * metadata by identity because representation IDs can repeat across Periods. */
internal class YlDashDecoderSizing {
    private val nextByCoverage = IdentityHashMap<YlDashVideoCoverage, Format>()
    private fun coverage(format: Format) = format.metadata?.let { metadata ->
        (0 until metadata.length()).firstNotNullOfOrNull { metadata[it] as? YlDashVideoCoverage }
    }

    fun update(manifest: DashManifest) {
        nextByCoverage.clear()
        var previous = emptyList<Format>()
        for (index in 0 until manifest.periodCount) {
            val current = manifest.getPeriod(index).adaptationSets.filter { it.type == C.TRACK_TYPE_VIDEO }
                .flatMap { set -> set.representations.map { it.format } }
            // An unambiguous following AVC track can share a decoder. Bound the
            // additional allocation to SD on this 32-bit TV and let Media3 decide reuse.
            val next = current.singleOrNull()
            if (next != null && next.sampleMimeType == MimeTypes.VIDEO_H264 &&
                next.width in 1..720 && next.height in 1..576) {
                for (format in previous) {
                    if (format.sampleMimeType == next.sampleMimeType && format.width in 1..next.width &&
                        format.height in 1..next.height && (format.width < next.width || format.height < next.height)) {
                        coverage(format)?.let { nextByCoverage[it] = next }
                    }
                }
            }
            previous = current
        }
    }

    fun clear() = nextByCoverage.clear()

    fun nextFormat(format: Format): Format? = coverage(format)?.let(nextByCoverage::get)

    companion object {
        fun forDevice(profile: YlAndroidDeviceProfile) = if (profile.isTelevision &&
            profile.signals.apiLevel == 28 && profile.tier == YlDeviceTier.CONSTRAINED &&
            Build.MODEL == "MiTV-MTTP0") YlDashDecoderSizing() else null
    }
}
