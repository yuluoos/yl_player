package dev.ylplayer.yl_player_android

import java.io.EOFException
import java.io.IOException
import java.net.ConnectException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.text.SimpleDateFormat
import java.text.ParsePosition
import java.util.Locale
import java.util.TimeZone
import javax.net.ssl.SSLException

/** Pure budget arithmetic. Callers increment the index only when a retry is scheduled. */
internal class YlManagedRetryPolicy(
    private val network: NetworkConfiguration,
    private val wallTimeMs: () -> Long,
) {
    fun delay(method: String, retryIndex: Int, status: Int? = null, retryAfter: String? = null, error: IOException? = null): Long? {
        if (method !in listOf("GET", "HEAD") || retryIndex !in 1..network.maxRetries) return null
        if (error != null) {
            if (generateSequence<Throwable>(error) { it.cause }.any { it is SSLException }) return null
            if (error !is SocketTimeoutException && error !is ConnectException && error !is SocketException && error !is UnknownHostException && error !is EOFException) return null
        } else if (status !in listOf(408, 429, 500, 502, 503, 504)) return null
        parseRetryAfter(retryAfter)?.let { return it.takeIf { delay -> delay <= network.maxRetryDelayMs } }
        var delay = network.baseRetryDelayMs
        repeat(minOf(retryIndex - 1, 63)) { delay = if (delay > Long.MAX_VALUE / 2) Long.MAX_VALUE else delay * 2 }
        return minOf(network.maxRetryDelayMs, delay)
    }
    private fun parseRetryAfter(raw: String?): Long? {
        val value = raw?.trim() ?: return null
        if (value.isNotEmpty() && value.all(Char::isDigit)) {
            val seconds = value.toLongOrNull() ?: return Long.MAX_VALUE
            return if (seconds > Long.MAX_VALUE / 1000) Long.MAX_VALUE else seconds * 1000
        }
        val format = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("GMT"); isLenient = false
        }
        val position = ParsePosition(0)
        val date = format.parse(value, position) ?: return null
        if (position.index != value.length) return null
        return (date.time - wallTimeMs()).coerceAtLeast(0)
    }
}
