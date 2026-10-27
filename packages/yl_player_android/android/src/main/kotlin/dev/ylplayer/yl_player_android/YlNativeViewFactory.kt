package dev.ylplayer.yl_player_android

import android.content.Context
import android.graphics.Color
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/** Explicit hybrid composition keeps TV sideband video beneath Flutter controls. */
internal class YlNativeViewFactory(private var registry: YlNativeViewRegistry) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    fun bind(registry: YlNativeViewRegistry) { this.registry = registry }
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val root = FrameLayout(context)
        root.setBackgroundColor(Color.BLACK)
        val textureId = when (val value = (args as? Map<*, *>)?.get("textureId")) {
            is Int -> value.toLong()
            is Long -> value
            else -> null
        }
        val binding = textureId?.let(registry::get)?.takeIf { it.claim(viewId) }
        if (binding == null) return object : PlatformView {
            override fun getView(): View = root
            override fun dispose() {}
        }
        val video = SurfaceView(context)
        val cover = View(context).apply { setBackgroundColor(Color.BLACK) }
        root.addView(video, FrameLayout.LayoutParams(-1, -1))
        root.addView(cover, FrameLayout.LayoutParams(-1, -1))
        binding.onHidden = { cover.visibility = View.VISIBLE }
        binding.onFrame = { cover.visibility = View.INVISIBLE }
        val callback = object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) { binding.available(viewId, holder.surface) }
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
            override fun surfaceDestroyed(holder: SurfaceHolder) { binding.destroyed(viewId) }
        }
        video.holder.addCallback(callback)
        return object : PlatformView {
            private var disposed = false
            override fun getView(): View = root
            override fun dispose() {
                if (disposed) return
                disposed = true
                video.holder.removeCallback(callback)
                binding.disposeView(viewId) // Surface belongs to the holder.
            }
        }
    }
    companion object { const val TYPE = "yl_player_android/native_video" }
}
