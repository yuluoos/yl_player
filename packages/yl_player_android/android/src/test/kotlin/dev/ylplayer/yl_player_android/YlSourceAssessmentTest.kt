package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import kotlin.test.*

class YlSourceAssessmentTest {
    private val options = AndroidLoadOptionsMessage(false, bufferStrategy = AndroidBufferStrategyMessage(AndroidBufferKind.AUTOMATIC), videoConstraints = AndroidVideoConstraintsMessage())
    private fun assess(source: AndroidSourceMessage, decoder: AndroidDecoderPolicy = AndroidDecoderPolicy.SYSTEM_DEFAULT, evidence: YlDecoderEvidenceProvider = YlDecoderEvidenceProvider(29, listOf(YlCodecDescriptor("vendor", true, false)) ), load: AndroidLoadOptionsMessage = options) =
        YlSourceAssessment(evidence).assess(source, load, decoder)
    private fun source(kind: AndroidSourceKind, url: String, format: AndroidMediaFormat = AndroidMediaFormat.MP4) = AndroidSourceMessage(kind, url, AndroidStreamIntent.ON_DEMAND, format)
    @Test fun `invalid ports and HTTP header values fail before native allocation`() {
        assertEquals(AndroidAssessmentOutcome.INCOMPATIBLE, assess(source(AndroidSourceKind.NETWORK, "https://media.test:99999/video.mp4")).outcome)
        assertEquals(AndroidAssessmentOutcome.INCOMPATIBLE, assess(source(AndroidSourceKind.NETWORK, "https://media.test/video.mp4").copy(request = AndroidHttpRequestMessage(mapOf("X-Test" to "value\r\nInjected: bad"), emptyMap()))).outcome)
    }
    @Test fun `known local content progressive and managed HLS have real routes`() {
        for (value in listOf(source(AndroidSourceKind.FILE, "/tmp/video.mp4"), source(AndroidSourceKind.CONTENT, "content://media/external/video/1"), source(AndroidSourceKind.NETWORK, "https://media.test/movie.mp4"), source(AndroidSourceKind.NETWORK, "https://media.test/master.m3u8", AndroidMediaFormat.HLS).copy(networkPolicy = AndroidNetworkPolicyMessage(AndroidNetworkPolicyKind.MANAGED, 100, 200, 1, 10, 20, 2)))) {
            assertEquals(AndroidAssessmentOutcome.COMPATIBLE, assess(value).outcome)
        }
    }
    @Test fun `malformed descriptors and unimplemented hard buffers reject`() {
        for (value in listOf(source(AndroidSourceKind.NETWORK, "ftp://media.test/video"), source(AndroidSourceKind.CONTENT, "content:"), source(AndroidSourceKind.CONTENT, "content:///missing-authority"))) assertEquals(AndroidAssessmentOutcome.INCOMPATIBLE, assess(value).outcome)
        assertEquals("policy.unsupported", assess(source(AndroidSourceKind.FILE, "/tmp/video.mp4"), load = options.copy(bufferStrategy = AndroidBufferStrategyMessage(AndroidBufferKind.BOUNDED, 100))).rejection?.code)
    }
    @Test fun `unknown containers and attainable strict evidence require inspection`() {
        val value = source(AndroidSourceKind.NETWORK, "https://media.test/opaque", AndroidMediaFormat.AUTOMATIC)
        assertEquals(AndroidAssessmentOutcome.REQUIRES_INSPECTION, assess(value).outcome)
        assertEquals(AndroidAssessmentOutcome.REQUIRES_INSPECTION, assess(value.copy(format = AndroidMediaFormat.MP4), AndroidDecoderPolicy.HARDWARE_REQUIRED).outcome)
        assertEquals(AndroidAssessmentOutcome.REQUIRES_INSPECTION, assess(value, AndroidDecoderPolicy.HARDWARE_REQUIRED, YlDecoderEvidenceProvider(28, listOf(YlCodecDescriptor("OMX.vendor", true, false)))).outcome)
        val unavailable = YlSourceAssessment(YlDecoderEvidenceProvider(28, emptyList()))
        assertEquals(AndroidAssessmentOutcome.INCOMPATIBLE, unavailable.assess(value, options, AndroidDecoderPolicy.HARDWARE_REQUIRED, hasVideo = true).outcome)
        assertEquals(AndroidAssessmentOutcome.COMPATIBLE, unavailable.assess(value.copy(format = AndroidMediaFormat.MP4), options, AndroidDecoderPolicy.HARDWARE_REQUIRED, hasVideo = false).outcome)
        val inspected = YlSourceAssessment(YlDecoderEvidenceProvider(29, listOf(YlCodecDescriptor("hw", true, false), YlCodecDescriptor("sw", false, true))))
        assertEquals(AndroidAssessmentOutcome.COMPATIBLE, inspected.assess(value.copy(format = AndroidMediaFormat.MP4), options, AndroidDecoderPolicy.HARDWARE_REQUIRED, true, "hw").outcome)
        assertEquals(AndroidAssessmentOutcome.INCOMPATIBLE, inspected.assess(value.copy(format = AndroidMediaFormat.MP4), options, AndroidDecoderPolicy.HARDWARE_REQUIRED, true, "sw").outcome)
        val preferred = assess(value.copy(format = AndroidMediaFormat.MP4), AndroidDecoderPolicy.HARDWARE_PREFERRED)
        assertEquals(AndroidAssessmentOutcome.COMPATIBLE, preferred.outcome)
        assertTrue(preferred.limitations.contains("decoder.modeUnknown"))
        assertTrue(preferred.satisfiedRequirements.contains("decoder.hardwarePreferred"))
        assertTrue(preferred.satisfiedRequirements.contains("network.platformDefault"))
    }
}
