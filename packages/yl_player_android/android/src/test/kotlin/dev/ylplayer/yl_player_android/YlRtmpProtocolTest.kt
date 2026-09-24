package dev.ylplayer.yl_player_android

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import kotlin.test.*

class YlRtmpProtocolTest {
    private fun message(type: Int, data: ByteArray, time: Long = 0, stream: Int = 1, cs: Int = 6): ByteArray = ByteArrayOutputStream().also { YlRtmpChunkWriter(it).write(YlRtmpMessage(type, stream, time, data), cs) }.toByteArray()
    @Test fun `chunk reader handles partial input extended timestamp and multi chunks`() {
        val payload = ByteArray(401) { it.toByte() }
        val bytes = message(9, payload, 0x1000000)
        val reader = YlRtmpChunkReader(object: ByteArrayInputStream(bytes) { override fun read(b: ByteArray, o: Int, n: Int) = super.read(b, o, minOf(n, 1)) })
        val got = reader.next()
        assertEquals(0x1000000L, got.timestamp)
        assertContentEquals(payload, got.payload)
    }
    @Test fun `fmt zero one two three timestamps inherit and advance`() {
        val bytes = message(9, byteArrayOf(1), 10) + byteArrayOf(0x46,0,0,5,0,0,1,9,2, 0x86.toByte(),0,0,7,3, 0xc6.toByte(),4)
        val r = YlRtmpChunkReader(ByteArrayInputStream(bytes))
        assertEquals(listOf(10L,15L,22L,29L), (1..4).map { r.next().timestamp })
    }
    @Test fun `bounds reject before allocation and abort releases accounting`() {
        val r = YlRtmpChunkReader(ByteArrayInputStream(byteArrayOf(6,0,0,0,0x40,0,1,9,1,0,0,0)))
        assertEquals(YlFailureKind.RESOURCE_EXHAUSTED, assertFailsWith<YlRtmpException> { r.next() }.kind)
        assertFailsWith<YlRtmpException> { r.setChunkSize(65537) }
        assertFailsWith<YlRtmpException> { r.setChunkSize(0) }
    }
    @Test fun `AMF real object vectors preserve types and enforce recursion entries and strings`() {
        val values = listOf<Any?>("connect", 1.0, mapOf("app" to "live", "fpad" to false, "objectEncoding" to 0.0), null)
        assertEquals(values, YlRtmpAmf.decode(YlRtmpAmf.encode(values)))
        assertFailsWith<YlRtmpException> { YlRtmpAmf.decode(byteArrayOf(2,0x7f,0xff.toByte())) }
        var deep: Any? = null
        repeat(10) { deep = mapOf("a" to deep) }
        assertFailsWith<YlRtmpException> { YlRtmpAmf.decode(YlRtmpAmf.encode(listOf(deep))) }
        assertFailsWith<YlRtmpException> { YlRtmpAmf.decode(ByteArray(257) { 5 }) }
        assertFailsWith<YlRtmpException> { YlRtmpAmf.decode(byteArrayOf(17)) }
    }
    @Test fun `AVC AAC preserve payload composition and timestamp but reject enhanced codecs`() {
        val flv = YlRtmpFlvStream()
        val avc = byteArrayOf(0x17,0,0,0,0,1,0x64,0,0x1f,0xff.toByte(),0xe1.toByte(),0,1,0x67,1,0,1,0x68)
        assertNotNull(flv.accept(YlRtmpMessage(9,1,100,avc)))
        val frame = byteArrayOf(0x17,1,0xff.toByte(),0xff.toByte(),0xf0.toByte(),0,0,0,1,0x65)
        val tag = flv.accept(YlRtmpMessage(9,1,110,frame))!!
        assertContentEquals(frame, tag.copyOfRange(11,11+frame.size))
        assertNotNull(flv.accept(YlRtmpMessage(8,1,100,byteArrayOf(0xaf.toByte(),0,0x12,0x10))))
        assertFailsWith<YlRtmpException> { flv.accept(YlRtmpMessage(9,1,111,byteArrayOf(0x90.toByte(),0,0,0,0))) }
    }
    @Test fun `timestamp resets are per track and force a fresh epoch`() {
        val f = YlRtmpFlvStream()
        val config = byteArrayOf(0x17,0,0,0,0,1,0x64,0,0x1f,0xff.toByte(),0xe1.toByte(),0,1,0x67,1,0,1,0x68)
        f.accept(YlRtmpMessage(9,1,10000,config))
        f.accept(YlRtmpMessage(8,1,0,byteArrayOf(0xaf.toByte(),0,0x12,0x10)))
        assertFailsWith<YlRtmpException> { f.accept(YlRtmpMessage(9,1,7000,config)) }
    }
    @Test fun `recovery only after commit and has one lifetime budget`() {
        val r = YlRtmpRecovery()
        assertNull(r.next(YlFailureKind.RTMP_DISCONNECTED, true))
        r.committed = true
        assertEquals(500L, r.next(YlFailureKind.RTMP_DISCONNECTED, true))
        assertNull(r.next(YlFailureKind.RTMP_STREAM_UNAVAILABLE, false))
        assertEquals(1000L, r.next(YlFailureKind.RTMP_HANDSHAKE_FAILED, true))
        assertEquals(2000L, r.next(YlFailureKind.RTMP_DISCONNECTED, true))
        assertNull(r.next(YlFailureKind.RTMP_DISCONNECTED, true))
    }
    @Test fun `new fmt3 after fmt0 inherits nonzero timestamp as delta including extended values`() {
        for(time in listOf(17L,0x1000001L)) {
            val continuation=ByteArrayOutputStream().apply { write(0xc6);if(time>=0xffffff) u32(time);write(2) }.toByteArray()
            val r=YlRtmpChunkReader(ByteArrayInputStream(message(9,byteArrayOf(1),time)+continuation))
            assertEquals(time,r.next().timestamp);assertEquals(time*2,r.next().timestamp)
        }
    }
    @Test fun `interleaved chunks reassemble independently and abort drops pending buffer`() {
        val large=message(9,ByteArray(200){1},3)
        val first=large.copyOfRange(0,140)
        val rest=large.copyOfRange(140,large.size)
        val r=YlRtmpChunkReader(ByteArrayInputStream(first+message(8,byteArrayOf(2),7,cs=7)+rest))
        assertEquals(8,r.next().type);assertEquals(200,r.allocatedBytes)
        assertEquals(9,r.next().type);assertEquals(0,r.allocatedBytes)
        val abort=message(2,byteArrayOf(0,0,0,6),stream=0,cs=2)
        val a=YlRtmpChunkReader(ByteArrayInputStream(first+abort+message(9,byteArrayOf(3),8)))
        assertEquals(2,a.next().type);a.abort(6);assertEquals(0,a.allocatedBytes)
        assertContentEquals(byteArrayOf(3),a.next().payload)
    }
    @Test fun `chunk stream count and aggregate reassembly bytes are bounded`() {
        val states=ByteArrayOutputStream()
        for(cs in 2..34) states.write(message(9,byteArrayOf(1),cs=cs))
        val r=YlRtmpChunkReader(ByteArrayInputStream(states.toByteArray()))
        repeat(32){ r.next() }
        assertEquals(YlFailureKind.RESOURCE_EXHAUSTED,assertFailsWith<YlRtmpException>{r.next()}.kind)
        val partial=ByteArrayOutputStream()
        for(cs in 6..8) partial.apply {write(cs);u24(0);u24(4*1024*1024);write(9);write(byteArrayOf(1,0,0,0));write(ByteArray(128))}
        val a=YlRtmpChunkReader(ByteArrayInputStream(partial.toByteArray()))
        assertEquals(YlFailureKind.RESOURCE_EXHAUSTED,assertFailsWith<YlRtmpException>{a.next()}.kind)
        assertEquals(8*1024*1024,a.allocatedBytes)
        a.clear();assertEquals(0,a.allocatedBytes)
    }

    @Test fun `declared codec configurations are immutable within a demux epoch`() {
        val avc=byteArrayOf(0x17,0,0,0,0,1,0x64,0,0x1f,0xff.toByte(),0xe1.toByte(),0,1,0x67,1,0,1,0x68)
        val aac=byteArrayOf(0xaf.toByte(),0,0x12,0x10)
        val f=YlRtmpFlvStream()
        f.accept(YlRtmpMessage(9,1,0,avc));f.accept(YlRtmpMessage(8,1,0,aac));f.header()
        assertNotNull(f.accept(YlRtmpMessage(9,1,1,avc.copyOf())))
        assertNotNull(f.accept(YlRtmpMessage(8,1,1,aac.copyOf())))
        val changedNalLength=avc.copyOf().apply { this[9]=0xfc.toByte() }
        assertEquals("container.rtmp_track_layout_changed",assertFailsWith<YlRtmpException>{f.accept(YlRtmpMessage(9,1,2,changedNalLength))}.kind.code)
        val changedAac=aac.copyOf().apply { this[3]=0x08 }
        assertEquals("container.rtmp_track_layout_changed",assertFailsWith<YlRtmpException>{f.accept(YlRtmpMessage(8,1,2,changedAac))}.kind.code)
    }
    @Test fun `late AAC after video-only header rejects explicitly before tag output`() {
        val f=YlRtmpFlvStream()
        f.accept(YlRtmpMessage(9,1,0,byteArrayOf(0x17,0,0,0,0,1,0x64,0,0x1f,0xff.toByte(),0xe1.toByte(),0,1,0x67,1,0,1,0x68)))
        assertEquals(1,f.header()[4].toInt())
        assertEquals("container.rtmp_track_layout_changed",assertFailsWith<YlRtmpException>{f.accept(YlRtmpMessage(8,1,0,byteArrayOf(0xaf.toByte(),0,0x12,0x10)))}.kind.code)
    }

    @Test fun `valid config reset takes epoch precedence but malformed reset stays permanent`() {
        val config=byteArrayOf(0x17,0,0,0,0,1,0x64,0,0x1f,0xff.toByte(),0xe1.toByte(),0,1,0x67,1,0,1,0x68)
        val f=YlRtmpFlvStream();f.accept(YlRtmpMessage(9,1,10000,config));f.header()
        val changed=config.copyOf().apply { this[9]=0xfc.toByte() }
        val reset=assertFailsWith<YlRtmpException>{f.accept(YlRtmpMessage(9,1,1000,changed))}
        assertEquals(YlFailureKind.RTMP_DISCONNECTED,reset.kind);assertTrue(reset.transient)
        val malformed=config.copyOf().apply { this[9]=0xfe.toByte() }
        val invalid=assertFailsWith<YlRtmpException>{f.accept(YlRtmpMessage(9,1,1000,malformed))}
        assertEquals(YlFailureKind.NETWORK_PROTOCOL_UNSUPPORTED,invalid.kind);assertFalse(invalid.transient)
        assertNotNull(f.accept(YlRtmpMessage(9,1,10001,config)))
    }

}
