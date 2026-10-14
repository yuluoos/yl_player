package dev.ylplayer.yl_player_android

import okhttp3.HttpUrl
import java.util.Collections

/** Source-owned, atomically published ordered alternatives for managed clear DASH.
 * Readers capture an immutable group for one HTTP call; a later source preparation
 * cannot alter an in-flight call's candidates, retry budget or entity validator. */
internal class YlDashCandidateRegistry(private val maxUrls: Int = 100_000, private val maxCharacters: Int = 4 * 1024 * 1024) {
    @Volatile private var accepted: Map<HttpUrl, List<HttpUrl>> = emptyMap()
    fun publish(groups: List<List<HttpUrl>>) {
        val next = linkedMapOf<HttpUrl, List<HttpUrl>>()
        var characters = 0L
        for (group in groups) {
            require(group.size in 1..128)
            val ordered = Collections.unmodifiableList(group.map(::key).distinct())
            if (ordered.size == 1) continue
            for (url in ordered) {
                val previous = next[url]
                // A bare Media3 HTTP request cannot disambiguate conflicting
                // resource identities sharing a URL. Reject before publication.
                require(previous == null || previous == ordered)
                if (previous != null) continue
                require(next.size < maxUrls)
                characters += url.toString().length
                require(characters <= maxCharacters)
                next[url] = ordered
            }
        }
        accepted = Collections.unmodifiableMap(next)
    }
    fun candidatesFor(url: HttpUrl): List<HttpUrl> = accepted[key(url)] ?: listOf(url)
    private fun key(url: HttpUrl) = url.newBuilder().fragment(null).build()
}
