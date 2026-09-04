package dev.ylplayer.yl_player_android

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Process
import android.util.DisplayMetrics
import android.view.WindowManager

internal data class YlAndroidDeviceProfile(
    val signals: YlDeviceSignals,
    val tier: YlDeviceTier,
    val displayWidth: Int?,
    val displayHeight: Int?,
    val displayRefreshRate: Double?,
) {
    val videoEnvelope: YlVideoEnvelope
        get() = videoEnvelope(tier, displayWidth, displayHeight, displayRefreshRate)

    companion object {
        @Suppress("DEPRECATION")
        fun collect(context: Context): YlAndroidDeviceProfile {
            val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            val memoryInfo = activityManager?.let {
                ActivityManager.MemoryInfo().also(it::getMemoryInfo)
            }
            val signals = YlDeviceSignals(
                totalMemoryBytes = memoryInfo?.totalMem?.takeIf { it > 0 },
                memoryClassMb = activityManager?.memoryClass ?: 0,
                is64Bit = Process.is64Bit(),
                apiLevel = Build.VERSION.SDK_INT,
            )
            val windowManager = context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
            val display = windowManager?.defaultDisplay
            val metrics = display?.let {
                DisplayMetrics().also(it::getRealMetrics)
            }
            return YlAndroidDeviceProfile(
                signals = signals,
                tier = YlPlaybackPolicy.classifyDevice(signals),
                displayWidth = metrics?.widthPixels?.takeIf { it > 0 },
                displayHeight = metrics?.heightPixels?.takeIf { it > 0 },
                displayRefreshRate = display?.refreshRate?.toDouble()?.takeIf { it > 0.0 },
            )
        }
    }
}
