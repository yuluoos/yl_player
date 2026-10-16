package dev.ylplayer.yl_player_android

import android.media.AudioTrack
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import org.mockito.Mockito.*

/** A stalled output must not acquire consumption evidence from elapsed time. */
class YlConsumedAudioClockTest {
    @Test fun `consumption stays at the real head while programme estimate advances`() {
        val session=mock(YlFfmpegSession::class.java)
        `when`(session.configureSoftwareAudio(1)).thenReturn(true)
        val output=YlPcmAudioOutput(session,YlNativeStreamInfo(1,YlNativeStreamKind.AUDIO,YlNativeCodec.FLAC,sampleRate=48000,channelCount=2))
        val track=mock(AudioTrack::class.java)
        fun set(name:String,value:Any) {YlPcmAudioOutput::class.java.getDeclaredField(name).apply {isAccessible=true}.set(output,value)}
        set("output",track);set("firstPresentationUs",1_250_000L);set("playing",true)
        set("clockFramePosition",480L);set("clockTimestampNs",System.nanoTime()-1_000_000_000L);set("writtenFrames",96000L)
        `when`(track.playbackHeadPosition).thenReturn(480)
        check(output.positionUs()!!>2_000_000L) // Existing production estimate is deliberately unchanged.
        assertEquals(1_260_000L,output.consumedPositionUs())
        set("clockTimestampNs",System.nanoTime()-2_000_000_000L)
        assertEquals(1_260_000L,output.consumedPositionUs(),"Wall time is not consumed PCM")
        `when`(track.playbackHeadPosition).thenReturn(960)
        assertEquals(1_270_000L,output.consumedPositionUs())
        output.flush(2_250_000L)
        assertNull(output.consumedPositionUs(),"Old generation must lose its sample origin")
        output.close();assertNull(output.consumedPositionUs())
    }
}
