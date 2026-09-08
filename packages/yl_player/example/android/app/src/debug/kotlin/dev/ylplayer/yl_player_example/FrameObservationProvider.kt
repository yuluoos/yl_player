package dev.ylplayer.yl_player_example

import android.app.Activity
import android.app.Application
import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Surface
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.util.WeakHashMap
import java.util.concurrent.atomic.AtomicBoolean

/** Debug APK only. Read-only observation of real Media3 callbacks; never controls playback. */
class FrameObservationProvider : ContentProvider(), Application.ActivityLifecycleCallbacks {
    private val observations = WeakHashMap<Activity, FrameObservation>()
    override fun onCreate(): Boolean {
        (context!!.applicationContext as Application).registerActivityLifecycleCallbacks(this)
        return true
    }
    private fun attach(activity: Activity) {
        if (observations.containsKey(activity)) return
        if (activity !is FlutterActivity) return
        val engine = FlutterActivity::class.java.getDeclaredMethod("getFlutterEngine")
            .apply { isAccessible = true }.invoke(activity) as? FlutterEngine
        engine?.let {
            observations[activity] = FrameObservation(it)
        }
    }
    override fun onActivityDestroyed(activity: Activity) { observations.remove(activity)?.close() }
    override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
    override fun onActivityStarted(activity: Activity) = attach(activity)
    override fun onActivityResumed(activity: Activity) = Unit
    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivityStopped(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
private class FrameObservation(private val flutter: FlutterEngine) {
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(flutter.dartExecutor.binaryMessenger, "yl_player_example/debug/frame_observation")
    private var attached: Attached? = null
    @Volatile private var closed = false
    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "install" -> install(call.argument<String>("previousSession")!!, result)
                    "read" -> {
                        val current = checkNotNull(attached)
                        onWorker(current.handler, result) { current.records.toList() }
                    }
                    "remove" -> {
                        val current = attached
                        attached = null
                        if (current == null || !current.handler.looper.thread.isAlive) result.success(null)
                        else onWorker(current.handler, result) { current.player.removeAnalyticsListener(current.listener); null }
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Throwable) { result.error("observation.setup", error.javaClass.simpleName, null) }
        }
    }
    @Suppress("UNCHECKED_CAST")
    private fun install(previousSession: String, result: MethodChannel.Result) {
        check(attached == null && !closed)
        val pluginType = Class.forName("dev.ylplayer.yl_player_android.YlPlayerAndroidPlugin") as Class<out FlutterPlugin>
        val plugin = checkNotNull(flutter.plugins.get(pluginType))
        val registry = field(plugin, "registry")!!
        val hosts = (field(registry, "players") as Map<*, *>).values
        val session = hosts.map { field(it!!, "session")!! }.single {
            val active = field(it, "active")
            active != null && field(field(active, "identity")!!, "sessionId") == previousSession
        }
        val engine = checkNotNull(field(session, "candidateEngine"))
        val id = field(field(engine, "identity")!!, "sessionId") as String
        // Deferred completion safely publishes the immutable worker holder. No looper wait.
        val deferred = field(engine, "worker")!!
        val worker = deferred.javaClass.getMethod("getCompleted").apply { isAccessible = true }.invoke(deferred)
        val handler = field(worker, "handler") as Handler
        onWorker(handler, result) {
            check(!closed)
            val core = field(engine, "core")!!
            val player = field(core, "exoPlayer") as ExoPlayer
            val privateSurface = field(field(engine, "privateOutput")!!, "surface") as Surface
            val records = ArrayList<Map<String, Any>>()
            fun record(value: Map<String, Any>) {
                if (records.size < 32) records += value
                else if (records.size == 32) records += mapOf("kind" to "overflow")
            }
            var decoderSeen = false
            val listener = object : AnalyticsListener {
                override fun onVideoDecoderInitialized(time: AnalyticsListener.EventTime, name: String, initializedTimestampMs: Long, initializationDurationMs: Long) {
                    decoderSeen = true
                    record(mapOf("kind" to "decoder", "sessionId" to id, "timeMs" to initializedTimestampMs, "decoder" to name))
                }
                override fun onRenderedFirstFrame(time: AnalyticsListener.EventTime, output: Any, renderTimeMs: Long) {
                    try {
                    val book = field(core, "videoOutput")!!
                    val currentSurface = field(book, "renderSurface")
                    val identity = field(book, "identity")!!
                    record(mapOf("kind" to "frame", "sessionId" to id, "timeMs" to renderTimeMs,
                        "surfaceId" to System.identityHashCode(output), "private" to (output === privateSurface),
                        "matchesCurrentSurface" to (output === currentSurface),
                        "public" to (field(identity, "isPublic") as Boolean), "decoderSeen" to decoderSeen))
                    } catch (error: Throwable) {
                        record(mapOf("kind" to "observationError", "error" to error.javaClass.simpleName))
                    }
                }
            }
            player.addAnalyticsListener(listener)
            val value = Attached(handler, player, listener, records)
            main.post { if (closed) handler.post { player.removeAnalyticsListener(listener) } else attached = value }
            mapOf("sessionId" to id, "privateSurfaceId" to System.identityHashCode(privateSurface))
        }
    }
    private fun onWorker(handler: Handler, result: MethodChannel.Result, action: () -> Any?) {
        val completed = AtomicBoolean()
        val timeout = Runnable { if (completed.compareAndSet(false, true)) result.error("observation.timeout", "Worker observation deadline", null) }
        main.postDelayed(timeout, 3000)
        val accepted = handler.post {
            if (completed.get()) return@post
            val outcome = runCatching(action)
            main.post {
                if (completed.compareAndSet(false, true)) {
                    main.removeCallbacks(timeout)
                    outcome.fold(result::success) { result.error("observation.failed", it.javaClass.simpleName, null) }
                }
            }
        }
        if (!accepted && completed.compareAndSet(false, true)) { main.removeCallbacks(timeout); result.error("observation.released", "Worker already released", null) }
    }
    fun close() {
        closed = true
        channel.setMethodCallHandler(null)
        val current = attached
        attached = null
        current?.handler?.post { current.player.removeAnalyticsListener(current.listener) }
    }
    private data class Attached(val handler: Handler, val player: ExoPlayer, val listener: AnalyticsListener, val records: ArrayList<Map<String, Any>>)
}

private fun field(owner: Any, name: String): Any? = owner.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(owner)
