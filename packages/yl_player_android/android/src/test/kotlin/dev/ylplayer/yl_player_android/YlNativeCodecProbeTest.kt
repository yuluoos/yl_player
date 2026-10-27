package dev.ylplayer.yl_player_android

import android.media.MediaCodec
import android.view.Surface
import dev.ylplayer.yl_player_android.pigeon.AndroidDecoderMode
import android.media.MediaCodecInfo
import android.media.MediaFormat
import dev.ylplayer.yl_player_android.pigeon.AndroidDecoderPolicy
import kotlin.test.Test
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
