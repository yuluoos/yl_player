package dev.ylplayer.yl_player_android

import okhttp3.HttpUrl
import okhttp3.Request

/** Source lifetime graph. Once a URL is reached through a stripped path, every reuse remains
 * stripped, including cached playlist objects, reloads and return-origin descendants. */
internal class YlOriginCredentialPolicy(
    source: HttpUrl,
    headers: Map<String, String>,
    credentials: Map<String, String>,
    private val requireKnownAncestry: Boolean = false,
) {
    private val origin = YlHttpOrigin.from(source)
    private val ordinary = headers.filterKeys { it.lowercase() !in reserved && it.lowercase() !in credentials.keys.map(String::lowercase) }
    private val secrets = headers.filterKeys { it.lowercase() in setOf("authorization", "cookie", "proxy-authorization") } + credentials
    private val credentialKeys = (credentials.keys + listOf("Authorization", "Cookie", "Proxy-Authorization")).map(String::lowercase).toSet()
    private val stripped = mutableSetOf<HttpUrl>()
    private val known = mutableSetOf(key(source))
    private val edges = mutableMapOf<HttpUrl, MutableSet<HttpUrl>>()
    // LL-HLS reload parameters and fragments do not create independent credential ancestry.
    private fun key(url: HttpUrl): HttpUrl = url.newBuilder().fragment(null).apply {
        listOf("_HLS_msn", "_HLS_part", "_HLS_skip").forEach(::removeAllQueryParameters)
    }.build()
    @Synchronized fun isStripped(url: HttpUrl): Boolean = YlHttpOrigin.from(url) != origin || key(url) in stripped || (requireKnownAncestry && key(url) !in known)
    @Synchronized fun inherit(parent: HttpUrl, child: HttpUrl) {
        val from = key(parent)
        val to = key(child)
        val inherited = isStripped(parent)
        known.add(to)
        edges.getOrPut(from) { mutableSetOf() }.add(to)
        if (inherited || YlHttpOrigin.from(child) != origin) markStripped(child)
    }
    @Synchronized fun markStripped(url: HttpUrl) {
        val pending = java.util.ArrayDeque<HttpUrl>()
        pending.add(key(url))
        while (pending.isNotEmpty()) {
            val next = pending.removeFirst()
            if (stripped.add(next)) edges[next]?.let(pending::addAll)
        }
    }
    @Synchronized fun apply(request: Request, inheritedStripped: Boolean): Request {
        if (inheritedStripped || YlHttpOrigin.from(request.url) != origin) markStripped(request.url)
        return request.newBuilder().apply {
            ordinary.forEach { (key, value) -> if (key.lowercase() !in credentialKeys) header(key, value) }
            if (isStripped(request.url)) {
                request.headers.names().filter { it.lowercase() in credentialKeys }.forEach(::removeHeader)
                credentialKeys.forEach(::removeHeader)
            } else secrets.filterKeys { it.lowercase() !in reserved }.forEach { (key, value) -> header(key, value) }
        }.build()
    }
    companion object {
        val reserved = setOf("host", "connection", "content-length", "transfer-encoding", "range", "if-range", "accept-encoding", "upgrade", "keep-alive", "te", "trailer", "proxy-connection")
    }
}
