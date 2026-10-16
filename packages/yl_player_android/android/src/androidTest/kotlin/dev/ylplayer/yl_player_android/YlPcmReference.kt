package dev.ylplayer.yl_player_android

import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max

/** Pinned host output. Shared FFmpeg ancestry is not an independent decoder
 * implementation; the independent frame table still catches dropped/shifted PCM. */
internal object YlPcmReference {
    private val reference by lazy {
        JSONObject(InstrumentationRegistry.getInstrumentation().context.assets
            .open("pcm_alignment/p03-pcm-reference.json").bufferedReader().use { it.readText() })
    }
    fun verify(track: Int, rows: List<YlNativePcmChunk>, targetUs: Long) {
        val tracks=reference.getJSONArray("tracks")
        val ref=(0 until tracks.length()).map { tracks.getJSONObject(it) }
            .single { it.getInt("track")==track && it.getInt("channels")==2 }
        val packets=ref.getJSONArray("packetFrames")
        val rate=ref.getInt("rate"); val total=ref.getInt("frames")
        val packet=(0 until packets.length()).map { packets.getJSONObject(it) }.first {
            val skipped=max(0L,(targetUs-it.getLong("ptsUs"))*rate+999999)/1000000
            skipped<it.getInt("count")
        }
        val skip=max(0L,(targetUs-packet.getLong("ptsUs"))*rate+999999)/1000000
        val start=packet.getInt("offset")+skip.toInt()
        val firstPts=packet.getLong("ptsUs")+(skip*1000000+rate-1)/rate
        assertTrue("No PCM",rows.isNotEmpty())
        assertTrue("Wrong first PCM: ${rows.first().presentationTimeUs} expected $firstPts",abs(rows.first().presentationTimeUs-firstPts)<=1)
        val expectedPackets=(0 until packets.length()).map { packets.getJSONObject(it) }.mapNotNull {
            val skipped=max(0L,(targetUs-it.getLong("ptsUs"))*rate+999999)/1000000
            if(skipped>=it.getInt("count")) null else Pair(it.getLong("ptsUs")+(skipped*1000000+rate-1)/rate,it.getInt("count")-skipped.toInt())
        }
        assertEquals("Missing/duplicated PCM packet",expectedPackets.size,rows.size)
        rows.zip(expectedPackets).forEach { (row,expected) ->
            assertTrue("PCM timestamp moved",abs(row.presentationTimeUs-expected.first)<=1)
            assertEquals("PCM packet frame count",expected.second,row.data.size/4)
        }
        val samples=rows.flatMap { row ->
            assertEquals(rate,row.sampleRate);assertEquals(2,row.channelCount)
            val data=ByteBuffer.wrap(row.data).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
            List(data.remaining()) { data.get()/32768.0f }
        }
        assertEquals("Lost/duplicated head or tail PCM",total-start,samples.size/2)
        val windows=ref.getJSONArray("windows")
        for (index in listOf(start,total-4096)) {
            val window=(0 until windows.length()).map { windows.getJSONObject(it) }.single {
                it.getInt("start")<=index && it.getInt("start")+it.getInt("count")>=index+4096
            }
            val bytes=android.util.Base64.decode(window.getString("f32le"),android.util.Base64.DEFAULT)
            val expected=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
            var peak=0f
            for(i in 0 until 8192) peak=max(peak,abs(samples[(index-start)*2+i]-expected.get((index-window.getInt("start"))*2+i)))
            assertTrue("track=$track window=$index unshifted PCM error=$peak",peak<0.0002f)
        }
        val last=rows.last();val end=packets.getJSONObject(packets.length()-1)
        assertEquals(end.getLong("ptsUs")+end.getInt("count")*1000000L/rate,
            last.presentationTimeUs+(last.data.size/4)*1000000L/rate)
        android.util.Log.i("P03_PCM_BOUNDARY","track=$track target=$targetUs frames=${samples.size/2} first=$firstPts last=${last.presentationTimeUs} referenceWindows=true")
    }
}
