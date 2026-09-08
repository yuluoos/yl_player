package dev.ylplayer.yl_player_android

/** Worker-owned safety ledger for pinned Media3's synchronous operation + timeout-listener API.
 * A normal Unit return is insufficient if the operation synchronously reported a timeout.
 * No subsequent operation can manufacture the missing acknowledgement of an earlier timeout.
 */
internal class YlMedia3Acknowledgement {
    var isSafe = true
        private set
    fun onTimeout() { isSafe = false }
    fun perform(operation: () -> Unit): Boolean {
        try { operation() } catch (_: Throwable) { isSafe = false }
        return isSafe
    }
}
