package dev.ylplayer.yl_player_android

internal class YlFirstFrameGate {
    private var generation = Long.MIN_VALUE
    private var sent = false

    fun reset(generation: Long) {
        this.generation = generation
        sent = false
    }

    fun markRendered(generation: Long): Boolean {
        if (sent || this.generation != generation) return false
        sent = true
        return true
    }
}
