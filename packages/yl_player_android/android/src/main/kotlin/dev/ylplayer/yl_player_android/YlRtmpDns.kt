package dev.ylplayer.yl_player_android

import java.net.InetAddress
import java.util.concurrent.CompletableFuture
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/** API24 getAllByName is not interruptible. Exactly two daemon slots, zero queued work.
 * A cancelled caller exits promptly, but the slot remains occupied until the OS call exits.
 * Late results are discarded, never delivered to a replacement transport. */
internal class YlRtmpDns(private val lookup: (String) -> Array<InetAddress> = InetAddress::getAllByName) {
    companion object {
        private val pool = ThreadPoolExecutor(2,2,0,TimeUnit.MILLISECONDS,SynchronousQueue<Runnable>(),
            { r -> Thread(r, "yl-rtmp-dns").apply { isDaemon = true } }, ThreadPoolExecutor.AbortPolicy())
    }
    fun resolve(host: String, check: () -> Unit): Array<InetAddress> {
        check()
        val result = CompletableFuture<Array<InetAddress>>()
        try { pool.execute { try { result.complete(lookup(host)) } catch (_: Exception) { result.completeExceptionally(YlRtmpException(YlFailureKind.RTMP_HANDSHAKE_FAILED, true)) } } }
        catch (_: java.util.concurrent.RejectedExecutionException) { rtmpLimit() }
        while (true) {
            check()
            try {
                val addresses = result.get(25, TimeUnit.MILLISECONDS)
                check()
                if (addresses.isEmpty()) throw YlRtmpException(YlFailureKind.RTMP_HANDSHAKE_FAILED, true)
                return addresses
            } catch (_: TimeoutException) { continue }
            catch (e: java.util.concurrent.ExecutionException) { throw YlRtmpException(YlFailureKind.RTMP_HANDSHAKE_FAILED, true) }
            catch (_: InterruptedException) { Thread.currentThread().interrupt(); throw YlRtmpException(YlFailureKind.LOAD_CANCELLED) }
        }
    }
}
