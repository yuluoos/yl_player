package dev.ylplayer.yl_player_android

/** Worker-owned intent guard; ending automatic catch-up also restores its effect. */
internal class YlLiveCatchUpPolicy {
    var automaticEdgeAllowed = true
    fun absoluteSeek(requestedSpeed: Float, restoreRate: (Float) -> Unit) {
        restoreRate(requestedSpeed)
        automaticEdgeAllowed = false
    }
    fun canCatchUp(low: Boolean, playing: Boolean, active: Boolean, requestedSpeed: Float) =
        low && playing && active && automaticEdgeAllowed && requestedSpeed == 1f
}

/** RTMP has no source clock/DVR window. A new extractor epoch discards transport
 * backlog; do so only with playing intent and the shared session recovery budget. */
internal class YlRtmpLiveModePolicy {
    private var refreshPending = false
    fun paused() { refreshPending = true }
    fun refreshed() { refreshPending = false }
    fun shouldRefresh(low: Boolean, playing: Boolean, bufferedMs: Long, maxBufferMs: Int) =
        low && playing && (refreshPending || bufferedMs > maxBufferMs)
}

/** HTTP-FLV has no DVR edge. A long paused low-mode stream needs a new extractor
 * on resumed demand; short pauses and smooth playback keep their existing media. */
internal class YlHttpFlvResumePolicy {
    private var pausedAtMs: Long? = null
    fun paused(nowMs: Long) { if (pausedAtMs == null) pausedAtMs = nowMs }
    fun clear() { pausedAtMs = null }
    fun requiresRefresh(low: Boolean, live: Boolean, nowMs: Long): Boolean {
        val paused = pausedAtMs
        return low && live && paused != null && nowMs - paused >= 2000L
    }
}
