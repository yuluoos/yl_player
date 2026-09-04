package dev.ylplayer.yl_player_android

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class YlHardwareCodecSelectorTest {
    @Test
    fun `legacy software codec names are rejected`() {
        listOf(
            "OMX.google.h264.decoder",
            "c2.android.avc.decoder",
            "vendor.software.hevc.decoder",
            "vendor.sw.avc.decoder",
            "avc.decoder",
        ).forEach { assertFalse(isHardwareCodecName(it), it) }
    }

    @Test
    fun `known vendor codec names are accepted`() {
        listOf(
            "OMX.amlogic.avc.decoder.awesome",
            "OMX.MTK.VIDEO.DECODER.AVC",
            "c2.qti.avc.decoder",
            "c2.exynos.hevc.decoder",
        ).forEach { assertTrue(isHardwareCodecName(it), it) }
    }

    @Test
    fun `platform software flag wins over a vendor-looking name`() {
        assertFalse(
            shouldAcceptCodec(
                mimeType = "video/avc",
                name = "OMX.vendor.avc.decoder",
                hardwareAccelerated = true,
                softwareOnly = true,
            ),
        )
    }

    @Test
    fun `audio codecs pass through normal Media3 selection`() {
        assertTrue(
            shouldAcceptCodec(
                mimeType = "audio/mp4a-latm",
                name = "c2.android.aac.decoder",
                hardwareAccelerated = false,
                softwareOnly = true,
            ),
        )
    }

    @Test
    fun `HEVC requires an explicit accepted hardware candidate`() {
        val candidates = listOf(
            YlCodecDescriptor("c2.android.hevc.decoder", false, true),
        )
        assertFalse(hasExplicitHardwareDecoder("video/hevc", candidates))
        assertTrue(
            hasExplicitHardwareDecoder(
                "video/hevc",
                candidates + YlCodecDescriptor("OMX.amlogic.hevc.decoder", true, false),
            ),
        )
    }

    @Test
    fun `constrained envelope is capped at 1080p30`() {
        assertEquals(
            YlVideoEnvelope(1920, 1080, 30.0),
            videoEnvelope(YlDeviceTier.CONSTRAINED, 3840, 2160, 60.0),
        )
    }

    @Test
    fun `display limits intersect the tier envelope`() {
        assertEquals(
            YlVideoEnvelope(1280, 720, 25.0),
            videoEnvelope(YlDeviceTier.CONSTRAINED, 1280, 720, 25.0),
        )
        assertEquals(
            YlVideoEnvelope(1280, 720, 60.0),
            videoEnvelope(YlDeviceTier.STANDARD, 1280, 720, 60.0),
        )
        val unknown = videoEnvelope(YlDeviceTier.CAPABLE, null, null, null)
        assertNull(unknown.maxWidth)
        assertNull(unknown.maxHeight)
        assertNull(unknown.maxFrameRate)
    }

    @Test
    fun `host limits can only tighten an envelope`() {
        val constrained = videoEnvelope(YlDeviceTier.CONSTRAINED, 3840, 2160, 60.0)
        assertEquals(
            YlVideoEnvelope(1280, 720, 30.0),
            constrained.intersect(maxWidth = 1280, maxHeight = 720),
        )
    }
}
