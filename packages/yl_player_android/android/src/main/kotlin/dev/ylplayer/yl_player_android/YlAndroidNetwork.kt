package dev.ylplayer.yl_player_android

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import java.net.ProtocolException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlin.random.Random
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request

internal data class YlHttpOrigin(
    val scheme: String,
    val host: String,
    val port: Int,
) {
    companion object {
        fun from(url: HttpUrl) = YlHttpOrigin(
            scheme = url.scheme.lowercase(),
            host = url.host.lowercase(),
            port = url.port,
        )
    }
}

internal object YlRedirectCredentialPolicy {
    private val credentialHeaders = listOf(
        "Authorization",
        "Cookie",
        "Proxy-Authorization",
    )

    fun sanitize(originalUrl: HttpUrl, request: Request): Request {
        if (YlHttpOrigin.from(originalUrl) == YlHttpOrigin.from(request.url)) {
            return request
        }
        return request.newBuilder().apply {
            credentialHeaders.forEach(::removeHeader)
        }.build()
    }
}

internal data class NetworkConfiguration(
    val connectTimeoutMs: Int,
    val readTimeoutMs: Int,
    val maxRetries: Int,
    val baseRetryDelayMs: Long,
    val maxRetryDelayMs: Long,
    val maxRedirects: Int,
) {
    fun createHttpClient(): OkHttpClient {
        val redirectCounts = ConcurrentHashMap<okhttp3.Call, Int>()
        return OkHttpClient.Builder()
            .connectTimeout(connectTimeoutMs.toLong(), TimeUnit.MILLISECONDS)
            .readTimeout(readTimeoutMs.toLong(), TimeUnit.MILLISECONDS)
            .addNetworkInterceptor { chain ->
                val call = chain.call()
                val safeRequest = YlRedirectCredentialPolicy.sanitize(
                    call.request().url,
                    chain.request(),
                )
                val response = try {
                    chain.proceed(safeRequest)
                } catch (error: Throwable) {
                    redirectCounts.remove(call)
                    throw error
                }
                val isFollowableRedirect = response.code in setOf(300, 301, 302, 303, 307, 308) &&
                    response.header("Location") != null
                if (!isFollowableRedirect) {
                    redirectCounts.remove(call)
                    return@addNetworkInterceptor response
                }
                val followedRedirects = redirectCounts[call] ?: 0
                if (followedRedirects >= maxRedirects) {
                    redirectCounts.remove(call)
                    response.close()
                    throw ProtocolException("Redirect limit exceeded: $maxRedirects")
                }
                redirectCounts[call] = followedRedirects + 1
                response
            }
            .build()
    }
}

@OptIn(UnstableApi::class)
internal class YlLoadErrorHandlingPolicy(
    private val network: NetworkConfiguration,
    private val onRetry: (Int, Long, Exception) -> Unit,
) : DefaultLoadErrorHandlingPolicy(network.maxRetries) {
    override fun getRetryDelayMsFor(
        loadErrorInfo: androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy.LoadErrorInfo,
    ): Long {
        val attempt = loadErrorInfo.errorCount
        if (attempt > network.maxRetries) return C.TIME_UNSET
        val shift = (attempt - 1).coerceIn(0, 16)
        val exponential = network.baseRetryDelayMs.coerceAtLeast(0) * (1L shl shift)
        val capped = minOf(network.maxRetryDelayMs.coerceAtLeast(0), exponential)
        val jitterRange = capped / 4
        val delayMs = if (jitterRange > 0) {
            capped - jitterRange + Random.nextLong(jitterRange * 2 + 1)
        } else {
            capped
        }
        onRetry(attempt, delayMs, loadErrorInfo.exception)
        return delayMs
    }
}
