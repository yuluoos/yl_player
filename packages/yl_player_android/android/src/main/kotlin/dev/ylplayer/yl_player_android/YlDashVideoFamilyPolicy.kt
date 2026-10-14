package dev.ylplayer.yl_player_android

import androidx.media3.common.C
import androidx.media3.common.Format

/** Session-scoped colour intent shared by the DASH selector and decoded output gate.
 * Unknown manifest colour remains provisional until actual decoder metadata is checked
 * before frame release. Seek/reprepare never resets the accepted output family. */
internal class YlDashVideoFamilyPolicy(initial: String? = null) {
    @Volatile var accepted: String? = initial
        private set

    /** Restore occurs while this engine is quiesced, before its streams are activated. */
    fun restore(value: String?) {
        if (accepted != null && value != null && accepted != value) unsupported()
        if (value != null) accepted = value
    }

    var onAccepted: (() -> Unit)? = null

    fun compatible(format: Format) = try { family(format)?.let { accepted == null || accepted == it } ?: true }
        catch (_: YlBoundaryException) { false }

    fun accept(format: Format) {
        val next = family(format) ?: return
        if (accepted == null) { accepted = next; onAccepted?.invoke() }
        else if (accepted != next) unsupported()
    }

    fun verifyOutput(format: Format, decodedTransfer: Int?) {
        val transfer = decodedTransfer?.takeUnless { it == Format.NO_VALUE }
            ?: format.colorInfo?.colorTransfer?.takeUnless { it == Format.NO_VALUE } ?: C.COLOR_TRANSFER_SDR
        val actual = format.buildUpon()
            .setColorInfo((format.colorInfo?.buildUpon() ?: androidx.media3.common.ColorInfo.Builder())
                .setColorTransfer(transfer).build()).build()
        accept(actual)
    }

    private fun family(format: Format): String? {
        val transfer = format.colorInfo?.colorTransfer?.takeUnless { it == Format.NO_VALUE }
        if (format.sampleMimeType == "video/dolby-vision") {
            val codec = format.codecs?.lowercase() ?: unsupported()
            val profile = Regex("(?:dvhe|dvh1|dvav|dva1)\\.(\\d{2})\\.\\d{2}").matchEntire(codec)?.groupValues?.get(1)
                ?: unsupported()
            // Profile 7 does not identify MEL vs FEL. This Media3 path has no evidence
            // of a complete enhancement-layer decoder, so never choose a BL fallback.
            if (profile == "07") unsupported()
            return transfer?.let { "dolby:$profile:$it" }
        }
        if (transfer == null) return null
        if (format.colorInfo?.hdrStaticInfo != null && transfer == C.COLOR_TRANSFER_SDR) unsupported()
        return when (transfer) {
            C.COLOR_TRANSFER_SDR -> "sdr"
            C.COLOR_TRANSFER_ST2084 -> "pq"
            C.COLOR_TRANSFER_HLG -> "hlg"
            else -> unsupported()
        }
    }

    private fun unsupported(): Nothing = throw YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED)
}
