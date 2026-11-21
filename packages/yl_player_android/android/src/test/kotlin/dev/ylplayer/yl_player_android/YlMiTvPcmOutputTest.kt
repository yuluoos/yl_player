package dev.ylplayer.yl_player_android

import android.media.AudioTrack
import androidx.media3.common.C
import androidx.media3.exoplayer.audio.AudioOutputProvider
import androidx.media3.exoplayer.audio.AudioTrackAudioOutput
import kotlin.test.assertSame
import androidx.media3.common.PlaybackParameters
import androidx.media3.exoplayer.audio.AudioOutput
import org.mockito.Mockito.*
import org.mockito.MockedStatic
import android.util.Log
import kotlin.test.BeforeTest
import kotlin.test.AfterTest
import java.nio.ByteBuffer
import kotlin.test.Test

class YlMiTvPcmOutputTest {
    private val track = mock(AudioTrack::class.java)
    private val output = mock(AudioOutput::class.java)
    private val pcm = YlMiTvPcmOutput(output, track, 4)
    private val data = ByteBuffer.allocate(8)
    private lateinit var log: MockedStatic<Log>

    @BeforeTest fun mockPlatformLogging() { log = mockStatic(Log::class.java) }
    @AfterTest fun closePlatformLogging() { log.close() }

    init {
        `when`(track.sampleRate).thenReturn(48_000)
        `when`(track.bufferSizeInFrames).thenReturn(36_000)
        `when`(track.setBufferSizeInFrames(21_600)).thenReturn(21_600)
        `when`(track.setBufferSizeInFrames(36_000)).thenReturn(36_000)
    }

    @Test fun `fresh 3x output restores the full queue when the hardware head advances`() {
        pcm.setPlaybackParameters(PlaybackParameters(3f))
        `when`(track.playbackHeadPosition).thenReturn(0, 64)
        pcm.write(data, 1, 0)
        verify(track, never()).setBufferSizeInFrames(36_000)
        pcm.write(data, 1, 100)
        pcm.write(data, 1, 200)
        verify(track).setBufferSizeInFrames(21_600)
        verify(track).setBufferSizeInFrames(36_000)
        verify(output).write(data, 1, 100)
    }

    @Test fun `a full queue waits until the driver actually accepts more PCM`() {
        pcm.setPlaybackParameters(PlaybackParameters(3f))
        `when`(track.playState).thenReturn(AudioTrack.PLAYSTATE_PLAYING)
        val buffer = ByteBuffer.allocate(21_600 * 4 + 4)
        `when`(output.write(buffer, 1, 0)).thenAnswer { false }.thenAnswer {
            buffer.position(buffer.limit() - 4)
            false
        }.thenAnswer {
            buffer.position(buffer.limit())
            true
        }
        pcm.write(buffer, 1, 0)
        pcm.write(buffer, 1, 0)
        verify(track, never()).setBufferSizeInFrames(36_000)
        pcm.write(buffer, 1, 0)
        verify(track).setBufferSizeInFrames(36_000)
    }

    @Test fun `play starts after enough decoded PCM is accepted`() {
        pcm.setPlaybackParameters(PlaybackParameters(3f))
        pcm.play()
        verify(output, never()).play()
        val chunk = ByteBuffer.allocate(10_800 * 4)
        `when`(output.write(chunk, 1, 0)).thenAnswer { chunk.position(chunk.limit()); true }
        pcm.write(chunk, 1, 0)
        verify(output, never()).play()
        chunk.rewind()
        pcm.write(chunk, 1, 0)
        verify(output).play()
    }

    @Test fun `end of a short playing stream drains the accepted tail`() {
        pcm.setPlaybackParameters(PlaybackParameters(3f))
        pcm.play()
        `when`(output.write(data, 1, 0)).thenAnswer { data.position(data.limit()); true }
        pcm.write(data, 1, 0)
        pcm.stop()
        inOrder(output).also {
            it.verify(output).play()
            it.verify(output).stop()
        }
    }

    @Test fun `pause cancels a deferred play even if another write is blocked`() {
        pcm.setPlaybackParameters(PlaybackParameters(3f))
        pcm.play()
        pcm.pause()
        pcm.write(data, 1, 0)
        pcm.flush()
        verify(output, never()).play()
    }

    @Test fun `changing speed on running output preserves its queue`() {
        pcm.setPlaybackParameters(PlaybackParameters(1.5f))
        pcm.write(data, 1, 0)
        pcm.setPlaybackParameters(PlaybackParameters(3f))
        verify(track, never()).setBufferSizeInFrames(anyInt())
    }

    @Test fun `priming covers the same playout time at other sample rates`() {
        `when`(track.sampleRate).thenReturn(44_100)
        pcm.setPlaybackParameters(PlaybackParameters(3f))
        verify(track).setBufferSizeInFrames(19_845)
    }

    @Test fun `priming preserves a smaller native queue`() {
        `when`(track.bufferSizeInFrames).thenReturn(10_000)
        pcm.setPlaybackParameters(PlaybackParameters(3f))
        verify(track, never()).setBufferSizeInFrames(anyInt())
    }

    @Test fun `rate cancellation and flush restore even before the first head update`() {
        pcm.setPlaybackParameters(PlaybackParameters(3f))
        pcm.setPlaybackParameters(PlaybackParameters.DEFAULT)
        verify(track).setBufferSizeInFrames(36_000)
        pcm.setPlaybackParameters(PlaybackParameters(3f))
        pcm.flush()
        verify(track, times(2)).setBufferSizeInFrames(36_000)
        verify(output).flush()
    }

    @Test fun `a transient restore failure is retried on the next write`() {
        `when`(track.playbackHeadPosition).thenReturn(64)
        `when`(track.setBufferSizeInFrames(36_000)).thenReturn(AudioTrack.ERROR, 36_000)
        pcm.setPlaybackParameters(PlaybackParameters(3f))
        repeat(3) { pcm.write(data, 1, 0) }
        verify(track, times(2)).setBufferSizeInFrames(36_000)
    }

    @Test fun `tunneled PCM offload and encoded outputs keep the original track`() {
        val delegate = mock(AudioOutputProvider::class.java)
        val original = mock(AudioTrackAudioOutput::class.java)
        val provider = YlMiTvAudioOutputProvider(delegate)
        val pcmConfig = AudioOutputProvider.OutputConfig.Builder().setEncoding(C.ENCODING_PCM_16BIT)
        for (config in listOf(pcmConfig.setIsTunneling(true).build(),
            pcmConfig.setIsTunneling(false).setIsOffload(true).build(),
            pcmConfig.setIsOffload(false).setEncoding(C.ENCODING_AC3).build())) {
            `when`(delegate.getAudioOutput(config)).thenReturn(original)
            assertSame(original, provider.getAudioOutput(config))
        }
        verify(original, never()).audioTrack
    }

    @Test fun `an unsupported native resize leaves the steady buffer alone`() {
        `when`(track.setBufferSizeInFrames(21_600)).thenReturn(AudioTrack.ERROR_INVALID_OPERATION)
        pcm.setPlaybackParameters(PlaybackParameters(3f))
        pcm.write(data, 1, 0)
        pcm.flush()
        verify(track, never()).setBufferSizeInFrames(36_000)
        verify(track, never()).playbackHeadPosition
    }
}
