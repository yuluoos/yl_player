package dev.ylplayer.yl_player_android

import android.app.Activity
import android.app.Application
import android.content.ComponentCallbacks2
import android.content.res.Configuration
import android.os.Bundle
import dev.ylplayer.yl_player_android.pigeon.AndroidPlayerFactoryHostApi
import io.flutter.embedding.engine.plugins.FlutterPlugin

class YlPlayerAndroidPlugin :
    FlutterPlugin,
    ComponentCallbacks2,
    Application.ActivityLifecycleCallbacks {
    private var application: Application? = null
    private var registry: YlPlayerRegistry? = null
    private var startedActivities = 0
    private val failures = YlFailureMapper()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val owner = YlPlayerRegistry(binding.binaryMessenger, binding.textureRegistry, YlMedia3SessionFactory(binding.applicationContext), failures)
        registry = owner
        try {
            application = binding.applicationContext as Application
            application?.registerComponentCallbacks(this)
            application?.registerActivityLifecycleCallbacks(this)
            AndroidPlayerFactoryHostApi.setUp(binding.binaryMessenger, owner)
        } catch (error: Throwable) {
            failures.record(error)
            onDetachedFromEngine(binding)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val owner = registry
        registry = null
        val app = application
        application = null
        startedActivities = 0
        cleanup { AndroidPlayerFactoryHostApi.setUp(binding.binaryMessenger, null) }
        cleanup { app?.unregisterComponentCallbacks(this) }
        cleanup { app?.unregisterActivityLifecycleCallbacks(this) }
        cleanup { owner?.detach() }
    }

    private inline fun cleanup(action: () -> Unit) {
        try { action() } catch (error: Throwable) { failures.record(error) }
    }

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onTrimMemory(level: Int) { registry?.onTrimMemory(level) }

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onLowMemory() { registry?.onTrimMemory(ComponentCallbacks2.TRIM_MEMORY_COMPLETE) }

    override fun onConfigurationChanged(newConfig: Configuration) { registry?.onConfigurationChanged() }

    override fun onActivityStarted(activity: Activity) {
        val wasInBackground = startedActivities == 0
        startedActivities += 1
        if (wasInBackground) registry?.onForeground()
    }

    override fun onActivityStopped(activity: Activity) {
        startedActivities = (startedActivities - 1).coerceAtLeast(0)
        if (startedActivities == 0 && !activity.isChangingConfigurations) registry?.onBackground()
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
    override fun onActivityResumed(activity: Activity) = Unit
    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit
}
