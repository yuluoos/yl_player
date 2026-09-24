package dev.ylplayer.yl_player_android
import java.io.ByteArrayOutputStream
import kotlin.test.*

class YlRtmpFlowControlTest {
    @Test fun `hard soft dynamic bandwidth bounds outstanding bytes and ACK drains pending bytes`() {
        val bytes=ByteArrayOutputStream();val f=YlRtmpFlowControl(bytes)
        assertEquals(4L,f.bandwidth(4,0));f.write(ByteArray(8){it.toByte()});f.flush()
        assertEquals(4,bytes.size());assertEquals(4,f.pendingBytes)
        f.acknowledge(4);assertEquals(8,bytes.size());assertEquals(0,f.pendingBytes)
        assertEquals(2L,f.bandwidth(2,1));assertNull(f.bandwidth(100,2))
        f.write(byteArrayOf(8,9));f.flush();assertEquals(8,bytes.size())
        f.acknowledge(8);assertEquals(10,bytes.size())
        assertEquals(6L,f.bandwidth(6,0));assertEquals(8L,f.bandwidth(8,2))
    }
    @Test fun `ACK unsigned wrap is accepted and future ACK is invalid`() {
        val f=YlRtmpFlowControl(ByteArrayOutputStream(),initialSent=0xfffffff0L)
        f.acknowledge(0xfffffff0L);f.write(ByteArray(32));f.flush();f.acknowledge(16)
        assertEquals(0L,f.outstandingBytes)
        assertEquals(YlFailureKind.NETWORK_PROTOCOL_UNSUPPORTED,assertFailsWith<YlRtmpException>{f.acknowledge(17)}.kind)
    }
    @Test fun `pending output is capped before allocation and clear releases queued contents`() {
        val f=YlRtmpFlowControl(ByteArrayOutputStream());f.bandwidth(1,0)
        f.write(1);f.flush();f.write(ByteArray(65536))
        assertEquals(65536,f.pendingBytes)
        assertEquals(YlFailureKind.RESOURCE_EXHAUSTED,assertFailsWith<YlRtmpException>{f.write(2)}.kind)
        f.clear();assertEquals(0,f.pendingBytes)
    }
}
