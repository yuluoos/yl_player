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
    private var protectedViews: YlProtectedViewRegistry? = null
    private var nativeViews: YlNativeViewRegistry? = null
    private var registry: YlPlayerRegistry? = null
    private var startedActivities = 0
    private val failures = YlFailureMapper()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val native = YlNativeViewRegistry().also { nativeViews = it }
        val views = YlProtectedViewRegistry().also { protectedViews = it }
        val owner = YlPlayerRegistry(binding.binaryMessenger, binding.textureRegistry, YlMedia3SessionFactory(binding.applicationContext, protectedViews = views, nativeViews = native), failures, protectedViews = views, nativeViews = native)
        registry = owner
        try {
            val platformViews = binding.platformViewRegistry
            val nativeFactory = nativeFactories[platformViews]
            if (nativeFactory != null) nativeFactory.bind(native)
            else {
                val factory = YlNativeViewFactory(native)
                check(platformViews.registerViewFactory(YlNativeViewFactory.TYPE, factory))
                nativeFactories[platformViews] = factory
            }
            val registered = protectedFactories[platformViews]
            if (registered != null) registered.bind(views)
            else {
                val factory = YlProtectedViewFactory(views)
                check(platformViews.registerViewFactory(YlProtectedViewFactory.TYPE, factory)) { "Protected view type already registered" }
                protectedFactories[platformViews] = factory
            }
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
        cleanup { protectedViews?.detach(); protectedViews = null }
    }

    private companion object {
        // Flutter owns registrations for the engine lifetime, which can exceed a plugin instance.
        // Values do not reference the registry key; a collected engine is not retained here.
        val nativeFactories = java.util.WeakHashMap<io.flutter.plugin.platform.PlatformViewRegistry, YlNativeViewFactory>()
        val protectedFactories = java.util.WeakHashMap<io.flutter.plugin.platform.PlatformViewRegistry, YlProtectedViewFactory>()
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
