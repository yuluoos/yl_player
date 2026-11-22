package dev.ylplayer.yl_player_android

import android.view.Surface
import androidx.media3.common.util.Size
import java.util.WeakHashMap

/** A raw Surface passed to ExoPlayer loses its holder/texture size. Owners publish
 * actual buffer dimensions for the playback looper without retaining retired surfaces. */
internal object YlVideoSurfaceSize {
    private val sizes = WeakHashMap<Surface, Size>()
    @Synchronized fun update(surface: Surface, width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        val old = sizes[surface]
        if (old?.width != width || old.height != height) sizes[surface] = Size(width, height)
    }
    @Synchronized fun get(surface: Surface): Size? = sizes[surface]
}
