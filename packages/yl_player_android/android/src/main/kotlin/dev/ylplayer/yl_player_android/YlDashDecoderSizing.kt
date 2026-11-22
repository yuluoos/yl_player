package dev.ylplayer.yl_player_android

import android.os.Build
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.Size
import androidx.media3.exoplayer.dash.manifest.DashManifest
import java.util.IdentityHashMap

/** The source and the renderer use the playback looper. Match the parser-owned
 * metadata by identity because representation IDs can repeat across Periods. */
internal class YlDashDecoderSizing {
    var transitionOutputSize: Size? = null
        private set
    private val nextByCoverage = IdentityHashMap<YlDashVideoCoverage, Format>()
    private fun coverage(format: Format) = format.metadata?.let { metadata ->
        (0 until metadata.length()).firstNotNullOfOrNull { metadata[it] as? YlDashVideoCoverage }
    }

    fun update(manifest: DashManifest) {
        clear()
        val windows = (manifest as? YlDashProgramManifest)?.program?.windows
        val contiguousPair = !manifest.dynamic && windows?.size == 2 &&
            windows[0].start == YlDashTime.ZERO && windows[0].declaredEnd == windows[1].start
        var previous = emptyList<Format>()
        for (index in 0 until manifest.periodCount) {
            val current = manifest.getPeriod(index).adaptationSets.filter { it.type == C.TRACK_TYPE_VIDEO }
                .flatMap { set -> set.representations.map { it.format } }
            val next = current.singleOrNull()
            val old = previous.singleOrNull()
            if (contiguousPair && index == 1 &&
                old?.sampleMimeType == MimeTypes.VIDEO_H264 && next?.sampleMimeType == MimeTypes.VIDEO_H265 &&
                listOf(old, next).all(::smallClearVideo) && old.width * next.height == next.width * old.height) {
                transitionOutputSize = Size(maxOf(old.width, next.width), maxOf(old.height, next.height))
            }
            // An unambiguous following AVC track can share a decoder. Bound the
            // additional allocation to SD on this 32-bit TV and let Media3 decide reuse.
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

    private fun smallClearVideo(format: Format): Boolean {
        if (format.sampleMimeType == MimeTypes.VIDEO_H265) {
            val profile = format.codecs?.substringAfter('.', "")?.substringBefore('.')
            if (!profile.isNullOrEmpty() && profile != "1") return false
        }
        val color = format.colorInfo
        return format.width in 1..720 && format.height in 1..576 && format.drmInitData == null &&
            format.rotationDegrees == 0 && format.pixelWidthHeightRatio == 1f && format.frameRate <= 30f &&
            color?.hdrStaticInfo == null && (color == null ||
                color.colorTransfer in listOf(Format.NO_VALUE, C.COLOR_TRANSFER_SDR) &&
                color.lumaBitdepth in listOf(Format.NO_VALUE, 8) && color.chromaBitdepth in listOf(Format.NO_VALUE, 8))
    }

    fun clear() {
        nextByCoverage.clear()
        transitionOutputSize = null
    }

    fun nextFormat(format: Format): Format? = coverage(format)?.let(nextByCoverage::get)

    companion object {
        fun forDevice(profile: YlAndroidDeviceProfile) = if (profile.isTelevision &&
            profile.signals.apiLevel == 28 && profile.tier == YlDeviceTier.CONSTRAINED &&
            Build.MODEL == "MiTV-MTTP0") YlDashDecoderSizing() else null
    }
}
