package dev.ylplayer.yl_player_android

import android.app.Activity
import android.app.Application
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

class YlPlayerAndroidPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ComponentCallbacks2,
    Application.ActivityLifecycleCallbacks {
    private lateinit var application: Application
    private lateinit var applicationContext: Context
    private lateinit var textures: TextureRegistry
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private val players = mutableMapOf<Long, YlMedia3Player>()
    private var nextPlayerId = 1L
    private var eventSink: EventChannel.EventSink? = null
    private var startedActivities = 0
    private var activePlayerId: Long? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        application = applicationContext as Application
        application.registerComponentCallbacks(this)
        application.registerActivityLifecycleCallbacks(this)
        textures = binding.textureRegistry
        methodChannel = MethodChannel(
            binding.binaryMessenger,
            "dev.ylplayer.yl_player_android/methods",
        )
        eventChannel = EventChannel(
            binding.binaryMessenger,
            "dev.ylplayer.yl_player_android/events",
        )
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink = null
        application.unregisterComponentCallbacks(this)
        application.unregisterActivityLifecycleCallbacks(this)
        players.values.toList().forEach(YlMedia3Player::dispose)
        players.clear()
        activePlayerId = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
        players.values.forEach(YlMedia3Player::emitState)
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> createPlayer(call, result)
            "command" -> runCommand(call, result)
            "dispose" -> disposePlayer(call, result)
            else -> result.notImplemented()
        }
    }

    private fun createPlayer(call: MethodCall, result: MethodChannel.Result) {
        var texture: TextureRegistry.SurfaceTextureEntry? = null
        try {
            val arguments = call.arguments.asStringMap()
            val configuration = PlayerConfiguration.from(arguments["configuration"].asStringMap())
            val playerId = nextPlayerId++
            texture = textures.createSurfaceTexture()
            val player = YlMedia3Player(
                context = applicationContext,
                playerId = playerId,
                texture = texture,
                configuration = configuration,
                emit = ::emit,
            )
            players[playerId] = player
            result.success(mapOf("playerId" to playerId, "textureId" to texture.id()))
        } catch (error: Throwable) {
            texture?.release()
            result.playerError("android.create_failed", "Could not create Media3 player.", error)
        }
    }

    private fun runCommand(call: MethodCall, result: MethodChannel.Result) {
        val root = call.arguments.asStringMap()
        val playerId = (root["playerId"] as? Number)?.toLong()
        val player = playerId?.let(players::get)
        if (player == null) {
            result.error(
                "android.player_missing",
                "The requested Android player does not exist.",
                errorMap("resource", "android.player_missing", "Player was already released."),
            )
            return
        }
        try {
            val commandName = root["name"] as? String ?: ""
            if (commandName == "open") {
                player.validateOpen(root["arguments"].asStringMap()["source"].asStringMap())
            }
            if (commandName == "open" || commandName == "play") {
                players.values.filter { it !== player }.forEach(YlMedia3Player::deactivate)
                activePlayerId = playerId
                player.activate()
            }
            player.command(commandName, root["arguments"].asStringMap())
            result.success(null)
        } catch (error: PlayerCommandException) {
            result.error(error.code, error.message, error.details)
        } catch (error: Throwable) {
            result.playerError("android.command_failed", "Media3 command failed.", error)
        }
    }

    private fun disposePlayer(call: MethodCall, result: MethodChannel.Result) {
        val playerId = (call.arguments.asStringMap()["playerId"] as? Number)?.toLong()
        if (playerId != null) {
            players.remove(playerId)?.dispose()
            if (activePlayerId == playerId) activePlayerId = null
        }
        result.success(null)
    }

    private fun emit(event: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            eventSink?.success(event)
        } else {
            Handler(Looper.getMainLooper()).post { eventSink?.success(event) }
        }
    }

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onTrimMemory(level: Int) {
        val activePlayer = activePlayerId?.let(players::get)
        when {
            level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL ->
                activePlayer?.releaseForLifecycle()
            level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE ->
                activePlayer?.handleRunningLowMemory()
        }
    }

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onLowMemory() {
        activePlayerId?.let(players::get)?.releaseForLifecycle()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        activePlayerId?.let(players::get)?.rebuildVideoOutput()
    }

    override fun onActivityStarted(activity: Activity) {
        val wasInBackground = startedActivities == 0
        startedActivities += 1
        if (wasInBackground) activePlayerId?.let(players::get)?.restoreAfterForeground()
    }

    override fun onActivityStopped(activity: Activity) {
        startedActivities = (startedActivities - 1).coerceAtLeast(0)
        if (startedActivities == 0 && !activity.isChangingConfigurations) {
            activePlayerId?.let(players::get)?.releaseForLifecycle()
        }
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
    override fun onActivityResumed(activity: Activity) = Unit
    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit
}
private fun MethodChannel.Result.playerError(
    code: String,
    message: String,
    error: Throwable,
) {
    error(
        code,
        message,
        errorMap("internal", code, message, error.stackTraceToString()),
    )
}
