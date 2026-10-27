package dev.ylplayer.yl_player_android

import android.content.ComponentCallbacks2

/** Dispatch on the engine worker so memory notifications cannot race player operations. */
@Suppress("DEPRECATION")
internal fun handleAndroidTrimMemory(level: Int, shrink: () -> Unit, release: () -> Unit) {
    // RUNNING_CRITICAL (15) is below UI_HIDDEN (20): it must release too.
    // Compare thresholds, since Android may introduce intermediate levels.
    if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL) release()
    else if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE) shrink()
}
