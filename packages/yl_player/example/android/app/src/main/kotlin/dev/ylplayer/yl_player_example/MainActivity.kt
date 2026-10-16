package dev.ylplayer.yl_player_example

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import android.content.Context

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The example prototype exists only in src/debug. Release has no bridge.
        // Available only in the explicitly opted-in debug acceptance build.
        val av = try { Class.forName("dev.ylplayer.yl_player_android.YlBoundFlutterProbe") }
            catch (_: ClassNotFoundException) { null }
        av?.getMethod("register", FlutterEngine::class.java, Context::class.java)
            ?.invoke(null, flutterEngine, this)
        val probe = try { Class.forName("dev.ylplayer.yl_player_example.ProtectedViewProbe") }
            catch (_: ClassNotFoundException) { null }
        probe?.getMethod("register", FlutterEngine::class.java, Context::class.java)
            ?.invoke(null, flutterEngine, this)
    }
}
