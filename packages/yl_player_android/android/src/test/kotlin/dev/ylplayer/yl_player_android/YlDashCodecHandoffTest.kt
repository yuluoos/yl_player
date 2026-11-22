package dev.ylplayer.yl_player_android

import android.media.MediaFormat
import androidx.media3.common.Format
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.*
import org.mockito.Mockito.*

class YlDashCodecHandoffTest {
    @Test fun `only legacy tunneled MStar AVC needs the AVC surface restart`() {
        assertTrue(needsLegacyTunneledAvcSurfaceRestart("OMX.MS.AVC.Decoder", true, 28))
        assertFalse(needsLegacyTunneledAvcSurfaceRestart("OMX.MS.AVC.Decoder", false, 28))
        assertFalse(needsLegacyTunneledAvcSurfaceRestart("OMX.MS.AVC.Decoder", true, 29))
        assertFalse(needsLegacyTunneledAvcSurfaceRestart("OMX.other.AVC.Decoder", true, 28))
    }
    private fun config(name: String, mime: String): MediaCodecAdapter.Configuration {
        val info = MediaCodecInfo.newInstance(name, mime, mime, null, true, false, true, false, false)
        return MediaCodecAdapter.Configuration.createForVideoDecoding(info, mock(MediaFormat::class.java),
            Format.Builder().setSampleMimeType(mime).build(), null, null)
    }

    @Test fun `successor waits for AVC release and is transferred once`() {
        val avc = config("OMX.MS.AVC.Decoder", "video/avc")
        val hevc = config("OMX.MS.HEVC.Decoder", "video/hevc")
        val old = mock(MediaCodecAdapter::class.java)
        val next = mock(MediaCodecAdapter::class.java)
        val allowRelease = CountDownLatch(1)
        val released = CountDownLatch(1)
        val started = CountDownLatch(1)
        doAnswer {
            check(allowRelease.await(3, TimeUnit.SECONDS))
            released.countDown()
            null
        }.`when`(old).release()
        val factory = YlDashCodecHandoff { incoming ->
            if (incoming === avc) old else {
                check(released.count == 0L)
                started.countDown()
                next
            }
        }
        try {
            val adapter = factory.createAdapter(avc)
            factory.switching = true
            adapter.release()
            assertFalse(factory.ready { hevc })
            assertEquals(1L, started.count)
            allowRelease.countDown()
            assertSame(next, factory.createAdapter(hevc))
        } finally {
            allowRelease.countDown()
            factory.discard()
        }
        verify(old).release()
        verify(next, never()).release()
    }

    @Test fun `discard releases an unclaimed decoder and allows a later prepare`() {
        val config = config("OMX.MS.HEVC.Decoder", "video/hevc")
        val old = mock(MediaCodecAdapter::class.java)
        val next = mock(MediaCodecAdapter::class.java)
        val candidates = ArrayDeque(listOf(old, next))
        val factory = YlDashCodecHandoff { candidates.removeFirst() }
        assertFalse(factory.ready { config })
        factory.discard()
        verify(old).release()
        assertSame(next, factory.createAdapter(config))
        factory.discard()
        verify(next, never()).release()
    }
}
