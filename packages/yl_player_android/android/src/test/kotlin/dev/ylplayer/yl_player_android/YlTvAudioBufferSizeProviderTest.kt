package dev.ylplayer.yl_player_android

import androidx.media3.common.C
import androidx.media3.exoplayer.audio.DefaultAudioSink
import kotlin.test.*

class YlTvAudioBufferSizeProviderTest {
    private val provider = YlTvAudioBufferSizeProvider()

    @Test fun `stereo PCM gains a small scheduling cushion without changing speed processing`() {
        assertEquals(144_000, pcm(minimum = 4096, frameSize = 4, rate = 48_000))
    }

    @Test fun `high rate multichannel audio adds at most 256 KiB in whole frames`() {
        assertEquals(1_798_144, pcm(minimum = 4096, frameSize = 16, rate = 192_000))
        val oddFrames = pcm(minimum = 4096, frameSize = 14, rate = 384_000)
        assertEquals(2_950_136, oddFrames)
        assertEquals(0, oddFrames % 14)
    }

    @Test fun `platform minimum is never reduced or needlessly inflated`() {
        assertEquals(300_000, pcm(minimum = 300_000, frameSize = 4, rate = 48_000))
        assertEquals(300_004, pcm(minimum = 300_001, frameSize = 4, rate = 48_000))
    }

    @Test fun `platform playback speed cannot multiply the additional byte allowance`() {
        val baseline = DefaultAudioSink.AudioTrackBufferSizeProvider.DEFAULT.getBufferSizeInBytes(
            4096, C.ENCODING_PCM_16BIT, DefaultAudioSink.OUTPUT_MODE_PCM, 16, 192_000, -1, 8.0)
        val actual = pcm(4096, 16, 192_000, 8.0)
        assertEquals(262_144, actual - baseline)
        assertEquals(0, actual % 16)
    }

    @Test fun `platform rate TV uses the short queue and reserves four times the minimum in whole frames`() {
        val platformRate = YlTvAudioBufferSizeProvider(platformRate = true)
        fun size(minimum: Int) = platformRate.getBufferSizeInBytes(minimum, C.ENCODING_PCM_16BIT,
            DefaultAudioSink.OUTPUT_MODE_PCM, 4, 48_000, -1, 8.0)
        assertEquals(144_000, size(18_464))
        assertEquals(160_004, size(40_001))
    }

    @Test fun `passthrough and offload sizes preserve Media3 device workarounds`() {
        for (mode in listOf(DefaultAudioSink.OUTPUT_MODE_PASSTHROUGH, DefaultAudioSink.OUTPUT_MODE_OFFLOAD)) {
            val expected = DefaultAudioSink.AudioTrackBufferSizeProvider.DEFAULT.getBufferSizeInBytes(
                4096, C.ENCODING_AC3, mode, 1, 48_000, 640_000, 1.0)
            assertEquals(expected, provider.getBufferSizeInBytes(4096, C.ENCODING_AC3, mode, 1, 48_000, 640_000, 1.0))
        }
    }

    @Test fun `only a newly configured Mi TV 3x PCM track receives the larger steady queue`() {
        var requested = false
        val provider = YlTvAudioBufferSizeProvider(platformRate = true) { requested }
        fun bytes(frameSize: Int, rate: Int) = provider.getBufferSizeInBytes(18_464, C.ENCODING_PCM_16BIT,
            DefaultAudioSink.OUTPUT_MODE_PCM, frameSize, rate, -1, 8.0)
        assertEquals(144_000, bytes(4, 48_000))
        requested = true
        assertEquals(216_000, bytes(4, 48_000))
        val base = DefaultAudioSink.AudioTrackBufferSizeProvider.DEFAULT.getBufferSizeInBytes(
            18_464 * 4, C.ENCODING_PCM_16BIT, DefaultAudioSink.OUTPUT_MODE_PCM, 16, 192_000, -1, 1.0)
        assertTrue(bytes(16, 192_000) <= base + 256 * 1024)
        requested = false
        assertEquals(144_000, bytes(4, 48_000))
    }

    private fun pcm(minimum: Int, frameSize: Int, rate: Int, speed: Double = 1.0) =
        provider.getBufferSizeInBytes(minimum, C.ENCODING_PCM_16BIT, DefaultAudioSink.OUTPUT_MODE_PCM,
            frameSize, rate, -1, speed)
}
