package dev.ylplayer.yl_player_android

import android.media.MediaCodec
import android.view.Surface
import dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode
import android.media.MediaCodecInfo
import android.media.MediaFormat
import dev.ylplayer.yl_player_android.pigeon.AndroidDecoderPolicy
import java.nio.ByteBuffer
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertFailsWith
import org.mockito.Mockito.*

class YlNativeCodecProbeTest {
    private val stream = YlNativeStreamInfo(0, YlNativeStreamKind.VIDEO,
        YlNativeCodec.HEVC, 3840, 2160, 25.0, profile = 2)

    @Test fun `preferred legacy vendor can decode native 4K HEVC without strict hardware proof`() {
        assertEquals("OMX.MS.HEVC.Decoder", probe(AndroidDecoderPolicy.HARDWARE_PREFERRED))
        assertNull(probe(AndroidDecoderPolicy.HARDWARE_REQUIRED))
    }

    @Test fun `legacy software names and unsupported Main10 profiles stay rejected`() {
        assertNull(probe(AndroidDecoderPolicy.HARDWARE_PREFERRED, name = "OMX.google.hevc.decoder"))
        assertNull(probe(AndroidDecoderPolicy.HARDWARE_PREFERRED, main10 = false))
        assertNull(probe(AndroidDecoderPolicy.HARDWARE_PREFERRED, formatSupported = false))
    }

    @Test fun `initialized legacy vendor retains unknown evidence and strict mode releases rejected codec`() {
        withInitializedCodec("OMX.MS.HEVC.Decoder") { codec ->
            YlHardwareVideoDecoder(stream, mock(Surface::class.java), "candidate", byteArrayOf(),
                decoderPolicy = AndroidDecoderPolicy.HARDWARE_PREFERRED).use { decoder ->
                assertEquals(AndroidDecoderMode.UNKNOWN, decoder.decoderMode)
                assertEquals("OMX.MS.HEVC.Decoder", decoder.decoderIdentity)
                verify(codec).start()
            }
            verify(codec).release()
        }
        withInitializedCodec("OMX.MS.HEVC.Decoder") { codec ->
            assertFailsWith<YlBoundaryException> {
                YlHardwareVideoDecoder(stream, mock(Surface::class.java), "candidate", byteArrayOf(),
                    decoderPolicy = AndroidDecoderPolicy.HARDWARE_REQUIRED)
            }
            verify(codec, never()).start()
            verify(codec).release()
        }
    }

    @Test fun `actual software codec is rejected even when discovery returned a vendor candidate`() {
        withInitializedCodec("OMX.google.hevc.decoder") { codec ->
            assertFailsWith<YlBoundaryException> {
                YlHardwareVideoDecoder(stream, mock(Surface::class.java), "candidate", byteArrayOf(),
                    decoderPolicy = AndroidDecoderPolicy.HARDWARE_PREFERRED)
            }
            verify(codec, never()).start()
            verify(codec).release()
        }
    }

    @Test fun `only the known pre-29 HEVC codec needs a surface restart`() {
        for (api in 24..28) assertTrue(needsLegacyHevcSurfaceRestart("OMX.MS.HEVC.Decoder", api))
        for (api in 29..36) assertFalse(needsLegacyHevcSurfaceRestart("OMX.MS.HEVC.Decoder", api))
        assertFalse(needsLegacyHevcSurfaceRestart("OMX.MS.AVC.Decoder", 24))
        assertFalse(needsLegacyHevcSurfaceRestart("c2.mtk.hevc.decoder", 28))
    }

    @Test fun `legacy surface change restarts with CSD and waits for a sync sample`() {
        withInitializedCodec("OMX.MS.HEVC.Decoder") { codec ->
            val old = mock(Surface::class.java)
            val next = mock(Surface::class.java)
            val csd = byteArrayOf(0, 0, 0, 1, 64, 1)
            YlHardwareVideoDecoder(stream, old, "candidate", csd,
                decoderPolicy = AndroidDecoderPolicy.HARDWARE_PREFERRED).use { decoder ->
                assertTrue(decoder.replaceSurface(next, 1000) { needsLegacyHevcSurfaceRestart(it, 28) })
                val order = inOrder(codec)
                order.verify(codec).configure(any(MediaFormat::class.java), eq(old), isNull(), eq(0))
                order.verify(codec).start()
                order.verify(codec).stop()
                val format = org.mockito.ArgumentCaptor.forClass(MediaFormat::class.java)
                order.verify(codec).configure(format.capture(), eq(next), isNull(), eq(0))
                verify(format.value, atLeastOnce()).setByteBuffer("csd-0", ByteBuffer.wrap(csd))
                order.verify(codec).start()
                verify(codec, never()).setOutputSurface(any())
                val delta = YlNativePacket(0, byteArrayOf(1), 400, 400, 40, false)
                assertFalse(decoder.consume(delta))
                assertFalse(decoder.finish())
                verify(codec, never()).dequeueInputBuffer(anyLong())
                `when`(codec.dequeueOutputBuffer(any(), anyLong())).thenReturn(MediaCodec.INFO_TRY_AGAIN_LATER)
                `when`(codec.getInputBuffer(0)).thenReturn(ByteBuffer.allocate(64))
                decoder.consume(delta.copy(keyFrame = true))
                verify(codec).queueInputBuffer(0, 0, 1, 400, MediaCodec.BUFFER_FLAG_KEY_FRAME)
            }
            verify(codec).release()
        }
    }

    @Test fun `failed legacy reconfigure releases codec without a direct surface retry`() {
        withInitializedCodec("OMX.MS.HEVC.Decoder") { codec ->
            val next = mock(Surface::class.java)
            doThrow(IllegalStateException("reconfigure failed")).`when`(codec)
                .configure(any(MediaFormat::class.java), eq(next), isNull(), eq(0))
            assertFailsWith<IllegalStateException> {
                YlHardwareVideoDecoder(stream, mock(Surface::class.java), "candidate", byteArrayOf(),
                    decoderPolicy = AndroidDecoderPolicy.HARDWARE_PREFERRED).use { decoder ->
                    decoder.replaceSurface(next, 0) { needsLegacyHevcSurfaceRestart(it, 24) }
                }
            }
            verify(codec, never()).setOutputSurface(any())
            verify(codec).start()
            verify(codec).stop()
            verify(codec).release()
        }
    }

    @Test fun `other vendor codec switches surfaces without interrupting decode`() {
        withInitializedCodec("OMX.vendor.hevc.decoder") { codec ->
            val next = mock(Surface::class.java)
            YlHardwareVideoDecoder(stream, mock(Surface::class.java), "candidate", byteArrayOf(),
                decoderPolicy = AndroidDecoderPolicy.HARDWARE_PREFERRED).use { decoder ->
                assertFalse(decoder.replaceSurface(next, 0) { needsLegacyHevcSurfaceRestart(it, 28) })
                verify(codec).setOutputSurface(next)
                verify(codec, never()).stop()
            }
        }
    }

    private fun withInitializedCodec(name: String, block: (MediaCodec) -> Unit) {
        val codec = mock(MediaCodec::class.java)
        val info = mock(MediaCodecInfo::class.java)
        `when`(codec.name).thenReturn(name)
        `when`(info.name).thenReturn(name)
        `when`(codec.codecInfo).thenReturn(info)
        mockStatic(MediaCodec::class.java).use { codecs ->
            codecs.`when`<MediaCodec> { MediaCodec.createByCodecName("candidate") }.thenReturn(codec)
            mockStatic(MediaFormat::class.java).use { formats ->
                formats.`when`<MediaFormat> { MediaFormat.createVideoFormat("video/hevc", 3840, 2160) }
                    .thenReturn(mock(MediaFormat::class.java))
                block(codec)
            }
        }
    }

    private fun probe(policy: AndroidDecoderPolicy, name: String = "OMX.MS.HEVC.Decoder",
        main10: Boolean = true, formatSupported: Boolean = true): String? {
        val format = mock(MediaFormat::class.java)
        val codec = mock(MediaCodecInfo::class.java)
        val capabilities = mock(MediaCodecInfo.CodecCapabilities::class.java)
        capabilities.profileLevels = arrayOf(MediaCodecInfo.CodecProfileLevel().apply {
            profile = if (main10) MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10
                else MediaCodecInfo.CodecProfileLevel.HEVCProfileMain
            level = MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel51
        })
        `when`(codec.name).thenReturn(name)
        `when`(codec.supportedTypes).thenReturn(arrayOf("video/hevc"))
        `when`(codec.getCapabilitiesForType("video/hevc")).thenReturn(capabilities)
        `when`(capabilities.isFormatSupported(format)).thenReturn(formatSupported)
        return mockStatic(MediaFormat::class.java).use { factory ->
            factory.`when`<MediaFormat> { MediaFormat.createVideoFormat("video/hevc", 3840, 2160) }.thenReturn(format)
            YlHardwareCodecProbe.findVideoDecoder(stream, policy, 28) { arrayOf(codec) }
        }
    }
}
