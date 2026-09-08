package dev.ylplayer.yl_player_android

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class YlAndroidChannelTest {
    @Test
    fun `per load goals apply existing profiles without mutating previous source configuration`() {
        val legacy = PlayerConfiguration.from(mapOf("bufferMode" to "stable"))
        val low = legacy.bufferRequest(mapOf("bufferStrategy" to "lowLatency"))
        val smooth = legacy.bufferRequest(mapOf("bufferStrategy" to "smoothPlayback"))
        val automatic = legacy.bufferRequest(emptyMap())
        assertEquals(5_000, YlPlaybackPolicy.effectiveBufferProfile(YlDeviceTier.STANDARD, YlSourceClass.NETWORK_VOD, low).maxBufferMs)
        assertEquals(50_000, YlPlaybackPolicy.effectiveBufferProfile(YlDeviceTier.STANDARD, YlSourceClass.NETWORK_VOD, smooth).maxBufferMs)
        assertEquals(20_000, YlPlaybackPolicy.effectiveBufferProfile(YlDeviceTier.STANDARD, YlSourceClass.NETWORK_VOD, automatic).maxBufferMs)
        assertEquals("stable", legacy.bufferRequest().mode)
        assertEquals("lowLatency", low.mode)
    }

    @Test
    fun `explicit app managed disables automatic audio ownership with legacy defaults intact`() {
        assertFalse(PlayerConfiguration.from(mapOf("audioPolicy" to "appManaged")).managesAudioSession)
        assertTrue(PlayerConfiguration.from(emptyMap()).managesAudioSession)
    }
    @Test
    fun `full state carries committed candidate token independently of generation`() {
        val state = YlAndroidChannel.fullStateEnvelope(7, 3, emptyMap(), loadToken = 11)
        assertEquals(11L, state["loadToken"])
        assertEquals(3L, state["generation"])
    }

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
