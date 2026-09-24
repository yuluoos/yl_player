package dev.ylplayer.yl_player_android

import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.*

/** Loopback peer writes protocol bytes; commands use fixed transaction and stream identities. */
class YlRtmpControlTest {
    private val config=byteArrayOf(0x17,0,0,0,0,1,0x64,0,0x1f,0xff.toByte(),0xe1.toByte(),0,1,0x67,1,0,1,0x68)
    private val frame=byteArrayOf(0x17,1,0,0,0,0,0,0,1,0x65)
    private fun peer(socket:Socket, action:(YlRtmpChunkReader,YlRtmpChunkWriter)->Unit) {
        socket.soTimeout=2000
        val i=socket.getInputStream(); val o=socket.getOutputStream()
        assertEquals(3,i.u8()); val c1=i.exact(1536)
        val s1=ByteArray(1536) { (it%251).toByte() }
        o.write(3);o.write(s1);o.flush()
        assertContentEquals(s1,i.exact(1536)) // Blocks if client incorrectly waits for S2.
        o.write(c1);o.flush()
        action(YlRtmpChunkReader(i),YlRtmpChunkWriter(o))
    }
    private fun command(w:YlRtmpChunkWriter,stream:Int,vararg args:Any?)=w.write(YlRtmpMessage(20,stream,0,YlRtmpAmf.encode(args.toList())))
    private fun setup(r:YlRtmpChunkReader,w:YlRtmpChunkWriter) {
        val connect=YlRtmpAmf.decode(r.next().payload)
        assertEquals("connect",connect[0]);assertEquals(1.0,connect[1]);assertEquals("live",(connect[2] as Map<*,*>)["app"])
        command(w,0,"_result",1.0,null,mapOf("code" to "NetConnection.Connect.Success"))
        assertEquals("createStream",YlRtmpAmf.decode(r.next().payload)[0])
        command(w,0,"_result",2.0,null,1.0)
        assertEquals(4,r.next().type) // Set Buffer Length.
        val play=r.next();assertEquals(1,play.streamId);assertEquals("play",YlRtmpAmf.decode(play.payload)[0])
        command(w,1,"onStatus",0.0,null,mapOf("code" to "NetStream.Play.Start","level" to "status"))
    }
    private fun runPeer(action:(Socket)->Unit, client:(YlRtmpTransport)->Unit, inactivityMs:Long=100) {
        ServerSocket(0,1,InetAddress.getLoopbackAddress()).use { server ->
            val executor=Executors.newSingleThreadExecutor()
            val future=executor.submit { server.accept().use(action) }
            val t=YlRtmpTransport(YlRtmpSourcePolicy.parse("rtmp://127.0.0.1:${server.localPort}/live/key"),setupMs=1000,inactivityMs=inactivityMs)
            try { client(t); future.get(3,TimeUnit.SECONDS) }
            finally { t.finish();executor.shutdownNow() }
        }
    }
    @Test fun `server denial is permanent and contains no remote prose`() = runPeer({ socket -> peer(socket) { r,w ->
        r.next();command(w,0,"_error",1.0,null,mapOf("code" to "secret-token", "description" to "private-host"))
    } }, { t -> val e=assertFailsWith<YlRtmpException> { t.open() };assertEquals(YlFailureKind.RTMP_STREAM_UNAVAILABLE,e.kind);assertFalse(e.transient);assertFalse(e.toString().contains("private-host")) })
    @Test fun `ping replies retain timestamp and config chatter cannot prevent media timeout`() = runPeer({ socket -> peer(socket) { r,w ->
        setup(r,w)
        w.write(YlRtmpMessage(4,0,0,byteArrayOf(0,6,0x12,0x34,0x56,0x78)))
        val pong=r.next();assertEquals(4,pong.type);assertContentEquals(byteArrayOf(0,7,0x12,0x34,0x56,0x78),pong.payload)
        w.write(YlRtmpMessage(9,1,0,config));w.write(YlRtmpMessage(9,1,1,frame))
        try { repeat(30) { Thread.sleep(10);w.write(YlRtmpMessage(9,1,2,config)) } } catch (_:java.io.IOException) { }
    } }, { t -> t.open();val e=assertFailsWith<YlRtmpException> { while(true) t.read(ByteArray(256),0,256) };assertEquals(YlFailureKind.RTMP_DISCONNECTED,e.kind);assertTrue(e.transient) })
    @Test fun `acknowledgement crosses a receive window during incomplete video message`() = runPeer({ socket -> peer(socket) { r,w ->
        setup(r,w)
        w.write(YlRtmpMessage(5,0,0,byteArrayOf(0,0,0,64)))
        assertEquals(3,r.next().type) // Existing handshake/command bytes exceed new window.
        // A 300-byte message, but send only 64 bytes. Client must ACK without completing it.
        val partial=ByteArrayOutputStream().apply { write(6);u24(0);u24(300);write(9);write(byteArrayOf(1,0,0,0));write(ByteArray(52)) }.toByteArray()
        socket.getOutputStream().write(partial);socket.getOutputStream().flush()
        assertEquals(3,r.next().type)
    } }, { t -> assertFailsWith<YlRtmpException> { t.open() } })
    @Test fun `wrong transaction is protocol failure instead of false setup success`() = runPeer({ socket -> peer(socket) { r,w ->
        r.next();command(w,0,"_result",2.0,null,mapOf("code" to "NetConnection.Connect.Success"))
    } }, { t -> assertEquals(YlFailureKind.NETWORK_PROTOCOL_UNSUPPORTED,assertFailsWith<YlRtmpException> { t.open() }.kind) })
    @Test fun `audio and controls alone cannot complete video setup even when paused`() = runPeer({ socket -> peer(socket) { r,w ->
        setup(r,w)
        w.write(YlRtmpMessage(8,1,0,byteArrayOf(0xaf.toByte(),0,0x12,0x10)))
        try { repeat(200) { Thread.sleep(10);w.write(YlRtmpMessage(8,1,it.toLong(),byteArrayOf(0xaf.toByte(),1,1))) } } catch (_:java.io.IOException) { }
    } }, { t -> t.setPlaybackPaused(true);assertEquals(YlFailureKind.RTMP_HANDSHAKE_FAILED,assertFailsWith<YlRtmpException> { t.open() }.kind) })
    @Test fun `close cancels established blocked media read promptly`() {
        val hold=java.util.concurrent.CountDownLatch(1)
        runPeer({ socket -> peer(socket) { r,w ->
            setup(r,w);w.write(YlRtmpMessage(9,1,0,config));w.write(YlRtmpMessage(9,1,1,frame))
            hold.await(2,TimeUnit.SECONDS)
        } }, { t ->
            t.open()
            val executor=Executors.newSingleThreadExecutor()
            val reading=java.util.concurrent.CountDownLatch(1)
            try {
                val result=executor.submit<YlFailureKind>{
                    try { reading.countDown();while(true)t.read(ByteArray(256),0,256);error("ended") }
                    catch(e:YlRtmpException){e.kind}
                }
                assertTrue(reading.await(1,TimeUnit.SECONDS));t.close()
                assertEquals(YlFailureKind.LOAD_CANCELLED,result.get(1,TimeUnit.SECONDS))
            }finally{hold.countDown();executor.shutdownNow()}
        })
    }

    @Test fun `consumer backpressure longer than inactivity does not expire a healthy stream`() = runPeer({ socket -> peer(socket) { r,w ->
        setup(r,w);w.write(YlRtmpMessage(9,1,0,config));w.write(YlRtmpMessage(9,1,1,frame))
        Thread.sleep(250)
        w.write(YlRtmpMessage(9,1,2,frame))
    } }, { t ->
        t.open();Thread.sleep(300) // No read demand for three times the injected deadline.
        val bytes=ByteArray(256)
        assertEquals(13,t.read(bytes,0,bytes.size))
        assertEquals(config.size+15,t.read(bytes,0,bytes.size))
        assertEquals(frame.size+15,t.read(bytes,0,bytes.size))
        assertEquals(frame.size+15,t.read(bytes,0,bytes.size))
    })

    /** Real Core entrypoint + real owned socket/parser; ExoPlayer/device surfaces are mocked.
     * Register an injected short-deadline transport in the real source owner. */
    @Test fun `Core pause freezes an already blocked loader read and resumes same connection`() {
        val release=java.util.concurrent.CountDownLatch(1)
        runPeer({ socket -> peer(socket) { r,w ->
            setup(r,w);w.write(YlRtmpMessage(9,1,0,config));w.write(YlRtmpMessage(9,1,1,frame))
            assertTrue(release.await(2,TimeUnit.SECONDS))
            w.write(YlRtmpMessage(9,1,2,frame))
            Thread.sleep(200)
        } }, { t -> withCore(coreSource=source().copy(locator="rtmp://owned.test/live/key", intent=dev.ylplayer.yl_player_android.pigeon.AndroidStreamIntent.LIVE, format=dev.ylplayer.yl_player_android.pigeon.AndroidMediaFormat.FLV)) { core,player,_ ->
            core.field("active",true)
            val factory=core.javaClass.getDeclaredField("sourceFactory").apply { isAccessible=true }.get(core)
            val owner=factory.javaClass.getDeclaredField("rtmp").apply { isAccessible=true }.get(factory)
            register(owner as YlRtmpDataSources,t)
            t.open();repeat(3) { t.read(ByteArray(256),0,256) }
            val executor=Executors.newSingleThreadExecutor()
            try {
                val read=executor.submit<Int> { t.read(ByteArray(256),0,256) }
                Thread.sleep(25);core.pause();Thread.sleep(250)
                assertFalse(read.isDone,"pause must freeze pending read watchdog")
                org.mockito.Mockito.verify(player).pause()
                core.play();release.countDown()
                assertEquals(frame.size+15,read.get(1,TimeUnit.SECONDS))
                assertEquals(0L,core.mediaEpoch)
                org.mockito.Mockito.verify(player,org.mockito.Mockito.never()).stop()
            } finally { release.countDown();t.close();executor.shutdownNow() }
        } })
    }

    @Suppress("UNCHECKED_CAST")
    private fun register(owner:YlRtmpDataSources,t:YlRtmpTransport) {
        // Invoke the exact factory admission callback with the injected short-deadline socket.
        val dataSource=owner.factory().createDataSource()
        val register=dataSource.javaClass.getDeclaredField("register").apply { isAccessible=true }.get(dataSource) as (YlRtmpTransport)->Unit
        register(t)
    }
    @Test fun `Core pause before registration is inherited and Stop cancels blocked read`() {
        val hold=java.util.concurrent.CountDownLatch(1)
        runPeer({ socket -> peer(socket) { r,w ->
            setup(r,w);w.write(YlRtmpMessage(9,1,0,config));w.write(YlRtmpMessage(9,1,1,frame))
            hold.await(2,TimeUnit.SECONDS)
        } }, { t -> withCore(coreSource=source().copy(locator="rtmp://owned.test/live/key",intent=dev.ylplayer.yl_player_android.pigeon.AndroidStreamIntent.LIVE,format=dev.ylplayer.yl_player_android.pigeon.AndroidMediaFormat.FLV)) { core,_,_ ->
            core.field("active",true);core.pause()
            val factory=core.javaClass.getDeclaredField("sourceFactory").apply { isAccessible=true }.get(core)
            val owner=factory.javaClass.getDeclaredField("rtmp").apply { isAccessible=true }.get(factory) as YlRtmpDataSources
            register(owner,t)
            t.open();repeat(3) { t.read(ByteArray(256),0,256) }
            val executor=Executors.newSingleThreadExecutor()
            try {
                val read=executor.submit<YlFailureKind> { try { t.read(ByteArray(256),0,256);error("unexpected media") } catch(e:YlRtmpException) { e.kind } }
                Thread.sleep(250);assertFalse(read.isDone)
                core.stop();assertEquals(YlFailureKind.LOAD_CANCELLED,read.get(1,TimeUnit.SECONDS))
            } finally { hold.countDown();t.close();executor.shutdownNow() }
        } })
    }
    @Test fun `pause preserves elapsed inactivity instead of granting a new full allowance`() {
        val hold=java.util.concurrent.CountDownLatch(1)
        runPeer({ socket -> peer(socket) { r,w ->
            setup(r,w);w.write(YlRtmpMessage(9,1,0,config));w.write(YlRtmpMessage(9,1,1,frame))
            hold.await(3,TimeUnit.SECONDS)
        } }, { t ->
            t.open();repeat(3) { t.read(ByteArray(256),0,256) }
            val executor=Executors.newSingleThreadExecutor()
            try {
                val read=executor.submit<YlFailureKind> { try { t.read(ByteArray(256),0,256);error("unexpected media") } catch(e:YlRtmpException) { e.kind } }
                Thread.sleep(300);t.setPlaybackPaused(true);Thread.sleep(650)
                assertFalse(read.isDone)
                val start=System.nanoTime();t.setPlaybackPaused(false)
                assertEquals(YlFailureKind.RTMP_DISCONNECTED,read.get(350,TimeUnit.MILLISECONDS))
                assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime()-start)<350)
            } finally { hold.countDown();t.close();executor.shutdownNow() }
        }, inactivityMs=500)
    }

}
