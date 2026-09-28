package dev.ylplayer.yl_player_android

import android.content.Context
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.widget.FrameLayout
import kotlinx.coroutines.test.*
import org.mockito.Mockito.*
import kotlin.test.*

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class YlProtectedViewTest {
    @Test fun `factory secures holder before attaching view and invalid identity remains black`() = runTest {
        val registry = YlProtectedViewRegistry(StandardTestDispatcher(testScheduler), {})
        val id = YlDrmSessionIdentity(1, 2, "one", 3)
        val binding = registry.register(id, object : YlProtectedOutputPort {
            override suspend fun attach(surface: android.view.Surface, identity: YlOutputIdentity, isCurrent: () -> Boolean) {}
            override suspend fun park() {}
            override fun detachBeforeDestroy() {}
        }) {}; binding.commit()
        val holder = mock(SurfaceHolder::class.java)
        mockConstruction(FrameLayout::class.java).use {
            mockConstruction(android.view.View::class.java).use {
                mockConstruction(SurfaceView::class.java) { view, _ -> `when`(view.holder).thenReturn(holder) }.use { surfaces ->
                    val factory = YlProtectedViewFactory(registry)
                    val context = mock(Context::class.java)
                    factory.create(context, 1, mapOf("playerId" to 1L, "surfaceId" to 2L, "sessionId" to "one", "generation" to 99L))
                    assertTrue(surfaces.constructed().isEmpty())
                    val view = factory.create(context, 2, mapOf("playerId" to 1L, "surfaceId" to 2L, "sessionId" to "one", "generation" to 3L))
                    val surface = surfaces.constructed().single()
                    val order = inOrder(surface, holder)
                    order.verify(surface).setSecure(true)
                    order.verify(holder).addCallback(any())
                    view.dispose(); verify(holder).removeCallback(any()); runCurrent()
                }
            }
        }
        binding.retire(); runCurrent()
    }
    @Test fun `native fit preserves display aspect ratio within portrait and landscape bounds`() {
        assertEquals(1080 to 608, protectedVideoSize(1080, 1920, 16.0 / 9))
        assertEquals(608 to 1080, protectedVideoSize(1920, 1080, 9.0 / 16))
        assertEquals(1280 to 720, protectedVideoSize(1280, 720, Double.NaN))
    }

}
