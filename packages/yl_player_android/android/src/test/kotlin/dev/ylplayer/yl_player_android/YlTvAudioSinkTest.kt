package dev.ylplayer.yl_player_android

import android.content.Context
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.drm.DrmSessionManager
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

    private fun checkFactory(enabled: Boolean) {
        val sink = mock(DefaultAudioSink::class.java)
        mockConstruction(DefaultAudioSink.Builder::class.java, withSettings().defaultAnswer(RETURNS_SELF)) { builder, _ ->
            `when`(builder.build()).thenReturn(sink)
        }.use { construction ->
            val context = mock(Context::class.java)
            val factory = TestFactory(context)
            factory.useConstrainedTvAudioBuffer = enabled
            assertSame(sink, factory.audio(context))
            val builder = construction.constructed().single()
            verify(builder).setEnableFloatOutput(false)
            verify(builder).setEnableAudioOutputPlaybackParameters(false)
            if (enabled) verify(builder).setAudioTrackBufferSizeProvider(isA(YlTvAudioBufferSizeProvider::class.java))
            else verify(builder, never()).setAudioTrackBufferSizeProvider(any())
        }
    }

    private fun device(tv: Boolean, tier: YlDeviceTier) = YlAndroidDeviceProfile(
        YlDeviceSignals(2L * 1024 * 1024 * 1024, 128, false, 24), tier, 1920, 1080, 60.0, tv)

    private class TestFactory(context: Context) : YlOutputRenderersFactory(context,
        YlVideoOutputObserver({ it() }, { _, _, _ -> })) {
        fun audio(context: Context): AudioSink? = buildAudioSink(context, false, false)
    }
}
