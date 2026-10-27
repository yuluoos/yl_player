package dev.ylplayer.yl_player_android

import androidx.media3.common.*
import kotlin.test.*
import org.mockito.Mockito.*

class YlEac3AudioRendererTest {
    private fun format(mime: String = MimeTypes.AUDIO_E_AC3, rate: Int = 48000, channels: Int = 6) =
        Format.Builder().setSampleMimeType(mime).setSampleRate(rate).setChannelCount(channels).build()
    @Test fun `only bounded clear EAC3 reaches the existing software decoder`() {
        mockStatic(android.text.TextUtils::class.java) { call ->
            if (call.method.name == "isEmpty") (call.arguments[0] as? CharSequence).isNullOrEmpty() else call.callRealMethod()
        }.use {
            assertTrue(YlEac3AudioRenderer.accepts(format()))
            assertTrue(YlEac3AudioRenderer.accepts(format(rate = 44100, channels = 2)))
            assertFalse(YlEac3AudioRenderer.accepts(format(MimeTypes.AUDIO_AAC)))
            assertFalse(YlEac3AudioRenderer.accepts(format(MimeTypes.AUDIO_E_AC3_JOC)))
            assertFalse(YlEac3AudioRenderer.accepts(format(rate = -1)))
            assertFalse(YlEac3AudioRenderer.accepts(format(rate = 192000)))
            assertFalse(YlEac3AudioRenderer.accepts(format(channels = 9)))
            assertFalse(YlEac3AudioRenderer.accepts(format().buildUpon().setCryptoType(C.CRYPTO_TYPE_FRAMEWORK).build()))
        }
    }
}
