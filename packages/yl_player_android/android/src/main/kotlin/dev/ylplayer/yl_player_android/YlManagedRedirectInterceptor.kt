package dev.ylplayer.yl_player_android

import java.net.ProtocolException
import okhttp3.Request
import okhttp3.Response

/** Follow-up construction only. The original resource owns the counter across retries. */
internal class YlManagedRedirectInterceptor(private val maxRedirects: Int, private val credentials: YlOriginCredentialPolicy) {
    fun follow(response: Response, followed: Int): Request? {
        if (response.code !in listOf(300,301,302,303,307,308)) return null
        val location = response.header("Location") ?: return null
        val target = response.request.url.resolve(location) ?: throw ProtocolException("Invalid redirect")
        if (target.scheme !in listOf("http", "https")) throw ProtocolException("Invalid redirect")
        if (followed >= maxRedirects) throw ProtocolException("Redirect limit")
        credentials.inherit(response.request.url, target)
        val builder = response.request.newBuilder().url(target)
        if (response.code in listOf(300,301,302,303) && response.request.method !in listOf("GET", "HEAD")) {
            builder.method("GET", null).removeHeader("Content-Type").removeHeader("Content-Length").removeHeader("Transfer-Encoding")
        }
        return builder.build()
    }
}
