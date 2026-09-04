package dev.ylplayer.yl_player_android

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
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

    @Test
    fun `full state envelope carries protocol and generation`() {
        val state = mapOf<String, Any?>("status" to "playing", "decoderName" to "hardware")

        val envelope = YlAndroidChannel.fullStateEnvelope(
            playerId = 7,
            generation = 3,
            state = state,
        )

        assertEquals(1, envelope["protocolVersion"])
        assertEquals(7L, envelope["playerId"])
        assertEquals(3L, envelope["generation"])
        assertEquals("state", envelope["type"])
        assertEquals(state, envelope["state"])
    }

    @Test
    fun `delta envelope carries no static state`() {
        val envelope = YlAndroidChannel.stateDeltaEnvelope(
            playerId = 7,
            generation = 3,
            delta = mapOf(
                "positionMs" to 1_000L,
                "bufferedPositionMs" to 3_000L,
                "isAtLiveEdge" to false,
                "liveOffsetMs" to 2_500L,
                "metrics" to mapOf("droppedVideoFrames" to 2),
            ),
        )

        assertEquals(1, envelope["protocolVersion"])
        assertEquals(7L, envelope["playerId"])
        assertEquals(3L, envelope["generation"])
        assertEquals("stateDelta", envelope["type"])
        val delta = envelope["delta"] as Map<*, *>
        assertFalse(delta.containsKey("tracks"))
        assertFalse(delta.containsKey("capabilities"))
        assertFalse(delta.containsKey("decoderName"))
    }
}
