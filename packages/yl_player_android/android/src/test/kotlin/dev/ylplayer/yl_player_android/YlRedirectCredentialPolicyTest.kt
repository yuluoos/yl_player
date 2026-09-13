package dev.ylplayer.yl_player_android

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import okhttp3.Request
import okhttp3.HttpUrl.Companion.toHttpUrl

class YlRedirectCredentialPolicyTest {
    @Test
    fun `HLS ancestry graph is skipped when requests contain no sensitive credentials`() {
        assertFalse(requiresHlsCredentialAncestry(emptyMap(), emptyMap()))
        assertFalse(
            requiresHlsCredentialAncestry(
                mapOf("User-Agent" to "YL", "Referer" to "https://media.test"),
                emptyMap(),
            ),
        )
    }

    @Test
    fun `HLS ancestry graph is retained for every supported credential source`() {
        for (header in listOf("Authorization", "authorization", "Cookie", "Proxy-Authorization")) {
            assertTrue(requiresHlsCredentialAncestry(mapOf(header to "secret"), emptyMap()))
        }
        assertTrue(requiresHlsCredentialAncestry(emptyMap(), mapOf("X-Api-Key" to "secret")))
    }

    @Test fun `HLS reload query and cached graph edges cannot restore stripped credentials`() {
        val root = "https://origin.test/master.m3u8".toHttpUrl()
        val outside = "https://cdn.test/media.m3u8".toHttpUrl()
        val returning = "https://origin.test/media.m3u8".toHttpUrl()
        val key = "https://origin.test/key".toHttpUrl()
        val policy = YlOriginCredentialPolicy(root, mapOf("X-Ordinary" to "ok"), mapOf("X-Api-Key" to "secret"))
        policy.inherit(root, returning)
        policy.inherit(returning, key) // Cached trusted edges exist before a later tainted path.
        policy.inherit(root, outside); policy.inherit(outside, returning)
        for (url in listOf(returning.toString() + "?_HLS_msn=42&_HLS_part=2&_HLS_skip=YES#fragment", key.toString())) {
            val safe = policy.apply(Request.Builder().url(url).build(), false)
            assertNull(safe.header("X-Api-Key")); assertEquals("ok", safe.header("X-Ordinary"))
        }
    }
    @Test
    fun `same origin keeps caller credentials including implicit https port`() {
        val safe = YlRedirectCredentialPolicy.sanitize(
            "https://media.test/start".toHttpUrl(),
            credentialRequest("https://MEDIA.test:443/next"),
        )

        assertCredentialsPresent(safe)
    }

    @Test
    fun `same origin keeps credentials with implicit http port`() {
        val safe = YlRedirectCredentialPolicy.sanitize(
            "http://media.test:80/start".toHttpUrl(),
            credentialRequest("http://media.test/next"),
        )

        assertCredentialsPresent(safe)
    }

    @Test
    fun `host change strips every credential but keeps ordinary headers`() {
        assertCredentialsRemoved(
            YlRedirectCredentialPolicy.sanitize(
                "https://media.test/start".toHttpUrl(),
                credentialRequest("https://cdn.test/next"),
            ),
        )
    }

    @Test
    fun `scheme downgrade strips every credential`() {
        assertCredentialsRemoved(
            YlRedirectCredentialPolicy.sanitize(
                "https://media.test/start".toHttpUrl(),
                credentialRequest("http://media.test/next"),
            ),
        )
    }

    @Test
    fun `effective port change strips every credential`() {
        assertCredentialsRemoved(
            YlRedirectCredentialPolicy.sanitize(
                "https://media.test/start".toHttpUrl(),
                credentialRequest("https://media.test:8443/next"),
            ),
        )
    }

    @Test
    fun `credentials removed on first hop cannot reappear on second hop`() {
        val original = "https://media.test/start".toHttpUrl()
        val firstHop = YlRedirectCredentialPolicy.sanitize(
            original,
            credentialRequest("https://cdn.test/first"),
        )
        val secondHop = YlRedirectCredentialPolicy.sanitize(
            original,
            firstHop.newBuilder().url("https://media.test/second").build(),
        )

        assertCredentialsRemoved(secondHop)
    }

    private fun credentialRequest(url: String): Request = Request.Builder()
        .url(url)
        .header("Authorization", "Bearer secret")
        .header("Cookie", "sid=secret")
        .header("Proxy-Authorization", "Basic secret")
        .header("User-Agent", "YL")
        .build()

    private fun assertCredentialsPresent(request: Request) {
        assertEquals("Bearer secret", request.header("Authorization"))
        assertEquals("sid=secret", request.header("Cookie"))
        assertEquals("Basic secret", request.header("Proxy-Authorization"))
        assertEquals("YL", request.header("User-Agent"))
    }

    private fun assertCredentialsRemoved(request: Request) {
        assertNull(request.header("Authorization"))
        assertNull(request.header("Cookie"))
        assertNull(request.header("Proxy-Authorization"))
        assertEquals("YL", request.header("User-Agent"))
    }
}
