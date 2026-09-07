package dev.ylplayer.yl_player_android

import kotlin.test.*

class YlStopPolicyTest {
    @Test fun stopClearsSessionAndAdvancesGenerationWithoutDisposingIdentity() {
        val reset = YlStopPolicy.reset(generation = 41)
        assertEquals(42L, reset.generation)
        assertEquals("idle", reset.state["status"])
        assertEquals(0L, reset.state["positionMs"])
        assertEquals(0L, reset.state["bufferedPositionMs"])
        for (field in listOf("durationMs", "videoWidth", "videoHeight", "error", "decoderName", "liveOffsetMs", "dvrStartMs", "dvrEndMs")) {
            assertTrue(reset.state.containsKey(field), field)
            assertNull(reset.state[field], field)
        }
        assertEquals(emptyList<Any>(), reset.state["audioTracks"])
        assertEquals(emptyList<Any>(), reset.state["videoTracks"])
        assertEquals(false, reset.state["isLive"])
        assertEquals(false, reset.state["isSeekable"])
        val metrics = reset.state["metrics"] as Map<*, *>
        assertEquals(0, metrics["reconnectCount"])
        assertEquals(0, metrics["rebufferCount"])
        assertNull(metrics["firstFrameDurationMs"])
    }
}
