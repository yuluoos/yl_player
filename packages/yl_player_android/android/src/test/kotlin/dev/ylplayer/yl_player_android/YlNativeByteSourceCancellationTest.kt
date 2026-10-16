package dev.ylplayer.yl_player_android

import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.Protocol
import okio.Buffer
import kotlin.test.*
import java.nio.ByteBuffer

class YlNativeByteSourceCancellationTest {
    @Test fun cancellationDoesNotCloseTheResponseOnTheCallingThread() {
        val url="http://127.0.0.1/media.flv".toHttpUrl()
        val credentials=YlOriginCredentialPolicy(url,emptyMap(),emptyMap())
        val calls=YlManagedHttpClient(credentials,null)
        val type=Class.forName("dev.ylplayer.yl_player_android.YlHttpRangeByteSource")
        val source=type.declaredConstructors.single().apply {isAccessible=true}
            .newInstance(url.toString(),calls,credentials) as YlNativeByteSource
        val closedOn=mutableListOf<Thread>()
        val body=object:ResponseBody() {
            override fun contentType()=null
            override fun contentLength()=1L
            override fun source()=Buffer().writeByte(1)
            override fun close() {closedOn.add(Thread.currentThread())}
        }
        val response=Response.Builder().request(Request.Builder().url(url).build())
            .protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body).build()
        type.getDeclaredField("response").apply {isAccessible=true}.set(source,response)
        try {
            source.cancel()
            assertTrue(closedOn.isEmpty(),"Cancellation must not drain an HTTP body on the UI caller")
            assertEquals(-2,source.read(ByteBuffer.allocate(1)))
            val worker=Thread { source.close(); source.close() }
            worker.start();worker.join(2000)
            assertFalse(worker.isAlive)
            assertEquals(listOf(worker),closedOn)
        } finally { source.close() }
    }
}
