package dev.ylplayer.yl_player_android

import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import kotlin.test.*

class YlProtectedCodecSelectorTest {
    private fun codec(name: String, secure: Boolean, hardware: Boolean = true) = MediaCodecInfo.newInstance(
        name, "video/avc", "video/avc", null, hardware, !hardware, true, false, secure)
    @Test fun `Media3 insecure retry still queries secure codecs and filters false evidence`() {
        val protected = codec("protected", true)
        val ordinary = codec("ordinary", false)
        val software = codec("software", true, false)
        val queries = mutableListOf<Boolean>()
        val selector = YlProtectedCodecSelector(MediaCodecSelector { _, secure, _ ->
            queries += secure; listOf(ordinary, software, protected)
        }, YlDecoderEvidenceProvider(29, listOf(YlCodecDescriptor("protected", true, false),
            YlCodecDescriptor("ordinary", true, false), YlCodecDescriptor("software", false, true))))
        assertFalse(selector.provesInitialized("protected"))
        assertEquals(listOf(protected), selector.getDecoderInfos("video/avc", true, false))
        assertTrue(selector.provesInitialized("protected"))
        assertFalse(selector.provesInitialized("ordinary"))
        assertEquals(listOf(protected), selector.getDecoderInfos("video/avc", false, false))
        assertEquals(listOf(true, true), queries)
    }
    @Test fun `missing secure or actual hardware evidence fails closed`() {
        val codec = codec("protected", true)
        for (api in listOf(24, 28, 29)) {
            val selector = YlProtectedCodecSelector(MediaCodecSelector { _, _, _ -> listOf(codec) },
                YlDecoderEvidenceProvider(api, emptyList()))
            val error = assertFailsWith<YlBoundaryException> { selector.getDecoderInfos("video/avc", false, false) }
            assertEquals(YlFailureKind.DRM_PROTECTION_INSUFFICIENT, error.kind)
        }
    }
    @Test fun `audio secure requirement is preserved and cannot select unprotected audio`() {
        val ordinary = codec("audio", false)
        val selector = YlProtectedCodecSelector(MediaCodecSelector { _, _, _ -> listOf(ordinary) },
            YlDecoderEvidenceProvider(29, emptyList()))
        assertFailsWith<YlBoundaryException> { selector.getDecoderInfos("audio/mp4a-latm", true, false) }
    }
}
