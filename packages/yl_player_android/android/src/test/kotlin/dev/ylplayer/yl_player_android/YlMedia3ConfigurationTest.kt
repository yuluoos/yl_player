package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import kotlin.test.Test
import kotlin.test.assertFalse

class YlMedia3ConfigurationTest {
    @Test
    fun `app managed worker configuration disables both focus and noisy handling`() {
        val source = AndroidSourceMessage(AndroidSourceKind.FILE, "/movie.mp4", AndroidStreamIntent.ON_DEMAND, AndroidMediaFormat.MP4)
        val load = AndroidLoadOptionsMessage(false, bufferStrategy = AndroidBufferStrategyMessage(AndroidBufferKind.AUTOMATIC), videoConstraints = AndroidVideoConstraintsMessage())
        val player = AndroidPlayerOptionsMessage(AndroidDecoderPolicy.SYSTEM_DEFAULT, AndroidAudioPolicy.APP_MANAGED, 250)
        // YlMedia3Core passes this same flag to Media3's handleAudioFocus and noisy handling.
        assertFalse(createMedia3Configuration(source, load, player).managesAudioSession)
    }
}
