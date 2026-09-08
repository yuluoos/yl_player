package dev.ylplayer.yl_player_android

import android.util.Log
import java.util.UUID

/** Never inspect exception prose: removing it entirely also redacts unknown credential formats. */
internal class YlSafeDiagnostics(
    private val writeLine: (String) -> Unit = { Log.e("YlPlayer", it); Unit },
) {
    fun record(error: Throwable): String {
        val id = UUID.randomUUID().toString()
        // Only code-owned type metadata is useful here; no message, cause, URI or stack is logged.
        val type = error.javaClass.simpleName.replace(Regex("[^A-Za-z0-9_$]"), "_").take(80)
        try {
            writeLine("diagnosticId=$id type=$type detail=[redacted]")
        } catch (_: Throwable) {
            // Diagnostics must never prevent cleanup or escape a generated host handler.
        }
        return id
    }
}
