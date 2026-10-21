package dev.ylplayer.yl_player_android

import android.util.Log
import java.util.UUID

/** Never inspect exception prose: removing it entirely also redacts unknown credential formats. */
internal class YlSafeDiagnostics(
    private val writeLine: (String) -> Unit = { Log.e("YlPlayer", it); Unit },
) {
    fun record(error: Throwable, httpStatus: Int? = null): String {
        val id = UUID.randomUUID().toString()
        val failure = YlFailureDescriptions.describe(error)
        val status = httpStatus?.takeIf { it in 100..599 } ?: failure.httpStatus
        // Code-owned wording only; no raw message, URI, headers or stack.
        val type = error.javaClass.simpleName.replace(Regex("[^A-Za-z0-9_$]"), "_").take(80)
        try {
            writeLine("diagnosticId=$id type=$type httpStatus=${status ?: "none"} code=${failure.code} reason=${failure.message}")
        } catch (_: Throwable) {
            // Diagnostics must never prevent cleanup or escape a generated host handler.
        }
        return id
    }
}
