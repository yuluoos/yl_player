package dev.ylplayer.yl_player_android

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import okhttp3.Request
import okhttp3.HttpUrl.Companion.toHttpUrl

class YlRedirectCredentialPolicyTest {
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
