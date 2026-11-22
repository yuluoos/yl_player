package dev.ylplayer.yl_player_android

import android.content.Context
import android.media.AudioManager
import android.os.Process
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.net.InetSocketAddress
import java.net.Socket

/** Separate test APK / UID for the public Android audio-focus integration suite. */
class YlAudioFocusPeerInstrumentedTest {
    @Suppress("DEPRECATION")
    @Test fun competeForSystemFocus() {
        val args = InstrumentationRegistry.getArguments()
        val port = args.getString("focusPort")?.toIntOrNull()
        assumeTrue("Requires the running Flutter focus suite", port != null)
        val token = requireNotNull(args.getString("focusToken"))
        require(token.matches(Regex("[a-f0-9]{32}")))
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val listener = AudioManager.OnAudioFocusChangeListener { }
        var held = false
        Socket().use { socket ->
            socket.connect(InetSocketAddress("127.0.0.1", requireNotNull(port)), 5000)
            socket.soTimeout = 60000
            val input = socket.getInputStream().bufferedReader()
            val output = socket.getOutputStream().bufferedWriter()
            fun reply(value: String) {
                output.write(value)
                output.newLine()
                output.flush()
            }
            try {
                reply("$token ${Process.myUid()} ${Process.myPid()}")
                while (true) {
                    when (val command = input.readLine()) {
                        "close" -> {
                            check(!held)
                            reply("closed")
                            return
                        }
                        "release" -> {
                            check(held)
                            assertEquals(AudioManager.AUDIOFOCUS_REQUEST_GRANTED, manager.abandonAudioFocus(listener))
                            held = false
                            reply("released")
                        }
                        "transient", "duck", "gain" -> {
                            check(!held)
                            val gain = when (command) {
                                "transient" -> AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
                                "duck" -> AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
                                else -> AudioManager.AUDIOFOCUS_GAIN
                            }
                            assertEquals(AudioManager.AUDIOFOCUS_REQUEST_GRANTED,
                                manager.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, gain))
                            held = true
                            reply("granted")
                        }
                        else -> error("Missing or unknown focus command")
                    }
                }
            } finally {
                if (held) manager.abandonAudioFocus(listener)
            }
        }
    }
}
