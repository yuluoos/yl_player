package dev.ylplayer.yl_player_android

import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.Executors
import kotlin.test.*

class YlRtmpTransportTest {
    @Test fun `silent and trickling peers cannot extend absolute setup deadline`() {
        for (trickle in listOf(false,true)) {
            ServerSocket(0,1,InetAddress.getLoopbackAddress()).use { server ->
                val worker = Thread { server.accept().use { socket ->
                    try { if (trickle) repeat(100) { socket.getOutputStream().write(3); Thread.sleep(15) } else Thread.sleep(400) } catch (_: Exception) { }
                } }.apply { isDaemon = true; start() }
                val t = YlRtmpTransport(YlRtmpSourcePolicy.parse("rtmp://127.0.0.1:${server.localPort}/live/x"), setupMs = 100)
                val start = System.nanoTime()
                val failure = assertFailsWith<YlRtmpException> { t.open() }
                assertEquals(YlFailureKind.RTMP_HANDSHAKE_FAILED, failure.kind)
                assertTrue(failure.transient)
                assertTrue((System.nanoTime()-start)/1000000 < 1500)
                t.close(); worker.join(1500)
            }
        }
    }
    @Test fun `close wakes blocked handshake without waiting for setup`() {
        ServerSocket(0,1,InetAddress.getLoopbackAddress()).use { server ->
            val accepted = CountDownLatch(1)
            val done = CountDownLatch(1)
            val peer = Thread { server.accept().use { socket -> accepted.countDown(); done.await(2,TimeUnit.SECONDS) } }.apply { isDaemon=true; start() }
            val t = YlRtmpTransport(YlRtmpSourcePolicy.parse("rtmp://127.0.0.1:${server.localPort}/live/x"))
            val executor = Executors.newSingleThreadExecutor()
            try {
                val result = executor.submit<YlFailureKind> { try { t.open(); error("opened") } catch (e: YlRtmpException) { e.kind } }
                assertTrue(accepted.await(1,TimeUnit.SECONDS))
                t.close()
                assertEquals(YlFailureKind.LOAD_CANCELLED, result.get(1,TimeUnit.SECONDS))
            } finally { done.countDown(); t.close(); executor.shutdownNow(); peer.join(1500) }
        }
    }
    @Test fun `DNS admission remains held after cancellation until actual OS lookup exit`() {
        val entered = CountDownLatch(2); val release = CountDownLatch(1)
        val dns = YlRtmpDns { entered.countDown(); release.await(); arrayOf(InetAddress.getLoopbackAddress()) }
        val cancelled = java.util.concurrent.atomic.AtomicBoolean(false)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val futures = (1..2).map { executor.submit { assertFailsWith<YlRtmpException> { dns.resolve("owned.test") { if (cancelled.get()) throw YlRtmpException(YlFailureKind.LOAD_CANCELLED) } } } }
            assertTrue(entered.await(1,TimeUnit.SECONDS)); cancelled.set(true)
            futures.forEach { it.get(1,TimeUnit.SECONDS) }
            assertEquals(YlFailureKind.RESOURCE_EXHAUSTED, assertFailsWith<YlRtmpException> { dns.resolve("owned.test") {} }.kind)
        } finally { release.countDown(); executor.shutdownNow() }
    }
    @Test fun `close interrupts a published connecting socket`() {
        val entered=CountDownLatch(1);val closed=CountDownLatch(1)
        val socket=object:java.net.Socket(){
            override fun setTcpNoDelay(value:Boolean){}
            override fun connect(endpoint:java.net.SocketAddress,timeout:Int){entered.countDown();closed.await(2,TimeUnit.SECONDS);throw java.io.IOException()}
            override fun close(){closed.countDown()}
        }
        val t=YlRtmpTransport(YlRtmpSourcePolicy.parse("rtmp://127.0.0.1/live/x"),socket=socket)
        val executor=Executors.newSingleThreadExecutor()
        try {
            val result=executor.submit<YlFailureKind>{try {t.open();error("opened")}catch(e:YlRtmpException){e.kind}}
            assertTrue(entered.await(1,TimeUnit.SECONDS));t.close()
            assertEquals(YlFailureKind.LOAD_CANCELLED,result.get(1,TimeUnit.SECONDS))
        }finally{t.finish();executor.shutdownNow()}
    }
    @Test fun `close interrupts a blocked socket write`() {
        val entered=CountDownLatch(1);val closed=CountDownLatch(1)
        val socket=object:java.net.Socket(){
            override fun setTcpNoDelay(value:Boolean){}
            override fun connect(endpoint:java.net.SocketAddress,timeout:Int){}
            override fun getInputStream()=java.io.ByteArrayInputStream(ByteArray(0))
            override fun getOutputStream()=object:java.io.OutputStream(){override fun write(value:Int){entered.countDown();closed.await(2,TimeUnit.SECONDS);throw java.io.IOException()}}
            override fun close(){closed.countDown()}
        }
        val t=YlRtmpTransport(YlRtmpSourcePolicy.parse("rtmp://127.0.0.1/live/x"),socket=socket)
        val executor=Executors.newSingleThreadExecutor()
        try {
            val result=executor.submit<YlFailureKind>{try {t.open();error("opened")}catch(e:YlRtmpException){e.kind}}
            assertTrue(entered.await(1,TimeUnit.SECONDS));t.close()
            assertEquals(YlFailureKind.LOAD_CANCELLED,result.get(1,TimeUnit.SECONDS))
        }finally{t.finish();executor.shutdownNow()}
    }

}
