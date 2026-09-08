package dev.ylplayer.yl_player_android

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class YlHardwareCodecSelectorTest {
    @Test fun `production inventory reports deduplicated video MIME families excluding software audio and encoders`() {
        fun codec(name: String, types: Array<String>, hardware: Boolean = true, encoder: Boolean = false): android.media.MediaCodecInfo = org.mockito.Mockito.mock(android.media.MediaCodecInfo::class.java).also {
            org.mockito.Mockito.`when`(it.name).thenReturn(name)
            org.mockito.Mockito.`when`(it.canonicalName).thenReturn(name)
            org.mockito.Mockito.`when`(it.supportedTypes).thenReturn(types)
            org.mockito.Mockito.`when`(it.isEncoder).thenReturn(encoder)
            org.mockito.Mockito.`when`(it.isHardwareAccelerated).thenReturn(hardware)
            org.mockito.Mockito.`when`(it.isSoftwareOnly).thenReturn(!hardware)
        }
        val inventory = arrayOf(codec("one", arrayOf("video/hevc", "video/avc", "audio/aac")), codec("alias", arrayOf("video/avc")), codec("audio", arrayOf("audio/aac")), codec("encoder", arrayOf("video/vp9"), encoder = true), codec("software", arrayOf("video/av01"), hardware = false))
        assertEquals(listOf("video/avc", "video/hevc"), YlDecoderEvidenceProvider.collect(29) { inventory }.hardwareCodecs)
        assertTrue(YlDecoderEvidenceProvider.collect(28) { inventory }.hardwareCodecs.isEmpty())
        assertTrue(YlDecoderEvidenceProvider.collect(29) { throw IllegalStateException() }.hardwareCodecs.isEmpty())
    }
    @Test fun `canonical aliases prove only consistent exact initialized codec metadata`() {
        val evidence = YlDecoderEvidenceProvider(29, listOf(YlCodecDescriptor("vendor.alias", true, false, "vendor.canonical")))
        assertEquals(dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode.HARDWARE, evidence.mode("vendor.canonical"))
        assertEquals(dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode.UNKNOWN, evidence.mode("vendor.unrelated"))
        val conflict = YlDecoderEvidenceProvider(29, listOf(YlCodecDescriptor("alias1", true, false, "same"), YlCodecDescriptor("alias2", false, true, "same")))
        assertEquals(dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode.UNKNOWN, conflict.mode("same"))
    }
    @Test fun `strict selector accepts only API29 records and refuses name-only API28 candidates`() {
        val named = androidx.media3.exoplayer.mediacodec.MediaCodecInfo.newInstance("OMX.vendor", "video/avc", "video/avc", null, true, false, true, false, false)
        val delegate = androidx.media3.exoplayer.mediacodec.MediaCodecSelector { _, _, _ -> listOf(named) }
        val records = listOf(YlCodecDescriptor("OMX.vendor", true, false))
        val strict = dev.ylplayer.yl_player_android.pigeon.AndroidDecoderPolicy.HARDWARE_REQUIRED
        assertTrue(YlPolicyCodecSelector(strict, delegate, YlDecoderEvidenceProvider(28, records)).getDecoderInfos("video/avc", false, false).isEmpty())
        assertEquals(listOf(named), YlPolicyCodecSelector(strict, delegate, YlDecoderEvidenceProvider(29, records)).getDecoderInfos("video/avc", false, false))
        assertEquals(listOf(named), YlPolicyCodecSelector(strict, delegate, YlDecoderEvidenceProvider(28, records)).getDecoderInfos("audio/aac", false, false))
    }
    @Test fun `positive evidence belongs to initialized codec and unavailable on API28 names`() {
        val records = listOf(YlCodecDescriptor("OMX.vendor", true, false), YlCodecDescriptor("software", false, true))
        assertEquals(dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode.UNKNOWN, YlDecoderEvidenceProvider(28, records).mode("OMX.vendor"))
        val provider = YlDecoderEvidenceProvider(29, records)
        assertEquals(dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode.HARDWARE, provider.mode("OMX.vendor"))
        assertEquals(dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode.SOFTWARE, provider.mode("software"))
        assertEquals(dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode.UNKNOWN, provider.mode("unrelated"))
        assertTrue(provider.satisfiesRequired(hasVideo = false, initializedName = null))
        assertFalse(provider.satisfiesRequired(hasVideo = true, initializedName = "software"))
        assertFalse(provider.satisfiesRequired(hasVideo = true, initializedName = null))
    }

    @Test
    fun `v2 selector preserves default order and preferred software fallback`() {
        val software = androidx.media3.exoplayer.mediacodec.MediaCodecInfo.newInstance(
            "c2.android.avc.decoder", "video/avc", "video/avc", null, false, true, false, false, false)
        val hardware = androidx.media3.exoplayer.mediacodec.MediaCodecInfo.newInstance(
            "OMX.vendor.avc.decoder", "video/avc", "video/avc", null, true, false, true, false, false)
        val delegate = androidx.media3.exoplayer.mediacodec.MediaCodecSelector { _, _, _ -> listOf(software, hardware) }
        val system = YlPolicyCodecSelector(dev.ylplayer.yl_player_android.pigeon.AndroidDecoderPolicy.SYSTEM_DEFAULT, delegate)
        val preferred = YlPolicyCodecSelector(dev.ylplayer.yl_player_android.pigeon.AndroidDecoderPolicy.HARDWARE_PREFERRED, delegate)
        assertEquals(listOf(software, hardware), system.getDecoderInfos("video/avc", false, false))
        assertEquals(listOf(hardware, software), preferred.getDecoderInfos("video/avc", false, false))
        assertEquals(listOf(software, hardware), preferred.getDecoderInfos("audio/aac", false, false))
    }

    @Test fun `strict gate waits for initialized evidence and admits audio without video callback`() = kotlinx.coroutines.test.runTest {
        val gate = YlInitializedDecoderGate(dev.ylplayer.yl_player_android.pigeon.AndroidDecoderPolicy.HARDWARE_REQUIRED)
        val video = dev.ylplayer.yl_player_android.pigeon.AndroidTrackMessage("v", dev.ylplayer.yl_player_android.pigeon.AndroidTrackKind.VIDEO, isSelected = true)
        gate.accept(YlEngineSnapshot(status = dev.ylplayer.yl_player_android.pigeon.AndroidPlaybackStatus.READY, videoTracks = listOf(video)))
        assertFalse(gate.ready.isCompleted)
        gate.accept(YlEngineSnapshot(status = dev.ylplayer.yl_player_android.pigeon.AndroidPlaybackStatus.READY, videoTracks = listOf(video), decoderIdentity = "real-hw", decoderMode = dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode.HARDWARE))
        assertTrue(gate.ready.isCompleted)
        gate.reset()
        assertFalse(gate.ready.isCompleted)
        val audio = dev.ylplayer.yl_player_android.pigeon.AndroidTrackMessage("a", dev.ylplayer.yl_player_android.pigeon.AndroidTrackKind.AUDIO, isSelected = true)
        gate.accept(YlEngineSnapshot(status = dev.ylplayer.yl_player_android.pigeon.AndroidPlaybackStatus.READY, audioTracks = listOf(audio)))
        assertTrue(gate.ready.isCompleted)
    }

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
                candidates + YlCodecDescriptor("OMX.amlogic.hevc.decoder", true, false), apiLevel = 29,
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
