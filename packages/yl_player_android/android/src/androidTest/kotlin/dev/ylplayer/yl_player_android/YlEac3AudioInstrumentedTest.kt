package dev.ylplayer.yl_player_android

import androidx.media3.common.C
import androidx.media3.decoder.SimpleDecoderOutputBuffer
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer

class YlEac3AudioInstrumentedTest {
    private fun session(): YlFfmpegSession {
        val bytes = InstrumentationRegistry.getInstrumentation().context.assets
            .open("format_matrix/mkv-avc-eac3.mkv").use { it.readBytes() }
        return YlFfmpegSession.open(object : YlNativeByteSource {
            var position = 0
            override fun read(target: ByteBuffer): Int {
                val count = minOf(target.remaining(), bytes.size - position)
                target.put(bytes, position, count); position += count; return count
            }
            override fun seek(offset: Long, whence: Int): Long {
                if (whence and 0x10000 != 0) return bytes.size.toLong()
                val next = when (whence and 3) { 0 -> offset; 1 -> position + offset; 2 -> bytes.size + offset; else -> return -3 }
                if (next !in 0L..bytes.size.toLong()) return -3
                position = next.toInt(); return next
            }
            override fun cancel() {}
            override fun close() {}
        })
    }
    private fun take(decoder: YlEac3AudioDecoder): SimpleDecoderOutputBuffer {
        val deadline = System.nanoTime() + 3_000_000_000L
        while (System.nanoTime() < deadline) {
            decoder.dequeueOutputBuffer()?.let { return it }
            Thread.sleep(2)
        }
        throw AssertionError("E-AC-3 output timed out")
    }
    private fun decode(decoder: YlEac3AudioDecoder, bytes: ByteArray, time: Long): Pair<Long, ByteArray> {
        val input = requireNotNull(decoder.dequeueInputBuffer())
        input.ensureSpaceForWrite(bytes.size); requireNotNull(input.data).put(bytes)
        input.timeUs = time; input.flip(); decoder.queueInputBuffer(input)
        val output = take(decoder)
        return try { output.timeUs to ByteArray(requireNotNull(output.data).remaining()).also(requireNotNull(output.data)::get) }
        finally { output.release() }
    }
    @Test fun pcmMatchesExistingDecoderAndFlushRestoresFirstPacket() {
        session().use { reference ->
            val audio = reference.mediaInfo.streams.single { it.kind == YlNativeStreamKind.AUDIO }
            assertEquals(YlNativeCodec.EAC3, audio.codec)
            assertTrue(reference.configureSoftwareAudio(audio.index))
            val decoder = YlEac3AudioDecoder.create(audio.sampleRate, audio.channelCount)
            try {
                var count = 0; var first: ByteArray? = null; var firstPcm: ByteArray? = null
                while (count < 12) {
                    val packet = requireNotNull(reference.readPacket())
                    packet.use {
                        if (it.streamIndex == audio.index) {
                            val expected = requireNotNull(reference.decodeSoftwareAudio(it))
                            assertEquals(2, expected.channelCount)
                            val actual = decode(decoder, it.data, it.presentationTimeUs)
                            assertEquals(it.presentationTimeUs, actual.first)
                            assertArrayEquals(expected.data, actual.second)
                            if (first == null) { first = it.data.clone(); firstPcm = actual.second }
                            count++
                        }
                    }
                }
                decoder.flush()
                assertArrayEquals(firstPcm, decode(decoder, requireNotNull(first), 5_000_000L).second)
                val end = requireNotNull(decoder.dequeueInputBuffer()); end.addFlag(C.BUFFER_FLAG_END_OF_STREAM)
                decoder.queueInputBuffer(end)
                val output = take(decoder); assertTrue(output.isEndOfStream); output.release()
            } finally { decoder.release() }
        }
    }
    @Test fun nativeBoundaryRejectsInvalidShapeAndPacket() {
        assertTrue(YlFfmpegBridge.available)
        assertEquals(0L, YlFfmpegBridge.nativeCreateEac3(-1, 2))
        assertEquals(0L, YlFfmpegBridge.nativeCreateEac3(48000, 9))
        val handle = YlFfmpegBridge.nativeCreateEac3(48000, 2)
        assertTrue(handle != 0L)
        try {
            assertNull(YlFfmpegBridge.nativeDecodeEac3(handle, byteArrayOf(), false))
            assertNull(YlFfmpegBridge.nativeDecodeEac3(handle, ByteArray(1024 * 1024 + 1), false))
            assertNull(YlFfmpegBridge.nativeDecodeEac3(handle, byteArrayOf(1, 2, 3), true))
        } finally { YlFfmpegBridge.nativeCloseEac3(handle) }
    }
}
