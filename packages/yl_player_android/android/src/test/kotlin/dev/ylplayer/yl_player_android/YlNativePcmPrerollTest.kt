package dev.ylplayer.yl_player_android
import kotlin.test.*
class YlNativePcmPrerollTest {
    @Test fun trimsAcrossWholeBlocksAndPreservesPartialInterleavedFrameAlignment() {
        val pcm=YlNativePcmChunk(ByteArray(1024*4) { (it%251).toByte() },48000,2,0)
        assertNull(trimNativePcm(pcm,30000))
        val trimmed=assertNotNull(trimNativePcm(pcm,10000))
        assertEquals(10000,trimmed.presentationTimeUs)
        assertContentEquals(pcm.data.copyOfRange(480*4,pcm.data.size),trimmed.data)
    }
    @Test fun negativePrerollAndFractionalTargetNeverEmitAnEarlierSample() {
        val pcm=YlNativePcmChunk(ByteArray(1024*4),48000,2,-10000)
        assertEquals(0,trimNativePcm(pcm,0)?.presentationTimeUs)
        val fractional=assertNotNull(trimNativePcm(pcm,1))
        assertTrue(fractional.presentationTimeUs>=1)
        assertEquals(543*4,fractional.data.size)
    }
}
