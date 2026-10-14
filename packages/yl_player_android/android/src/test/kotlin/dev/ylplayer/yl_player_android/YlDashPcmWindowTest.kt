package dev.ylplayer.yl_player_android

import kotlin.test.*

class YlDashPcmWindowTest {
    @Test fun `final AAC buffer is clipped after decoding not at compressed packet boundary`() {
        val window = YlDashPcmWindow(YlDashTime.ZERO, YlDashTime.of(7, 2))
        assertEquals(64, window.clip(3498666, 1024, 48000).count)
        assertEquals(0, window.clip(3500000, 1024, 48000).count)
    }
    @Test fun `fractional endpoints project once to sample grid without accumulating drift`() {
        val first = YlDashPcmWindow(YlDashTime.ZERO, YlDashTime.of(1, 3))
        val second = YlDashPcmWindow(YlDashTime.of(1, 3), YlDashTime.of(2, 3))
        val third = YlDashPcmWindow(YlDashTime.of(2, 3), YlDashTime.of(1))
        assertEquals(44100, listOf(first, second, third).sumOf { it.frames(44100) })
        assertEquals(16, YlDashPcmWindow(YlDashTime.ZERO, YlDashTime.of(1, 3000)).frames(48000))
    }
    @Test fun `negative preroll keeps only samples in the programme window`() {
        val window = YlDashPcmWindow(YlDashTime.ZERO, YlDashTime.of(1))
        val clip = window.clip(-10000, 1024, 48000)
        assertEquals(480, clip.skip)
        assertEquals(544, clip.count)
    }
    @Test fun `PCM sink retains clipped buffer across partial writes and duplicate manifest merges`() {
        val delegate = org.mockito.Mockito.mock(androidx.media3.exoplayer.audio.AudioSink::class.java)
        val window = YlDashPcmWindow(YlDashTime.ZERO, YlDashTime.of(7, 2))
        val format = androidx.media3.common.Format.Builder().setSampleMimeType("audio/raw")
            .setSampleRate(48000).setChannelCount(1).setPcmEncoding(androidx.media3.common.C.ENCODING_PCM_16BIT)
            .setMetadata(androidx.media3.common.Metadata(window, window)).build()
        val sink = YlDashPcmAudioSink(delegate)
        sink.configure(androidx.media3.exoplayer.audio.AudioSink.AudioSinkConfig.Builder(format).build())
        sink.setOutputStreamOffsetUs(1000000)
        val observed = mutableListOf<Int>()
        org.mockito.Mockito.`when`(delegate.handleBuffer(org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.anyLong(), org.mockito.ArgumentMatchers.anyInt()))
            .thenAnswer { invocation ->
                val buffer = invocation.getArgument<java.nio.ByteBuffer>(0)
                observed += buffer.remaining() / 2
                val consumed = observed.size > 1
                buffer.position(if (consumed) buffer.limit() else buffer.position() + 16)
                consumed
            }
        val pcm = java.nio.ByteBuffer.allocateDirect(2048)
        assertFalse(sink.handleBuffer(pcm, 4498666, 1))
        assertTrue(sink.handleBuffer(pcm, 4498666, 1))
        assertEquals(listOf(64, 56), observed)
        assertEquals(2048, pcm.position())
    }

}
