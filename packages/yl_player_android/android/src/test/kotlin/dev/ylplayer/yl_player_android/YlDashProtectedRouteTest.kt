package dev.ylplayer.yl_player_android

import android.content.Context
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.dash.DashMediaSource
import androidx.media3.exoplayer.drm.DrmSessionManager
import androidx.media3.exoplayer.drm.DrmSessionManagerProvider
import dev.ylplayer.yl_player_android.pigeon.AndroidMediaFormat
import org.mockito.ArgumentCaptor
import org.mockito.Mockito.*
import kotlin.test.*

class YlDashProtectedRouteTest {
    @Test fun `protected DASH does not enter clear programme output transforms`() {
        withCore(coreSource = source().copy(format = AndroidMediaFormat.DASH), protectedDrm = mock(DrmSessionManager::class.java)) { core, _, _ ->
            assertNull(core.outputObserver.dashVideoFamily)
        }
    }

    @Test fun `protected DASH retains original source route and supplied DRM manager`() {
        val drm = mock(DrmSessionManager::class.java)
        withCore(coreSource = source().copy(format = AndroidMediaFormat.DASH), protectedDrm = drm) { core, _, _ ->
            val expected = mock(DashMediaSource::class.java)
            mockConstruction(DashMediaSource.Factory::class.java, withSettings().defaultAnswer(RETURNS_SELF)) { factory, _ ->
                `when`(factory.createMediaSource(any(MediaItem::class.java))).thenReturn(expected)
            }.use { factories ->
                val uri = mock(Uri::class.java)
                `when`(uri.path).thenReturn("/protected.mpd")
                val item = MediaItem.Builder().setUri(uri).setMimeType("application/dash+xml").build()
                val factory = core.javaClass.getDeclaredField("sourceFactory").apply { isAccessible = true }.get(core) as YlMediaSourceFactory
                assertSame(expected, factory.create(mock(Context::class.java), item))
                val provider = ArgumentCaptor.forClass(DrmSessionManagerProvider::class.java)
                verify(factories.constructed().single()).setDrmSessionManagerProvider(provider.capture())
                assertSame(drm, provider.value.get(item))
            }
        }
    }
}
