package dev.ylplayer.yl_player_android

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class YlPlayerErrorPolicyTest {
    @Test
    fun `missing hardware decoder has a stable public error`() {
        assertEquals(
            YlStableError(
                category = "decoderUnsupported",
                code = "decoder.hardware_required",
                message = "A compatible hardware video decoder is required.",
            ),
            stableError(YlPlaybackFailure.NO_HARDWARE_DECODER),
        )
    }

    @Test
    fun `capability and decoder failures keep distinct codes`() {
        assertEquals(
            "decoder.capability_exceeded",
            stableError(YlPlaybackFailure.CAPABILITY_EXCEEDED).code,
        )
        assertEquals(
            "decoder.initialization_failed",
            stableError(YlPlaybackFailure.DECODER_INITIALIZATION).code,
        )
    }

    @Test
    fun `adaptive decoder initialization can retry only once`() {
        assertEquals(
            YlDecoderRecovery.DOWNGRADE_ONCE,
            decoderRecovery(isAdaptive = true, previousRetries = 0),
        )
        assertEquals(
            YlDecoderRecovery.FAIL,
            decoderRecovery(isAdaptive = true, previousRetries = 1),
        )
        assertEquals(
            YlDecoderRecovery.FAIL,
            decoderRecovery(isAdaptive = false, previousRetries = 0),
        )
    }

    @Test
    fun `resource and live recovery errors are stable`() {
        assertEquals("resource.video_decoder_busy", stableError(YlPlaybackFailure.DECODER_BUSY).code)
        assertEquals("resource.memory_pressure", stableError(YlPlaybackFailure.MEMORY_PRESSURE).code)
        assertEquals("network.live_retry_exhausted", stableError(YlPlaybackFailure.LIVE_RETRY_EXHAUSTED).code)
    }

    @Test
    fun `codec diagnostic cannot contain a URL or headers`() {
        val diagnostic = codecDiagnostic(
            codecName = "OMX.amlogic.avc.decoder",
            width = 1920,
            height = 1080,
            frameRate = 30.0,
            apiLevel = 24,
        )

        assertEquals(
            "codec=OMX.amlogic.avc.decoder,size=1920x1080,fps=30.0,api=24",
            diagnostic,
        )
        assertFalse(diagnostic.contains("http"))
        assertFalse(diagnostic.contains("Authorization"))
    }
}
