package dev.ylplayer.yl_player_android

import okhttp3.HttpUrl
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
)
