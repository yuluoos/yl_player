package dev.ylplayer.yl_player_android

import android.view.Surface
import io.flutter.view.TextureRegistry

internal class YlVideoOutput(
    private val texture: TextureRegistry.SurfaceTextureEntry,
) {
    private val tracker = YlSurfaceGeneration()
    private var surface: Surface? = Surface(texture.surfaceTexture())
    private var disposed = false

    val surfaceRebuildCount: Int
        get() = tracker.rebuildCount

    val generation: Long
        get() = tracker.generation

    fun attach(
        expectedSourceGeneration: Long,
        currentSourceGeneration: Long,
        consumer: (Surface) -> Unit,
    ): Boolean {
        val expectedSurfaceGeneration = if (surface == null) tracker.rebuild() else tracker.generation
        if (!tracker.canAttach(expectedSurfaceGeneration, expectedSourceGeneration, currentSourceGeneration)) {
            return false
        }
        val output = surface ?: Surface(texture.surfaceTexture()).also { surface = it }
        consumer(output)
        return true
    }

    fun detach(clear: (Surface) -> Unit) {
        val output = surface ?: return
        clear(output)
        output.release()
        surface = null
        tracker.invalidate()
    }

    fun rebuild(
        expectedSourceGeneration: Long,
        currentSourceGeneration: Long,
        clear: (Surface) -> Unit,
        consumer: (Surface) -> Unit,
    ): Boolean {
        surface?.let {
            clear(it)
            it.release()
            surface = null
        }
        val expectedSurfaceGeneration = tracker.rebuild()
        if (!tracker.canAttach(expectedSurfaceGeneration, expectedSourceGeneration, currentSourceGeneration)) {
            return false
        }
        val output = Surface(texture.surfaceTexture())
        surface = output
        consumer(output)
        return true
    }

    fun resize(width: Int, height: Int) {
        if (disposed || width <= 0 || height <= 0) return
        texture.surfaceTexture().setDefaultBufferSize(width, height)
    }

    fun dispose(clear: (Surface) -> Unit) {
        if (disposed || !tracker.dispose()) return
        disposed = true
        surface?.let {
            clear(it)
            it.release()
        }
        surface = null
        texture.release()
    }
}
