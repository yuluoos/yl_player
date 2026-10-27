package dev.ylplayer.yl_player_android

import android.view.Surface
import kotlinx.coroutines.*
import java.util.concurrent.atomic.AtomicLong

/** Main-owned clear-video holder; the engine acknowledges detach on its own worker. */
internal interface YlNativeOutputPort {
    suspend fun attach(surface: Surface, current: () -> Boolean)
    fun detachBeforeDestroy()
    fun failed(error: Throwable) { throw error }
}

internal class YlNativeViewBinding(dispatcher: CoroutineDispatcher = Dispatchers.Main) {
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val epoch = AtomicLong()
    private var viewId: Int? = null
    private var surface: Surface? = null
    private var owner: YlNativeOutputPort? = null
    private var released = false
    var onHidden: (() -> Unit)? = null
    var onFrame: (() -> Unit)? = null
    fun claim(id: Int): Boolean {
        if (released || viewId != null) return false
        viewId = id; return true
    }
    fun bind(port: YlNativeOutputPort) {
        if (released || owner === port) return
        owner?.let(::unbind)
        owner = port; onHidden?.invoke(); scheduleAttach()
    }
    fun unbind(port: YlNativeOutputPort) {
        if (owner !== port) return
        epoch.incrementAndGet(); onHidden?.invoke()
        port.detachBeforeDestroy()
        owner = null
    }
    fun available(id: Int, value: Surface) {
        if (released || id != viewId) return
        surface = value; epoch.incrementAndGet(); onHidden?.invoke(); scheduleAttach()
    }
    private fun scheduleAttach() {
        val port = owner ?: return
        val value = surface ?: return
        val expected = epoch.get()
        scope.launch {
            try { port.attach(value) { epoch.get() == expected } }
            catch (_: CancellationException) { }
            catch (error: Throwable) { if (epoch.get() == expected) port.failed(error) }
        }
    }
    fun destroyed(id: Int) {
        if (id != viewId || surface == null) return
        epoch.incrementAndGet(); onHidden?.invoke()
        // Never await a main coroutine here. The engine's worker barrier also
        // fences an attach already queued before this holder was destroyed.
        owner?.detachBeforeDestroy()
        surface = null
    }
    fun disposeView(id: Int) {
        if (id != viewId) return
        destroyed(id); viewId = null; onHidden = null; onFrame = null
    }
    fun frame(port: YlNativeOutputPort) { if (owner === port && surface != null) onFrame?.invoke() }
    fun release() {
        if (released) return
        viewId?.let(::destroyed)
        released = true; epoch.incrementAndGet(); owner = null; surface = null
        onHidden = null; onFrame = null; scope.cancel()
    }
}

internal class YlNativeViewRegistry {
    private val outputs = mutableMapOf<Long, YlNativeViewBinding>()
    fun register(textureId: Long) = YlNativeViewBinding().also { check(outputs.put(textureId, it) == null) }
    fun get(textureId: Long) = outputs[textureId]
    fun remove(textureId: Long) { outputs.remove(textureId)?.release() }
}
