package dev.ylplayer.yl_player_android

import okhttp3.Request
import okhttp3.mockwebserver.*
import kotlin.test.*

class YlDashCandidateHttpTest {
    private fun MockWebServer.address(path: String) = url(path).newBuilder().host("127.0.0.1").build()
    private fun network(retries: Int) = NetworkConfiguration(1000, 500, retries, 0, 1000, 2)

    @Test fun `managed DASH starts at declared first candidate regardless of Media3 choice`() {
        MockWebServer().use { server ->
            server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest) = if (request.path == "/a") MockResponse().setResponseCode(503)
                    else MockResponse().setBody("media")
            }
            val urls = listOf(server.address("/a"), server.address("/b"))
            val client = YlManagedHttpClient(YlOriginCredentialPolicy(urls[0], emptyMap(), emptyMap()), network(1),
                dashCandidates = { urls })
            try {
                client.newCall(Request.Builder().url(urls[1]).build()).execute().use { assertEquals("media", it.body!!.string()) }
                assertEquals(2, server.requestCount)
                assertEquals(listOf("/a", "/b"), List(2) { server.takeRequest().path })
            } finally { client.close() }
        }
    }

    @Test fun `candidate switching shares one retry budget rather than retries per URL`() {
        MockWebServer().use { server ->
            server.dispatcher = object : Dispatcher() { override fun dispatch(request: RecordedRequest) = MockResponse().setResponseCode(503) }
            val urls = listOf(server.address("/a"), server.address("/b"))
            val indices = mutableListOf<Int>()
            val client = YlManagedHttpClient(YlOriginCredentialPolicy(urls[0], emptyMap(), emptyMap()), network(2),
                onRetry = { index, _ -> indices += index }, dashCandidates = { urls })
            try {
                client.newCall(Request.Builder().url(urls[0]).build()).execute().use { assertEquals(503, it.code) }
                assertEquals(listOf(1, 2), indices)
                assertEquals(3, server.requestCount)
                assertEquals(listOf("/a", "/b", "/a"), List(3) { server.takeRequest().path })
            } finally { client.close() }
        }
    }

    @Test fun `foreign fallback and return origin do not restore custom credentials`() {
        MockWebServer().use { primary -> MockWebServer().use { foreign ->
            primary.enqueue(MockResponse().setResponseCode(503))
            foreign.enqueue(MockResponse().setResponseCode(503))
            primary.enqueue(MockResponse().setBody("media"))
            val urls = listOf(primary.address("/a"), foreign.address("/b"), primary.address("/c"))
            val policy = YlOriginCredentialPolicy(urls[0], mapOf("X-Ordinary" to "ok"), mapOf("X-Key" to "secret"))
            val client = YlManagedHttpClient(policy, network(2), dashCandidates = { urls })
            try {
                client.newCall(Request.Builder().url(urls[0]).build()).execute().use { assertEquals("media", it.body!!.string()) }
                val first = primary.takeRequest()
                assertEquals("secret", first.getHeader("X-Key"))
                assertEquals(1, foreign.requestCount)
                val second = foreign.takeRequest()
                val third = primary.takeRequest()
                assertNull(second.getHeader("X-Key")); assertNull(third.getHeader("X-Key"))
                assertEquals("ok", third.getHeader("X-Ordinary")); assertEquals("/c", third.path)
                assertTrue(policy.isStripped(urls[2]))
            } finally { client.close() }
        } }
    }
    @Test fun `body resume stays on validated candidate and shares its retry budget`() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("abcdefgh").setHeader("ETag", "\"v1\"").setSocketPolicy(SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY))
            server.enqueue(MockResponse().setResponseCode(206).setHeader("ETag", "\"v1\"").setHeader("Content-Range", "bytes 4-7/8").setBody("efgh"))
            val urls = listOf(server.address("/a"), server.address("/b"))
            val client = YlManagedHttpClient(YlOriginCredentialPolicy(urls[0], emptyMap(), emptyMap()), network(1), dashCandidates = { urls })
            try {
                client.newCall(Request.Builder().url(urls[0]).build()).execute().use { assertEquals("abcdefgh", it.body!!.string()) }
                assertEquals("/a", server.takeRequest().path)
                val resumed = server.takeRequest()
                assertEquals("/a", resumed.path); assertEquals("bytes=4-", resumed.getHeader("Range"))
                assertEquals("\"v1\"", resumed.getHeader("If-Range")); assertEquals(2, server.requestCount)
            } finally { client.close() }
        }
    }

    @Test fun `caller entity validator pins original candidate rather than restarting at first`() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(206).setHeader("ETag", "\"b\"").setHeader("Content-Range", "bytes 4-7/8").setBody("efgh"))
            val urls = listOf(server.address("/a"), server.address("/b"))
            val client = YlManagedHttpClient(YlOriginCredentialPolicy(urls[0], emptyMap(), emptyMap()), network(1), dashCandidates = { urls })
            try {
                client.newCall(Request.Builder().url(urls[1]).header("Range", "bytes=4-7").header("If-Range", "\"b\"").build()).execute().use {
                    assertEquals("efgh", it.body!!.string())
                }
                assertEquals("/b", server.takeRequest().path); assertEquals(1, server.requestCount)
            } finally { client.close() }
        }
    }

    @Test fun `candidate changes cannot refund redirect budget`() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "/a-final"))
            server.enqueue(MockResponse().setResponseCode(503))
            server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "/b-final"))
            val urls = listOf(server.address("/a"), server.address("/b"))
            val client = YlManagedHttpClient(YlOriginCredentialPolicy(urls[0], emptyMap(), emptyMap()), network(1).copy(maxRedirects = 1), dashCandidates = { urls })
            try {
                assertFailsWith<java.io.IOException> { client.newCall(Request.Builder().url(urls[0]).build()).execute().close() }
                assertEquals(3, server.requestCount)
                assertEquals(listOf("/a", "/a-final", "/b"), List(3) { server.takeRequest().path })
            } finally { client.close() }
        }
    }

    @Test fun `cancel during scheduled candidate retry prevents the next request`() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(503))
            val urls = listOf(server.address("/a"), server.address("/b"))
            val scheduled = java.util.concurrent.CountDownLatch(1)
            val client = YlManagedHttpClient(YlOriginCredentialPolicy(urls[0], emptyMap(), emptyMap()), network(1).copy(baseRetryDelayMs = 500),
                onRetry = { _, _ -> scheduled.countDown() }, dashCandidates = { urls })
            val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
            val call = client.newCall(Request.Builder().url(urls[0]).build())
            try {
                val result = executor.submit<Boolean> { try { call.execute().close(); false } catch (_: java.io.IOException) { true } }
                assertTrue(scheduled.await(2, java.util.concurrent.TimeUnit.SECONDS))
                call.cancel()
                assertTrue(result.get(2, java.util.concurrent.TimeUnit.SECONDS)); assertEquals(1, server.requestCount)
            } finally { client.close(); executor.shutdownNow() }
        }
    }

}
