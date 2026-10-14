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
        sink.resetPosition(4498666)
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

    @Test fun `encoder priming is trimmed from content before leading silence is inserted`() {
        val delegate = org.mockito.Mockito.mock(androidx.media3.exoplayer.audio.AudioSink::class.java)
        val format = androidx.media3.common.Format.Builder().setSampleMimeType("audio/raw")
            .setSampleRate(48000).setChannelCount(1).setPcmEncoding(androidx.media3.common.C.ENCODING_PCM_16BIT)
            .setEncoderDelay(1024).setMetadata(androidx.media3.common.Metadata(YlDashPcmWindow(YlDashTime.ZERO, YlDashTime.of(2)))).build()
        val sink = YlDashPcmAudioSink(delegate)
        sink.setOutputStreamOffsetUs(1000000)
        sink.resetPosition(1000000)
        sink.configure(androidx.media3.exoplayer.audio.AudioSink.AudioSinkConfig.Builder(format).build())
        var zeroFrames = 0
        var toneFrames = 0
        val tonePts = mutableListOf<Long>()
        org.mockito.Mockito.`when`(delegate.handleBuffer(org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.anyLong(), org.mockito.ArgumentMatchers.anyInt()))
            .thenAnswer { invocation ->
                val buffer = invocation.getArgument<java.nio.ByteBuffer>(0)
                assertTrue(buffer.remaining() <= 32768)
                if (buffer.get(buffer.position()) == 0.toByte()) zeroFrames += buffer.remaining() / 2
                else { toneFrames += buffer.remaining() / 2; tonePts += invocation.getArgument<Long>(1) }
                buffer.position(buffer.limit()); true
            }
        val priming = java.nio.ByteBuffer.allocateDirect(2048)
        assertTrue(sink.handleBuffer(priming, 1500000, 1)) // No priming buffer reaches the output.
        assertEquals(0, zeroFrames)
        val tone = java.nio.ByteBuffer.allocateDirect(2048)
        repeat(2048) { tone.put(1) }; tone.flip()
        var calls = 0
        while (!sink.handleBuffer(tone, 1521333, 1)) assertTrue(++calls <= 6)
        assertEquals(24000, zeroFrames)
        assertEquals(1024, toneFrames)
        assertEquals(listOf(1500000L), tonePts)
    }

    @Test fun `seek flush discards partially written gap before accepting new position`() {
        val delegate = org.mockito.Mockito.mock(androidx.media3.exoplayer.audio.AudioSink::class.java)
        val format = androidx.media3.common.Format.Builder().setSampleMimeType("audio/raw")
            .setSampleRate(48000).setChannelCount(1).setPcmEncoding(androidx.media3.common.C.ENCODING_PCM_16BIT)
            .setMetadata(androidx.media3.common.Metadata(YlDashPcmWindow(YlDashTime.ZERO, YlDashTime.of(4)))).build()
        val sink = YlDashPcmAudioSink(delegate)
        sink.configure(androidx.media3.exoplayer.audio.AudioSink.AudioSinkConfig.Builder(format).build())
        sink.setOutputStreamOffsetUs(1000000); sink.resetPosition(1000000)
        val accepted = mutableListOf<Long>()
        var backpressure = true
        org.mockito.Mockito.`when`(delegate.handleBuffer(org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.anyLong(), org.mockito.ArgumentMatchers.anyInt()))
            .thenAnswer { invocation ->
                val buffer = invocation.getArgument<java.nio.ByteBuffer>(0)
                if (backpressure) { buffer.position(buffer.position() + 2); false }
                else { accepted += invocation.getArgument<Long>(1); buffer.position(buffer.limit()); true }
            }
        val old = java.nio.ByteBuffer.allocateDirect(2048)
        assertFalse(sink.handleBuffer(old, 1500000, 1))
        assertEquals(0, old.position()) // Only bounded silence was offered, content remains owned.
        sink.flush(); sink.resetPosition(2000000); backpressure = false
        assertTrue(sink.handleBuffer(java.nio.ByteBuffer.allocateDirect(2048), 2000000, 1))
        assertEquals(listOf(2000000L), accepted)
    }

    @Test fun `codec preroll is bounded without silently truncating extreme frame duration`() {
        fun format(mime: String, rate: Int) = androidx.media3.common.Format.Builder().setSampleMimeType(mime).setSampleRate(rate).build()
        assertEquals(85334L, dashAudioPrerollUs(format("audio/mp4a-latm", 48000)))
        assertEquals(8192000L, dashAudioPrerollUs(format("audio/flac", 8000)))
        assertFailsWith<IllegalArgumentException> { dashAudioPrerollUs(format("audio/flac", 4000)) }
    }

}
