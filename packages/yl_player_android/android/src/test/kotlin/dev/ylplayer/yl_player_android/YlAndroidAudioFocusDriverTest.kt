package dev.ylplayer.yl_player_android

import android.content.*
import android.media.*
import android.os.Handler
import org.mockito.Mockito.*
import org.mockito.ArgumentCaptor
import kotlin.test.*

@Suppress("DEPRECATION")
class YlAndroidAudioFocusDriverTest {
    @Test fun `real callbacks pause modern duck requests and duck legacy requests on main handler`() {
        for (api in listOf(24, 26)) {
            val app = mock(Context::class.java); val manager = mock(AudioManager::class.java); val handler = mock(Handler::class.java)
            `when`(app.getSystemService(Context.AUDIO_SERVICE)).thenReturn(manager)
            val queued = mutableListOf<Runnable>()
            doAnswer { queued += it.getArgument<Runnable>(0); true }.`when`(handler).post(any(Runnable::class.java))
            val request = mock(AudioFocusRequest::class.java); val attributes = mock(AudioAttributes::class.java)
            mockConstruction(AudioAttributes.Builder::class.java, withSettings().defaultAnswer(RETURNS_SELF)) { b, _ -> `when`(b.build()).thenReturn(attributes) }.use {
                mockConstruction(AudioFocusRequest.Builder::class.java, withSettings().defaultAnswer(RETURNS_SELF)) { b, _ -> `when`(b.build()).thenReturn(request) }.use { requests ->
                    `when`(manager.requestAudioFocus(request)).thenReturn(AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
                    `when`(manager.requestAudioFocus(any(), anyInt(), anyInt())).thenReturn(AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
                    val changes = mutableListOf<YlAudioFocusChange>()
                    val driver = YlAndroidAudioFocusDriver(app, api, handler)
                    assertTrue(driver.request(changes::add))
                    val capture = ArgumentCaptor.forClass(AudioManager.OnAudioFocusChangeListener::class.java)
                    if (api >= 26) { verify(requests.constructed().single()).setOnAudioFocusChangeListener(capture.capture(), eq(handler)); Unit }
                    else { verify(manager).requestAudioFocus(capture.capture(), anyInt(), anyInt()); Unit }
                    capture.value.onAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)
                    capture.value.onAudioFocusChange(AudioManager.AUDIOFOCUS_GAIN)
                    assertTrue(changes.isEmpty())
                    queued.forEach(Runnable::run)
                    assertEquals(listOf(if (api >= 26) YlAudioFocusChange.LOSS_TRANSIENT else YlAudioFocusChange.DUCK, YlAudioFocusChange.GAIN), changes)
                    driver.abandon()
                }
            }
        }
    }
    @Test fun `API24 honors real grant result and abandons only granted legacy request`() {
        val app = mock(Context::class.java)
        val manager = mock(AudioManager::class.java)
        `when`(app.getSystemService(Context.AUDIO_SERVICE)).thenReturn(manager)
        val driver = YlAndroidAudioFocusDriver(app, 24, mock(Handler::class.java))
        assertFalse(driver.request { })
        driver.abandon()
        verify(manager, never()).abandonAudioFocus(any())
        `when`(manager.requestAudioFocus(any(), eq(AudioManager.STREAM_MUSIC), eq(AudioManager.AUDIOFOCUS_GAIN))).thenReturn(AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
        assertTrue(driver.request { })
        driver.abandon(); driver.abandon()
        verify(manager, times(2)).requestAudioFocus(any(), eq(AudioManager.STREAM_MUSIC), eq(AudioManager.AUDIOFOCUS_GAIN))
        verify(manager).abandonAudioFocus(any())
    }
    @Test fun `API26 uses media attributes explicit duck callbacks no delayed focus and same request for abandon`() {
        val app = mock(Context::class.java); val manager = mock(AudioManager::class.java)
        `when`(app.getSystemService(Context.AUDIO_SERVICE)).thenReturn(manager)
        val request = mock(AudioFocusRequest::class.java)
        val attributes = mock(AudioAttributes::class.java)
        mockConstruction(AudioAttributes.Builder::class.java, withSettings().defaultAnswer(RETURNS_SELF)) { builder, _ ->
            `when`(builder.build()).thenReturn(attributes)
        }.use { attrs ->
            mockConstruction(AudioFocusRequest.Builder::class.java, withSettings().defaultAnswer(RETURNS_SELF)) { builder, _ ->
                `when`(builder.build()).thenReturn(request)
            }.use { requests ->
                val driver = YlAndroidAudioFocusDriver(app, 26, mock(Handler::class.java))
                `when`(manager.requestAudioFocus(request)).thenReturn(AudioManager.AUDIOFOCUS_REQUEST_DELAYED)
                assertFalse(driver.request { }); driver.abandon()
                verify(manager, never()).abandonAudioFocusRequest(any())
                `when`(manager.requestAudioFocus(request)).thenReturn(AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
                assertTrue(driver.request { })
                requests.constructed().forEach { builder ->
                    verify(builder).setWillPauseWhenDucked(true)
                    verify(builder).setAcceptsDelayedFocusGain(false)
                    verify(builder).setAudioAttributes(attributes)
                }
                attrs.constructed().forEach { builder ->
                    verify(builder).setUsage(AudioAttributes.USAGE_MEDIA)
                    verify(builder).setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                }
                driver.abandon(); driver.abandon()
                verify(manager).abandonAudioFocusRequest(request)
            }
        }
    }
    @Test fun `one application noisy receiver delivers only matching action then unregisters once`() {
        val app = mock(Context::class.java); val handler = mock(Handler::class.java)
        mockConstruction(IntentFilter::class.java).use {
            val driver = YlAndroidAudioFocusDriver(app, 33, handler)
            var noisy = 0
            driver.registerNoisy { noisy++ }; driver.registerNoisy { noisy++ }
            val receiver = ArgumentCaptor.forClass(BroadcastReceiver::class.java)
            verify(app).registerReceiver(receiver.capture(), any(IntentFilter::class.java), isNull(), eq(handler), eq(Context.RECEIVER_NOT_EXPORTED))
            val intent = mock(Intent::class.java)
            `when`(intent.action).thenReturn("unrelated")
            receiver.value.onReceive(app, intent); assertEquals(0, noisy)
            `when`(intent.action).thenReturn(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
            receiver.value.onReceive(app, intent); assertEquals(1, noisy)
            driver.unregisterNoisy(); driver.unregisterNoisy()
            verify(app).unregisterReceiver(receiver.value)
        }
    }
}
