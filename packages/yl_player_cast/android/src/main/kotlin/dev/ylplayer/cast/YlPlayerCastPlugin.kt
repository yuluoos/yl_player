package dev.ylplayer.cast

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Owns only multicast reception; playback remains in the player packages. */
class YlPlayerCastPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var lock: WifiManager.MulticastLock? = null
    private var references = 0

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dev.ylplayer.cast/multicast").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "acquire" -> acquire()
                "release" -> release()
                else -> {
                    result.notImplemented()
                    return
                }
            }
            result.success(null)
        } catch (_: SecurityException) {
            result.error(
                "cast.multicast_permission",
                "Android denied Wi-Fi multicast access. Check the application's network permissions.",
                null,
            )
        } catch (_: RuntimeException) {
            result.error(
                "cast.multicast_failed",
                "The Android Wi-Fi multicast lock operation failed.",
                null,
            )
        }
    }

    private fun acquire() {
        if (references == 0) {
            val manager = context?.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                ?: throw IllegalStateException("Wi-Fi service is unavailable")
            val acquiredLock = manager.createMulticastLock("yl_player_cast").apply {
                setReferenceCounted(false)
                acquire()
            }
            lock = acquiredLock
        }
        references++
    }

    private fun release() {
        if (references == 0) return
        if (references == 1) {
            lock?.let { if (it.isHeld) it.release() }
            lock = null
        }
        references--
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        try {
            lock?.let { if (it.isHeld) it.release() }
        } catch (_: RuntimeException) {
            Log.w("YlPlayerCast", "Unable to release the multicast lock while detaching.")
        } finally {
            lock = null
            references = 0
            context = null
        }
    }
}
