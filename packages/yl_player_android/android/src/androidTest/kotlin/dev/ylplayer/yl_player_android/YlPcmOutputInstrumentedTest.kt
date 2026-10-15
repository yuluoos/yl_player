package dev.ylplayer.yl_player_android

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.*

/** Samples the production JNI decoder's PCM before AudioTrack. This proves
 * conversion/downmix and seek markers, not speakers or physical A/V latency. */
class YlPcmOutputInstrumentedTest {
    private fun open(name: String): YlFfmpegSession {
        val bytes = InstrumentationRegistry.getInstrumentation().context.assets.open("format_matrix/$name.mkv").use { it.readBytes() }
        return YlFfmpegSession.open(object : YlNativeByteSource {
            var position = 0
            override fun read(target: ByteBuffer): Int {
                val n = minOf(target.remaining(), bytes.size-position)
                target.put(bytes,position,n);position+=n;return n
            }
            override fun seek(offset: Long, whence: Int): Long {
                if (whence and 0x10000 != 0) return bytes.size.toLong()
                val next = when (whence and 3) { 0 -> offset; 1 -> position+offset; 2 -> bytes.size+offset; else -> return -3 }
                if (next !in 0L..bytes.size.toLong()) return -3
                position=next.toInt();return next
            }
            override fun cancel() {}
            override fun close() {}
        })
    }
    private fun amplitude(samples: List<Double>, hz: Double, rate: Int): Double {
        var real=0.0;var imaginary=0.0
        samples.forEachIndexed { i,value -> val phase=2*PI*hz*i/rate;real+=value*cos(phase);imaginary+=value*sin(phase) }
        return 2*hypot(real,imaginary)/samples.size
    }
    private fun check(name: String, surround: Boolean = false) {
        open(name).use { session ->
            val stream=session.mediaInfo.streams.single { it.kind==YlNativeStreamKind.AUDIO }
            assertTrue(session.configureSoftwareAudio(stream.index))
            for (target in listOf(0L,2_250_000L,1_250_000L,0L)) {
                assertTrue(session.seekTo(target))
                val left=mutableListOf<Double>();val right=mutableListOf<Double>()
                val start=target+250_000;val end=target+650_000
                var rate=0
                while (true) {
                    val packet=session.readPacket() ?: break
                    packet.use {
                        if (it.streamIndex==stream.index) session.decodeSoftwareAudio(it)?.let { pcm ->
                            assertEquals(2,pcm.channelCount); rate=pcm.sampleRate
                            val data=ByteBuffer.wrap(pcm.data).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                            var frame=0
                            while (data.remaining()>=2) {
                                val l=data.get()/32768.0;val r=data.get()/32768.0
                                val pts=pcm.presentationTimeUs+frame*1_000_000L/rate;frame++
                                if (pts in start until end) {left+=l;right+=r}
                            }
                        }
                    }
                }
                assertEquals(48000,rate)
                assertTrue("Missing PCM at $name/$target",left.size>=18000)
                val second=(start/1_000_000).toInt();val base=440.0+second*220
                val l=amplitude(left,base,rate);val r=amplitude(right,base+55,rate)
                assertTrue("Missing left tone",l>0.008);assertTrue("Missing right tone",r>0.008)
                assertTrue("Swapped/leaked right channel",amplitude(left,base+55,rate)<l*0.1)
                assertTrue("Swapped/leaked left channel",amplitude(right,base,rate)<r*0.1)
                if (surround) {
                    // FFmpeg's stereo matrix retains center and the appropriate
                    // surround at sqrt(1/2); LFE is excluded from this downmix.
                    for ((samples,own,rear) in listOf(Triple(left,l,4),Triple(right,r,5))) {
                        assertEquals(sqrt(0.5),amplitude(samples,base+110,rate)/own,0.08)
                        assertEquals(sqrt(0.5),amplitude(samples,base+rear*55,rate)/own,0.08)
                        assertTrue(amplitude(samples,60.0+second*10,rate)<own*0.1)
                    }
                }
                android.util.Log.i("P03_PCM","$name target=$target frames=${left.size} rate=$rate channels=2 markers=true")
                // Recreate the real converter at the same stream boundary.
                assertTrue(session.configureSoftwareAudio(stream.index))
            }
        }
    }
    @Test fun ac3SurroundDownmixAndBidirectionalSeek() = check("mkv-avc-ac3-51",true)
    @Test fun eac3ChannelsAndBidirectionalSeek() = check("mkv-avc-eac3")
    @Test fun dtsChannelsAndBidirectionalSeek() = check("mkv-avc-dts")
    @Test fun flacChannelsAndBidirectionalSeek() = check("mkv-avc-flac")
}
