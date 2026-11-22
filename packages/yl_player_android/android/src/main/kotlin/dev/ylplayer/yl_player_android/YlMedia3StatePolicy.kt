package dev.ylplayer.yl_player_android

import androidx.media3.common.Player

internal object YlMedia3StatePolicy {
    fun status(currentStatus: String, playbackState: Int, isPlaying: Boolean, reachedReady: Boolean = true,
               pausedAfterPlayback: Boolean = false): String {
        if (currentStatus == "error") return currentStatus
        return when (playbackState) {
            Player.STATE_BUFFERING -> if (reachedReady) "buffering" else "opening"
            Player.STATE_READY -> when {
                isPlaying -> "playing"
                pausedAfterPlayback -> "paused"
                else -> "ready"
            }
            Player.STATE_ENDED -> "completed"
            else -> if (currentStatus == "opening") "opening" else "idle"
        }
    }

    fun readyStatus(currentStatus: String, isPlaying: Boolean): String =
        if (currentStatus == "error") currentStatus else if (isPlaying) "playing" else "paused"
}
