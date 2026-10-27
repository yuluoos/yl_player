package dev.ylplayer.yl_player_android

import android.view.Surface
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.mockito.Mockito.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class YlNativeViewBindingTest {
    private class Port : YlNativeOutputPort {
        var attaches = 0
        var detaches = 0
        var guard: (() -> Boolean)? = null
        override suspend fun attach(surface: Surface, current: () -> Boolean) { attaches++; guard = current }
        override fun detachBeforeDestroy() { detaches++ }
    }
    @Test fun `destroy fences late attachment and acknowledges detach before returning`() = runTest {
        val binding = YlNativeViewBinding(StandardTestDispatcher(testScheduler))
        val port = Port(); binding.bind(port)
        assertTrue(binding.claim(1))
        binding.available(1, mock(Surface::class.java)); runCurrent()
        assertEquals(1, port.attaches); assertTrue(port.guard?.invoke() == true)
        binding.destroyed(1)
        assertEquals(1, port.detaches); assertFalse(port.guard?.invoke() == true)
        binding.available(1, mock(Surface::class.java)); runCurrent()
        assertEquals(2, port.attaches)
        binding.release(); assertEquals(2, port.detaches)
    }
    @Test fun `stale owner and view cannot detach replacement or reveal an old frame`() = runTest {
        val binding = YlNativeViewBinding(StandardTestDispatcher(testScheduler))
        val old = Port(); val next = Port()
        binding.bind(old); assertTrue(binding.claim(4)); assertFalse(binding.claim(5))
        binding.available(4, mock(Surface::class.java)); runCurrent()
        var shown = 0; binding.onFrame = { shown++ }
        binding.bind(next); runCurrent()
        binding.unbind(old); binding.frame(old); assertEquals(0, shown)
        binding.frame(next); assertEquals(1, shown)
        binding.destroyed(3); assertEquals(0, next.detaches)
        binding.disposeView(4); assertEquals(1, next.detaches)
        assertTrue(binding.claim(5)); binding.release()
    }
}
