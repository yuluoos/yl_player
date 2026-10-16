package dev.ylplayer.yl_player_android

import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.Socket
import kotlin.test.*

class YlNetworkByteCounterTest {
    @Test fun `concurrent reads accumulate once and separate loads stay isolated`() {
        val first = YlNetworkByteCounter()
        val next = YlNetworkByteCounter()
        assertEquals(0L, first.bytesReceived)
        val workers = List(4) { Thread { repeat(10000) { first.received(37) } }.apply { start() } }
        workers.forEach { it.join() }
        assertEquals(1_480_000L, first.bytesReceived)
        first.received(-1); first.received(0)
        assertEquals(1_480_000L, first.bytesReceived)
        assertEquals(0L, next.bytesReceived)
        first.received(Long.MAX_VALUE)
        assertEquals(Long.MAX_VALUE, first.bytesReceived)
    }

    @Test fun `HTTP counts body payload for both policies and repeated requests without bitrate estimates`() {
        for (policy in listOf(null, NetworkConfiguration(1000, 1000, 1, 0, 1000, 2))) {
            MockWebServer().use { server ->
                server.enqueue(MockResponse().setBody("abcd"))
                server.enqueue(MockResponse().setBody("efghi"))
                val address = server.url("/media").newBuilder().host("127.0.0.1").build()
                val counter = YlNetworkByteCounter()
                val http = YlManagedHttpClient(YlOriginCredentialPolicy(address, emptyMap(), emptyMap()), policy, networkBytes = counter)
                try {
                    assertEquals(0L, counter.bytesReceived)
                    http.newCall(Request.Builder().url(address).build()).execute().use { assertEquals("abcd", it.body?.string()) }
                    assertEquals(4L, counter.bytesReceived)
                    http.newCall(Request.Builder().url(address).build()).execute().use { assertEquals("efghi", it.body?.string()) }
                    assertEquals(9L, counter.bytesReceived)
                    http.cancelAll()
                    assertEquals(9L, counter.bytesReceived)
                } finally { http.close() }
            }
        }
    }

    @Test fun `RTMP counts received handshake bytes before media readiness or protocol failure`() {
        val counter = YlNetworkByteCounter()
        val socket = object : Socket() {
            override fun setTcpNoDelay(value: Boolean) {}
            override fun connect(endpoint: java.net.SocketAddress, timeout: Int) {}
            override fun getInputStream() = ByteArrayInputStream(byteArrayOf(3) + ByteArray(27))
            override fun getOutputStream() = ByteArrayOutputStream()
            override fun close() {}
        }
        val transport = YlRtmpTransport(YlRtmpSourcePolicy.parse("rtmp://127.0.0.1/live/x"), socket = socket, networkBytes = counter)
        try {
            assertFailsWith<YlRtmpException> { transport.open() }
            assertEquals(28L, counter.bytesReceived)
            transport.finish()
            assertEquals(28L, counter.bytesReceived)
        } finally { transport.finish() }
    }
}
