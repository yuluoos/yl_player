package dev.ylplayer.yl_player_android

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class YlAndroidChannelTest {
    @Test
    fun `every explicit supported format has a MIME route`() {
        val explicit = YlAndroidChannel.supportedFormats.filterNot { it == "automatic" }

        assertTrue(explicit.all { YlAndroidChannel.mimeType(it) != null })
        assertTrue("mov" in explicit)
        assertTrue("avi" in explicit)
        assertEquals(explicit.size, explicit.toSet().size)
    }

    @Test
    fun `capability codecs remain canonical sorted MIME strings`() {
        val capabilities = YlAndroidChannel.capabilities(
            hardwareVideoCodecs = listOf("video/hevc", "video/avc", "video/hevc"),
            maxWidth = 1920,
            maxHeight = 1080,
        )

        assertEquals(
            listOf("video/avc", "video/hevc"),
            capabilities["hardwareVideoCodecs"],
        )
        assertEquals(YlAndroidChannel.supportedFormats, capabilities["supportedFormats"])
        assertEquals(1, capabilities["maxConcurrentVideoDecoders"])
        assertEquals(1920, capabilities["maxWidth"])
        assertEquals(1080, capabilities["maxHeight"])
    }

    @Test
    fun `defensive native decoder default is hardware only`() {
        val configuration = PlayerConfiguration.from(emptyMap())

        assertEquals("hardwareOnly", configuration.decoderPolicy)
        assertNotNull(configuration.network)
    }
}
