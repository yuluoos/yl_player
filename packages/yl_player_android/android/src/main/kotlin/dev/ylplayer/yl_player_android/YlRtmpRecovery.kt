package dev.ylplayer.yl_player_android

/** Session lifetime ledger. Successful first frame never replenishes this budget. */
internal class YlRtmpRecovery {
    @Volatile var committed = false
    var attempts = 0; private set
    var epoch = 0L; private set
    fun invalidate(): Long = ++epoch
    fun accepts(value: Long) = value == epoch
    fun canRecover(kind: YlFailureKind, transient: Boolean) = committed && transient &&
        kind in setOf(YlFailureKind.RTMP_HANDSHAKE_FAILED, YlFailureKind.RTMP_DISCONNECTED) && attempts < 3
    fun next(kind: YlFailureKind, transient: Boolean): Long? {
        if (!canRecover(kind, transient)) return null
        return longArrayOf(500,1000,2000)[attempts++]
    }
}
