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

/** Must be mounted with Flutter's explicit hybrid composition (3B3). Never a
 * texture fallback. Invalid or already-claimed identities get an empty black view. */
internal class YlProtectedViewFactory(private var registry: YlProtectedViewRegistry) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    fun bind(registry: YlProtectedViewRegistry) { this.registry = registry }
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val root = FrameLayout(context)
        root.setBackgroundColor(Color.BLACK)
        val identity = decodeIdentity(args)
        val claim = identity?.let { registry.claim(it, viewId) }
        if (claim == null) return object : PlatformView {
            override fun getView(): View = root
            override fun dispose() {}
        }
        val surface = SurfaceView(context)
        surface.setSecure(true) // Before addView, holder callbacks, or any attach.
        val cover = View(context).apply { setBackgroundColor(Color.BLACK) }
        root.addView(surface, FrameLayout.LayoutParams(-1, -1))
        root.addView(cover, FrameLayout.LayoutParams(-1, -1))
        fun resize() {
            if (root.width <= 0 || root.height <= 0) return
            val g = claim.geometry
            val ratio = g?.let { it.displaySize.width * it.pixelAspectRatio / it.displaySize.height } ?: Double.NaN
            val (width, height) = protectedVideoSize(root.width, root.height, ratio)
            surface.layoutParams = FrameLayout.LayoutParams(width, height, android.view.Gravity.CENTER)
        }
        val layout = View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> resize() }
        root.addOnLayoutChangeListener(layout)
        claim.onGeometry = ::resize
        claim.onHidden = { cover.visibility = View.VISIBLE }
        claim.onFrame = { cover.visibility = View.INVISIBLE }
        val callback = object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) { claim.available(holder.surface) }
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
            override fun surfaceDestroyed(holder: SurfaceHolder) { claim.destroyed() }
        }
        surface.holder.addCallback(callback)
        return object : PlatformView {
            private var disposed = false
            override fun getView(): View = root
            override fun dispose() {
                if (disposed) return
                disposed = true
                root.removeOnLayoutChangeListener(layout)
                surface.holder.removeCallback(callback)
                claim.dispose() // Holder owns its Surface; never call Surface.release().
            }
        }
    }
    private fun decodeIdentity(args: Any?): YlDrmSessionIdentity? {
        val values = args as? Map<*, *> ?: return null
        fun number(key: String): Long? = when (val n = values[key]) { is Int -> n.toLong(); is Long -> n; else -> null }
        val player = number("playerId") ?: return null
        val surface = number("surfaceId") ?: return null
        val generation = number("generation") ?: return null
        val session = values["sessionId"] as? String ?: return null
        if (player < 0 || surface < 0 || generation < 0 || session.isEmpty() || session.length > 256) return null
        return YlDrmSessionIdentity(player, surface, session, generation)
    }
    companion object { const val TYPE = "yl_player_android/protected_video" }
}

/** Display geometry only; no decoded pixels or screenshots are read. */
internal fun protectedVideoSize(width: Int, height: Int, ratio: Double): Pair<Int, Int> {
    if (!ratio.isFinite() || ratio <= 0 || width <= 0 || height <= 0) return width to height
    return if (width.toDouble() / height > ratio) kotlin.math.round(height * ratio).toInt().coerceIn(1, width) to height
        else width to kotlin.math.round(width / ratio).toInt().coerceIn(1, height)
}
