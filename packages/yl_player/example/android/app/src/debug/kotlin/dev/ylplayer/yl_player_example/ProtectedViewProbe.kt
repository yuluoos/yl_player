package dev.ylplayer.yl_player_example

import android.content.Context
import android.net.Uri
import android.view.SurfaceView
import android.view.View
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File

/** Debug-only clear-content prototype. Never reports DRM or secure-decoder verification. */
class ProtectedViewProbe private constructor(private val context: Context) : PlatformViewFactory(StandardMessageCodec.INSTANCE), FlutterPlugin {
    private val players = mutableMapOf<Long, ProbePlayer>()
    private var channel: MethodChannel? = null
    companion object {
        @JvmStatic fun register(engine: FlutterEngine, context: Context) {
            engine.plugins.add(ProtectedViewProbe(context.applicationContext))
        }
    }
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
            val probe = this
            binding.platformViewRegistry.registerViewFactory("yl_player_example/protected_probe_view", probe)
            channel = MethodChannel(binding.binaryMessenger, "yl_player_example/protected_probe")
            channel!!.setMethodCallHandler { call, reply ->
                if (call.method == "reset") {
                    probe.players.values.forEach { it.dispose() }; probe.players.clear(); reply.success(null)
                    return@setMethodCallHandler
                }
                if (call.method == "count") { reply.success(probe.players.size); return@setMethodCallHandler }
                val args = call.arguments as? Map<*, *>
                val id = (args?.get("id") as? Number)?.toLong()
                if (id == null) { reply.error("probe.arguments", "Invalid probe arguments", null); return@setMethodCallHandler }
                if (call.method == "create" || call.method == "replace") {
                    val path = args["path"] as? String
                    val file = path?.let { File(it) }
                    if (file == null || !file.isAbsolute || !file.isFile || file.length() !in 1..8*1024*1024) {
                        reply.error("probe.arguments", "Expected a bounded local clear fixture", null); return@setMethodCallHandler
                    }
                    if (call.method == "create") {
                        if (probe.players.containsKey(id) || probe.players.size >= 4) {
                            reply.error("probe.capacity", "Duplicate identity or capacity reached", null); return@setMethodCallHandler
                        }
                        probe.players[id] = ProbePlayer(context, id)
                    }
                    val player = probe.players[id]
                    if (player == null) { reply.error("probe.missing", "Probe identity is no longer active", null); return@setMethodCallHandler }
                    player.replace(file); reply.success(null); return@setMethodCallHandler
                }
                val player = probe.players[id]
                if (player == null) { reply.error("probe.missing", "Probe identity is no longer active", null); return@setMethodCallHandler }
                when (call.method) {
                    "snapshot" -> reply.success(player.snapshot())
                    "dispose" -> { player.dispose(); probe.players.remove(id); reply.success(null) }
                    else -> reply.notImplemented()
                }
            }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null); channel = null
        players.values.forEach { it.dispose() }; players.clear()
    }
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val id = ((args as? Map<*, *>)?.get("id") as? Number)?.toLong()
        val owner = players[id]
        val view = SurfaceView(context)
        // Set before attaching/creating the Surface. No TextureView/virtual display fallback.
        view.setSecure(true)
        owner?.attach(view)
        return object : PlatformView {
            override fun getView(): View = view
            override fun dispose() { owner?.detach(view) }
        }
    }
    private class ProbePlayer(private val context: Context, private val id: Long) {
        private var epoch = 0
        private var readyEpoch = 0
        private var player: ExoPlayer? = null
        private var view: SurfaceView? = null
        fun replace(file: File) {
            epoch++; readyEpoch = 0
            player?.clearVideoSurface(); player?.release()
            val token = epoch
            val next = ExoPlayer.Builder(context).build()
            player = next
            next.volume = 0f
            next.addListener(object : Player.Listener {
                override fun onRenderedFirstFrame() { if (epoch == token && player === next) readyEpoch = token }
            })
            view?.let { next.setVideoSurfaceView(it) }
            next.setMediaItem(MediaItem.fromUri(Uri.fromFile(file)))
            next.prepare(); next.play()
        }
        fun attach(value: SurfaceView) {
            view = value; player?.setVideoSurfaceView(value)
        }
        fun detach(value: SurfaceView) {
            if (view !== value) return
            player?.clearVideoSurfaceView(value); view = null
        }
        fun snapshot(): Map<String, Any> = mapOf(
            "id" to id, "epoch" to epoch, "readyEpoch" to readyEpoch,
            "positionMs" to (player?.currentPosition ?: 0L),
            "width" to ((view?.width ?: 0) / context.resources.displayMetrics.density),
            "height" to ((view?.height ?: 0) / context.resources.displayMetrics.density),
            "attached" to (view != null), "pixelReadback" to false, "protectionVerified" to false, "secureRequested" to true,
        )
        fun dispose() {
            epoch++; readyEpoch = 0
            player?.clearVideoSurface(); player?.release(); player = null; view = null
        }
    }
}
