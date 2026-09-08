package dev.ylplayer.yl_player_android

import java.io.*
import java.net.*
import javax.net.ssl.SSLHandshakeException
import kotlin.test.*

class YlManagedRetryPolicyTest {
    private fun policy(retries: Int = 4, base: Long = 100, max: Long = 1000) = YlManagedRetryPolicy(NetworkConfiguration(100, 200, retries, base, max, 2)) { 0L }
    @Test fun `retry count excludes initial and exponential delay saturates without jitter`() {
        assertNull(policy(0).delay("GET", 1, 503))
        assertEquals(listOf(100L, 200L, 400L, 800L, 1000L), (1..5).map { policy(5).delay("GET", it, 503) })
        assertNull(policy().delay("GET", 5, 503))
        assertEquals(Long.MAX_VALUE, policy(Int.MAX_VALUE, Long.MAX_VALUE / 2 + 1, Long.MAX_VALUE).delay("GET", 100, 503))
    }
    @Test fun `only idempotent requests and specified statuses or transient errors retry`() {
        for (status in listOf(408,429,500,502,503,504)) assertEquals(100L, policy().delay("HEAD", 1, status))
        for (status in listOf(400,401,403,404,409,501,505)) assertNull(policy().delay("GET", 1, status))
        assertNull(policy().delay("POST", 1, 503))
        for (error in listOf(SocketTimeoutException(), ConnectException(), SocketException(), EOFException())) assertEquals(100L, policy().delay("GET", 1, error = error))
        for (error in listOf(SSLHandshakeException("private"), ProtocolException(), InterruptedIOException(), IOException("unknown"))) assertNull(policy().delay("GET", 1, error = error))
    }
    @Test fun `Retry After valid date and seconds replace backoff but excessive value refuses retry`() {
        assertEquals(1000L, policy().delay("GET", 1, 429, "1"))
        assertEquals(0L, policy().delay("GET", 1, 429, "Thu, 01 Jan 1970 00:00:00 GMT"))
        assertNull(policy().delay("GET", 1, 429, "2"))
        for (invalid in listOf("-1", "1.5", "invalid", "")) assertEquals(100L, policy().delay("GET", 1, 429, invalid))
    }
}
