package dev.ylplayer.yl_player_android

import android.content.Context
import android.os.Handler
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.audio.AudioTrackAudioOutputProvider
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.AudioRendererEventListener
import androidx.media3.exoplayer.audio.MediaCodecAudioRenderer
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.drm.DrmSessionManager
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import dev.ylplayer.yl_player_android.pigeon.AndroidMediaFormat
import org.mockito.Mockito.*
import kotlin.test.*

@Suppress("DEPRECATION")
class YlTvAudioSinkTest {
    @Test fun `production TV factory installs bounded provider and preserves audio flags`() {
        checkFactory(enabled = true)
    }

    @Test fun `ordinary factory still uses the upstream audio sink configuration`() {
        checkFactory(enabled = false)
    }

    @Test fun `core enables PCM cushion only for constrained clear non DASH televisions`() {
        for ((tv, tier) in listOf(true to YlDeviceTier.CONSTRAINED, false to YlDeviceTier.CONSTRAINED,
            true to YlDeviceTier.STANDARD)) {
            val profile = device(tv, tier)
            withCore(coreDeviceProfile = profile, factoryObserver = { factory ->
                verify(factory).useConstrainedTvAudioBuffer = tv && tier == YlDeviceTier.CONSTRAINED
            }) { _, _, _ -> }
        }
        val dash = source().copy(format = AndroidMediaFormat.DASH)
        for (drm in listOf(null, mock(DrmSessionManager::class.java))) {
            withCore(coreSource = dash, protectedDrm = drm, coreDeviceProfile = device(true, YlDeviceTier.CONSTRAINED),
                factoryObserver = { factory -> verify(factory).useConstrainedTvAudioBuffer = false }) { _, _, _ -> }
        }
    }

    @Test fun `Mi TV uses platform playback parameters for the bounded PCM sink`() {
        val delegate = mock(AudioTrackAudioOutputProvider::class.java)
        mockConstruction(AudioTrackAudioOutputProvider.Builder::class.java, withSettings().defaultAnswer(RETURNS_SELF)) { builder, _ ->
            `when`(builder.build()).thenReturn(delegate)
        }.use { outputBuilders ->
            checkFactory(enabled = true, platformRate = true)
            verify(outputBuilders.constructed().single()).setAudioTrackBufferSizeProvider(isA(YlTvAudioBufferSizeProvider::class.java))
        }
    }

    @Test fun `Mi TV feeds audio before video while preserving software fallback order`() {
        val context = mock(Context::class.java)
        val video = mock(Renderer::class.java)
        val factory = TestFactory(context)
        factory.allowEac3SoftwareAudio = true
        for (prioritizeAudio in listOf(false, true)) {
            factory.useMiTvPlatformRate = prioritizeAudio
            mockConstruction(MediaCodecAudioRenderer::class.java).use { codecs ->
                mockConstruction(YlEac3AudioRenderer::class.java).use { fallbacks ->
                    val renderers = arrayListOf(video)
                    factory.addAudio(context, renderers)
                    val audio = listOf(codecs.constructed().single(), fallbacks.constructed().single())
                    assertEquals(if (prioritizeAudio) audio + video else listOf(video) + audio, renderers)
                }
            }
        }
    }

    private fun checkFactory(enabled: Boolean, platformRate: Boolean = false) {
        val sink = mock(DefaultAudioSink::class.java)
        mockConstruction(DefaultAudioSink.Builder::class.java, withSettings().defaultAnswer(RETURNS_SELF)) { builder, _ ->
            `when`(builder.build()).thenReturn(sink)
        }.use { construction ->
            val context = mock(Context::class.java)
            val factory = TestFactory(context)
            factory.useConstrainedTvAudioBuffer = enabled
            factory.useMiTvPlatformRate = platformRate
            val actual = factory.audio(context)
            if (platformRate) assertNotNull(actual) else assertSame(sink, actual)
            val builder = construction.constructed().single()
            verify(builder).setEnableFloatOutput(false)
            verify(builder).setEnableAudioOutputPlaybackParameters(platformRate)
            if (platformRate) verify(builder).setAudioOutputProvider(isA(YlMiTvAudioOutputProvider::class.java))
            else if (enabled) verify(builder).setAudioTrackBufferSizeProvider(isA(YlTvAudioBufferSizeProvider::class.java))
            else verify(builder, never()).setAudioTrackBufferSizeProvider(any())
        }
    }

    private fun device(tv: Boolean, tier: YlDeviceTier) = YlAndroidDeviceProfile(
        YlDeviceSignals(2L * 1024 * 1024 * 1024, 128, false, 24), tier, 1920, 1080, 60.0, tv)

    private class TestFactory(context: Context) : YlOutputRenderersFactory(context,
        YlVideoOutputObserver({ it() }, { _, _, _ -> })) {
        fun audio(context: Context): AudioSink? = buildAudioSink(context, false, false)
        fun addAudio(context: Context, renderers: ArrayList<Renderer>) = buildAudioRenderers(
            context, EXTENSION_RENDERER_MODE_OFF, MediaCodecSelector.DEFAULT, true, mock(AudioSink::class.java),
            mock(Handler::class.java), mock(AudioRendererEventListener::class.java), renderers,
        )
    }
}
