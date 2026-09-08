package dev.ylplayer.yl_player_android

import java.io.*
import java.util.concurrent.*
import okhttp3.*
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.mockwebserver.*
import kotlin.test.*

class YlManagedRedirectInterceptorTest {
    private fun MockWebServer.address(path: String) = url(path).newBuilder().host("127.0.0.1").build()
    private fun network(retries: Int = 0, redirects: Int = 4, headers: Int = 500, body: Int = 150) = NetworkConfiguration(headers, body, retries, 0, 1000, redirects)
    private fun client(server: MockWebServer, managed: Boolean = true, config: NetworkConfiguration = network(), retries: (Int, Long) -> Unit = { _, _ -> }) =
        YlManagedHttpClient(YlOriginCredentialPolicy(server.address("/"), mapOf("X-Ordinary" to "ok"), mapOf("Authorization" to "secret", "X-Api-Key" to "key")), if (managed) config else null, onRetry = retries)
    @Test fun `both policies keep same origin headers and permanently strip custom credentials across redirects`() {
        for (managed in listOf(false, true)) MockWebServer().use { first -> MockWebServer().use { second ->
            first.enqueue(MockResponse().setResponseCode(302).addHeader("Location", "/same"))
            first.enqueue(MockResponse().setResponseCode(302).addHeader("Location", second.address("/cross")))
            second.enqueue(MockResponse().setResponseCode(302).addHeader("Location", first.address("/return")))
            first.enqueue(MockResponse().setBody("done"))
            client(first, managed).newCall(Request.Builder().url(first.address("/start")).build()).execute().use { assertEquals("done", it.body!!.string()) }
            for (request in listOf(first.takeRequest(), first.takeRequest())) { assertEquals("secret", request.getHeader("Authorization")); assertEquals("key", request.getHeader("X-Api-Key")); assertEquals("ok", request.getHeader("X-Ordinary")) }
            for (request in listOf(second.takeRequest(), first.takeRequest())) { assertNull(request.getHeader("Authorization")); assertNull(request.getHeader("X-Api-Key")); assertEquals("ok", request.getHeader("X-Ordinary")) }
        } }
    }
    @Test fun `injected clock schedules one retry and fresh hop deadlines while preserving counters`() {
        MockWebServer().use { server ->
            val clock = ManualNetworkClock()
            val scheduled = CopyOnWriteArrayList<Pair<Int,Long>>()
            server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "/child"))
            server.enqueue(MockResponse().setResponseCode(503))
            server.enqueue(MockResponse().setBody("done"))
            val transport = YlManagedHttpClient(YlOriginCredentialPolicy(server.address("/"), emptyMap(), emptyMap()), network(1, 1).copy(baseRetryDelayMs = 100), clock, { index, delay -> scheduled += index to delay })
            val executor = Executors.newSingleThreadExecutor()
            try {
                val result = executor.submit<String> { transport.newCall(Request.Builder().url(server.address("/")).build()).execute().use { it.body!!.string() } }
                assertTrue(clock.retryScheduled.await(2, TimeUnit.SECONDS))
                assertFalse(result.isDone)
                assertEquals(2, server.requestCount)
                clock.advance(100)
                assertEquals("done", result.get(2, TimeUnit.SECONDS))
                assertEquals(listOf(1 to 100L), scheduled)
                assertEquals(listOf(500L, 500L, 100L, 500L), clock.delays.toList())
                assertEquals(3, server.requestCount)
            } finally { transport.close(); executor.shutdownNow() }
        }
    }
    @Test fun `cancellation while body resume retry is scheduled prevents reopening`() {
        MockWebServer().use { server ->
            val clock = ManualNetworkClock()
            server.enqueue(MockResponse().setBody("abcdefgh").setHeader("ETag", "\"v1\"").throttleBody(4, 1, TimeUnit.SECONDS))
            val transport = YlManagedHttpClient(YlOriginCredentialPolicy(server.address("/"), emptyMap(), emptyMap()), network(2).copy(baseRetryDelayMs = 100), clock)
            val call = transport.newCall(Request.Builder().url(server.address("/")).build())
            val executor = Executors.newSingleThreadExecutor()
            try {
                val result = executor.submit<Boolean> { try { call.execute().use { it.body!!.string() }; false } catch (_: IOException) { true } }
                assertTrue(clock.retryScheduled.await(2, TimeUnit.SECONDS)); call.cancel(); clock.advance(100)
                assertTrue(result.get(1, TimeUnit.SECONDS)); assertEquals(1, server.requestCount)
            } finally { transport.close(); executor.shutdownNow() }
        }
    }
    @Test fun `managed requests disable transparent gzip and unsafe encoded resume`() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("abcdefgh").setHeader("Content-Encoding", "gzip").setHeader("ETag", "\"v1\"").throttleBody(4, 1, TimeUnit.SECONDS))
            assertFailsWith<IOException> { client(server, config = network(2)).newCall(Request.Builder().url(server.address("/")).header("Accept-Encoding", "gzip").build()).execute().use { it.body!!.bytes() } }
            assertEquals("identity", server.takeRequest().getHeader("Accept-Encoding")); assertEquals(1, server.requestCount)
        }
    }
    @Test fun `managed rejects mismatched initial range and body retry header changes`() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(206).setHeader("Content-Range", "bytes 5-7/8").setBody("fgh"))
            assertFailsWith<IOException> { client(server).newCall(Request.Builder().url(server.address("/")).header("Range", "bytes=4-").build()).execute().use { it.body!!.string() } }
        }
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("original").setBodyDelay(1, TimeUnit.SECONDS).setHeader("ETag", "\"v1\""))
            server.enqueue(MockResponse().setBody("changed").setHeader("ETag", "\"v2\""))
            assertFailsWith<IOException> { client(server, config = network(1)).newCall(Request.Builder().url(server.address("/")).build()).execute().use { it.body!!.string() } }
            assertEquals(2, server.requestCount)
        }
    }
    @Test fun `nonretryable 421 stays visible and no retry event is emitted`() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(421).setHeader("X-Origin", "server").setBody("status"))
            val events = mutableListOf<Int>()
            client(server, config = network(2), retries = { index, _ -> events += index }).newCall(Request.Builder().url(server.address("/")).build()).execute().use {
                assertEquals(421, it.code); assertEquals("server", it.header("X-Origin")); assertEquals("status", it.body!!.string())
            }
            assertTrue(events.isEmpty()); assertEquals(1, server.requestCount)
        }
    }
    @Test fun `header deadline settles while DNS is still blocked and late lookup cannot consume another budget`() {
        MockWebServer().use { server ->
            val entered = CountDownLatch(1)
            val released = CountDownLatch(1)
            val url = server.address("/").newBuilder().host("lookup.invalid").build()
            val socket = OkHttpClient.Builder().proxy(java.net.Proxy.NO_PROXY).dns(object : Dns { override fun lookup(hostname: String): List<java.net.InetAddress> { entered.countDown(); released.await(); return listOf(java.net.InetAddress.getByName("127.0.0.1")) } }).build()
            val transport = YlManagedHttpClient(YlOriginCredentialPolicy(url, emptyMap(), emptyMap()), network(headers = 150), transport = socket)
            val executor = Executors.newSingleThreadExecutor()
            try {
                val result = executor.submit<Boolean> { try { transport.newCall(Request.Builder().url(url).build()).execute(); false } catch (_: java.net.SocketTimeoutException) { true } }
                assertTrue(entered.await(1, TimeUnit.SECONDS), "DNS did not start; completed result: ${if (result.isDone) result.get() else null}")
                assertTrue(result.get(1, TimeUnit.SECONDS))
                assertEquals(1L, released.count)
                assertEquals(0, server.requestCount)
            } finally { released.countDown(); transport.close(); executor.shutdownNow() }
        }
    }
    @Test fun `premature fixed length disconnect resumes with same strong representation`() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("abcdefgh").setHeader("ETag", "\"v1\"").setSocketPolicy(SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY))
            server.enqueue(MockResponse().setResponseCode(206).setHeader("ETag", "\"v1\"").setHeader("Content-Range", "bytes 4-7/8").setBody("efgh"))
            client(server, config = network(1)).newCall(Request.Builder().url(server.address("/")).build()).execute().use { assertEquals("abcdefgh", it.body!!.string()) }
            assertEquals(2, server.requestCount)
        }
    }
    @Test fun `actual HLS parser propagates master media key segment and return-origin provenance for both policies`() {
        org.mockito.Mockito.mockStatic(android.net.Uri::class.java).use { uris ->
            uris.`when`<android.net.Uri> { android.net.Uri.parse(org.mockito.Mockito.anyString()) }.thenAnswer { invocation ->
                val value = invocation.getArgument<String>(0)
                org.mockito.Mockito.mock(android.net.Uri::class.java).also { uri -> org.mockito.Mockito.`when`(uri.toString()).thenReturn(value) }
            }
            org.mockito.Mockito.mockStatic(android.text.TextUtils::class.java).use { text ->
                text.`when`<Boolean> { android.text.TextUtils.isEmpty(org.mockito.Mockito.any()) }.thenAnswer { it.getArgument<CharSequence?>(0).isNullOrEmpty() }
                for (managed in listOf(false, true)) MockWebServer().use { first -> MockWebServer().use { second ->
                    val root = first.address("/master.m3u8")
                    val credentials = YlOriginCredentialPolicy(root, mapOf("X-Ordinary" to "ok"), mapOf("X-Api-Key" to "secret"), requireKnownAncestry = true)
                    val transport = YlManagedHttpClient(credentials, if (managed) network() else null)
                    val parsers = YlOriginPlaylistParserFactory(credentials)
                    first.enqueue(MockResponse().setBody("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100000\n${second.address("/media.m3u8")}\n"))
                    second.enqueue(MockResponse().setBody("#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-KEY:METHOD=AES-128,URI=\"${second.address("/key")}\"\n#EXTINF:10,\n${second.address("/segment")}\n#EXT-X-ENDLIST\n"))
                    second.enqueue(MockResponse().setResponseCode(302).setHeader("Location", first.address("/key")))
                    second.enqueue(MockResponse().setResponseCode(302).setHeader("Location", first.address("/segment")))
                    first.enqueue(MockResponse().setBody("0123456789abcdef")); first.enqueue(MockResponse().setBody("segment"))
                    val master = transport.newCall(Request.Builder().url(root).build()).execute().use { response ->
                        parsers.createPlaylistParser().parse(android.net.Uri.parse(response.request.url.toString()), response.body!!.byteStream()) as androidx.media3.exoplayer.hls.playlist.HlsMultivariantPlaylist
                    }
                    val media = transport.newCall(Request.Builder().url(master.mediaPlaylistUrls.single().toString()).build()).execute().use { response ->
                        parsers.createPlaylistParser(master, null).parse(android.net.Uri.parse(response.request.url.toString()), response.body!!.byteStream()) as androidx.media3.exoplayer.hls.playlist.HlsMediaPlaylist
                    }
                    val segment = media.segments.single()
                    for (url in listOf(segment.fullSegmentEncryptionKeyUri!!, segment.url)) transport.newCall(Request.Builder().url(url).build()).execute().use { it.body!!.string() }
                    assertEquals("secret", first.takeRequest().getHeader("X-Api-Key"))
                    for (request in listOf(second.takeRequest(), second.takeRequest(), first.takeRequest(), second.takeRequest(), first.takeRequest())) { assertNull(request.getHeader("X-Api-Key")); assertEquals("ok", request.getHeader("X-Ordinary")) }
                    // A reused parsed playlist and independent return-origin request stay stripped.
                    second.enqueue(MockResponse().setBody("cached-child"))
                    transport.newCall(Request.Builder().url(segment.url).build()).execute().close()
                    assertNull(second.takeRequest().getHeader("X-Api-Key"))
                    transport.close()
                } }
            }
        }
    }
    @Test fun `307 and 308 retain method body and redirect counter survives retries`() {
        for (status in listOf(307,308)) MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(status).addHeader("Location", "/next")); server.enqueue(MockResponse().setBody("done"))
            client(server).newCall(Request.Builder().url(server.address("/start")).post("payload".toRequestBody()).build()).execute().close()
            repeat(2) { val request = server.takeRequest(); assertEquals("POST", request.method); assertEquals("payload", request.body.readUtf8()) }
        }
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(302).addHeader("Location", "/next")); server.enqueue(MockResponse().setResponseCode(503)); server.enqueue(MockResponse().setResponseCode(302).addHeader("Location", "/forbidden"))
            assertFailsWith<IOException> { client(server, config = network(1, 1)).newCall(Request.Builder().url(server.address("/start")).build()).execute() }
            assertEquals(3, server.requestCount)
        }
    }
    @Test fun `OkHttp status recovery cannot bypass zero managed retry budget`() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(503).setHeader("Retry-After", "0"))
            server.enqueue(MockResponse().setBody("unbudgeted"))
            client(server).newCall(Request.Builder().url(server.address("/")).build()).execute().use { assertEquals(503, it.code) }
            assertEquals(1, server.requestCount)
        }
    }
    @Test fun `managed status retry count and events are exact`() {
        for (status in listOf(408,429,500,502,503,504)) MockWebServer().use { server ->
            repeat(3) { server.enqueue(MockResponse().setResponseCode(status)) }
            val scheduled = mutableListOf<Int>()
            client(server, config = network(2), retries = { index, _ -> scheduled += index }).newCall(Request.Builder().url(server.address("/resource")).build()).execute().close()
            assertEquals(3, server.requestCount); assertEquals(listOf(1,2), scheduled)
        }
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(503))
            client(server).newCall(Request.Builder().url(server.address("/resource")).build()).execute().close()
            assertEquals(1, server.requestCount)
        }
    }
    @Test fun `connected server header stall expires and body timeout starts only after headers`() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE)); server.enqueue(MockResponse().setHeadersDelay(200, TimeUnit.MILLISECONDS).setBody("ok"))
            val started = System.nanoTime()
            client(server, config = network(1, headers = 350, body = 50)).newCall(Request.Builder().url(server.address("/")).build()).execute().use { assertEquals("ok", it.body!!.string()) }
            val elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
            assertTrue(elapsed >= 500); assertTrue(elapsed < 2500); assertEquals(2, server.requestCount)
        }
    }
    @Test fun `partial body resumes exactly with same budget and strong validator`() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("abcdefgh").setHeader("ETag", "\"v1\"").throttleBody(4, 1, TimeUnit.SECONDS))
            server.enqueue(MockResponse().setResponseCode(206).setHeader("ETag", "\"v1\"").setHeader("Content-Range", "bytes 4-7/8").setBody("efgh"))
            client(server, config = network(1)).newCall(Request.Builder().url(server.address("/")).build()).execute().use { assertEquals("abcdefgh", it.body!!.string()) }
            server.takeRequest(); val resumed = server.takeRequest()
            assertEquals("bytes=4-", resumed.getHeader("Range")); assertEquals("\"v1\"", resumed.getHeader("If-Range")); assertEquals(2, server.requestCount)
        }
    }
    @Test fun `resumed framing mismatch fails before delivering bytes beyond the validated range`() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("abcdefgh").setHeader("ETag", "\"v1\"").throttleBody(4, 1, TimeUnit.SECONDS))
            server.enqueue(MockResponse().setResponseCode(206).setHeader("ETag", "\"v1\"").setHeader("Content-Range", "bytes 4-7/8").setBody("efghEXTRA"))
            assertFailsWith<IOException> { client(server, config = network(2)).newCall(Request.Builder().url(server.address("/")).build()).execute().use { it.body!!.string() } }
            assertEquals(2, server.requestCount)
        }
    }
    @Test fun `mismatching resume and cancellation cannot produce concatenated body or extra retry`() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("abcdefgh").setHeader("ETag", "\"v1\"").throttleBody(4, 1, TimeUnit.SECONDS))
            server.enqueue(MockResponse().setResponseCode(206).setHeader("ETag", "\"v2\"").setHeader("Content-Range", "bytes 4-7/8").setBody("XXXX"))
            assertFailsWith<IOException> { client(server, config = network(2)).newCall(Request.Builder().url(server.address("/")).build()).execute().use { it.body!!.string() } }
            assertEquals(2, server.requestCount)
        }
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
            val call = client(server, config = network(3, headers = 2000)).newCall(Request.Builder().url(server.address("/")).build())
            val executor = Executors.newSingleThreadExecutor()
            try {
                val result = executor.submit<Boolean> { try { call.execute(); false } catch (_: IOException) { true } }
                assertNotNull(server.takeRequest(2, TimeUnit.SECONDS)); call.cancel()
                assertTrue(result.get(1, TimeUnit.SECONDS)); assertEquals(1, server.requestCount)
            } finally { executor.shutdownNow() }
        }
    }
    private class ManualNetworkClock : YlNetworkClock {
        private data class Timer(val at: Long, val action: () -> Unit, var cancelled: Boolean = false)
        private val timers = mutableListOf<Timer>()
        val delays = CopyOnWriteArrayList<Long>()
        val retryScheduled = CountDownLatch(1)
        private var now = 0L
        @Synchronized override fun monotonicMs() = now
        override fun wallTimeMs() = 0L
        @Synchronized override fun schedule(delayMs: Long, action: () -> Unit): Closeable {
            delays += delayMs
            val timer = Timer(now + delayMs, action).also(timers::add)
            if (delayMs == 100L) retryScheduled.countDown()
            return Closeable { synchronized(this) { timer.cancelled = true } }
        }
        fun advance(ms: Long) {
            val due = synchronized(this) { now += ms; timers.filter { !it.cancelled && it.at <= now }.also { timers.removeAll(it.toSet()) } }
            due.forEach { it.action() }
        }
    }
}
