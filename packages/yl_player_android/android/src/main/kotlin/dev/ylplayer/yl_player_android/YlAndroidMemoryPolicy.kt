package dev.ylplayer.yl_player_android

import android.content.ComponentCallbacks2

/** Dispatch on the engine worker so memory notifications cannot race player operations. */
@Suppress("DEPRECATION")
internal fun handleAndroidTrimMemory(level: Int, shrink: () -> Unit, release: () -> Unit) {
    // RUNNING_CRITICAL still describes a visible app: trim non-essential buffers,
    // not the decoder required by the active load/play operation. Background and
    // onLowMemory (forwarded as COMPLETE) still release playback resources.
    // Compare thresholds, since Android may introduce intermediate levels.
    if (level >= ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN) release()
    else if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE) shrink()
}
