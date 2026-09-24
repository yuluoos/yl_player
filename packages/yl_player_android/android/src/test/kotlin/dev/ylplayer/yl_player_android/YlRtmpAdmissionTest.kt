package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import kotlin.test.*

class YlRtmpAdmissionTest {
    private val options = AndroidLoadOptionsMessage(false, bufferStrategy = AndroidBufferStrategyMessage(AndroidBufferKind.AUTOMATIC), videoConstraints = AndroidVideoConstraintsMessage())
    private fun source(url: String = "rtmp://localhost/live/camera") = AndroidSourceMessage(AndroidSourceKind.NETWORK, url, AndroidStreamIntent.AUTOMATIC, AndroidMediaFormat.AUTOMATIC)
    private fun assess(s: AndroidSourceMessage, o: AndroidLoadOptionsMessage = options) = YlSourceAssessment(YlDecoderEvidenceProvider(29, emptyList())).assess(s, o, AndroidDecoderPolicy.SYSTEM_DEFAULT)
    @Test fun `rtmp routes before HTTP conversion`() {
        assertNotEquals(AndroidAssessmentOutcome.INCOMPATIBLE, assess(source()).outcome)
        assertNotEquals(AndroidAssessmentOutcome.INCOMPATIBLE, assess(source("rtmp://localhost/a%2fb/nested/x%FF?token=a+b%2f")).outcome)
    }
    @Test fun `unsupported protocol and policies have stable rejection`() {
        assertEquals("network.protocol_unsupported", assess(source("rtmps://localhost/live/camera")).rejection?.code)
        assertEquals("policy.unsupported", assess(source().copy(intent = AndroidStreamIntent.ON_DEMAND)).rejection?.code)
        assertEquals("policy.unsupported", assess(source(), options.copy(startPositionMs = 1)).rejection?.code)
        assertEquals("policy.unsupported", assess(source().copy(request = AndroidHttpRequestMessage(mapOf("X-Test" to "x"), emptyMap()))).rejection?.code)
        assertEquals("container.unsupported", assess(source().copy(format = AndroidMediaFormat.HLS)).rejection?.code)
    }
    @Test fun `malformed and decoded control values rejected`() {
        listOf("rtmp://a/live", "rtmp://a:/live/x", "rtmp://a:0/live/x", "rtmp://a:65536/live/x", "rtmp://u@a/live/x", "rtmp://a/live/x#frag", "rtmp://a/live/%00", "rtmp://a/live/%C2%85", "rtmp://a/live/%ZZ").forEach {
            assertEquals("source.invalid", assess(source(it)).rejection?.code, it)
        }
    }
    @Test fun `opaque app playpath query and port preserve lexical identity`() {
        val a=YlRtmpSourcePolicy.parse("rtmp://localhost:1940/a%2fb/nested/x%FF?token=a+b%2f")
        assertEquals("a%2fb",a.app);assertEquals("nested/x%FF?token=a+b%2f",a.playpath)
        assertEquals(1940,a.port);assertEquals("rtmp://localhost:1940/a%2fb",a.tcUrl)
        assertEquals(1935,YlRtmpSourcePolicy.parse("rtmp://localhost/live/x").port)
        assertEquals("source.invalid",assess(source("rtmp://localhost/live/"+"x".repeat(8192))).rejection?.code)
        assertEquals("policy.unsupported",assess(source().copy(networkPolicy=AndroidNetworkPolicyMessage(AndroidNetworkPolicyKind.MANAGED,100,200,1,10,20,0))).rejection?.code)
    }
    @Test fun `nested errors map safe phase codes and preserve permanent handshake rejection`() {
        for(kind in listOf(YlFailureKind.RTMP_HANDSHAKE_FAILED,YlFailureKind.RTMP_DISCONNECTED,YlFailureKind.RTMP_STREAM_UNAVAILABLE,YlFailureKind.NETWORK_PROTOCOL_UNSUPPORTED,YlFailureKind.RTMP_HANDSHAKE_INVALID)) {
            val error=java.io.IOException("not public",YlRtmpException(kind,kind.retryable))
            val wire=YlFailureMapper().toMessage(error)
            assertEquals(kind.code,wire.code);assertFalse(wire.message.contains("not public"));assertEquals(kind.retryable,wire.retryable)
            assertEquals(kind,mediaFailure(2000,error,AndroidDecoderPolicy.SYSTEM_DEFAULT))
        }
        assertFalse(YlFailureMapper().toMessage(YlRtmpException(YlFailureKind.RTMP_HANDSHAKE_INVALID)).retryable)
    }

}
