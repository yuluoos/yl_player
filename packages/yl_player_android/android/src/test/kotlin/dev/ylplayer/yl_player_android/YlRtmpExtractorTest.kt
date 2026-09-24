package dev.ylplayer.yl_player_android

import androidx.media3.common.C
import androidx.media3.common.DataReader
import androidx.media3.common.Format
import androidx.media3.common.util.ParsableByteArray
import androidx.media3.extractor.*
import androidx.media3.extractor.flv.FlvExtractor
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.test.*
import org.junit.jupiter.api.Assumptions.assumeTrue

class YlRtmpExtractorTest {
    private class Sink: ExtractorOutput {
        val declared=mutableSetOf<Int>()
        val formats=mutableMapOf<Int,Format>()
        val samples=mutableMapOf<Int,Int>()
        var seekable:Boolean?=null
        var duration:Long?=null
        override fun track(id:Int,type:Int):TrackOutput { declared.add(type);return object:TrackOutput {
            override fun format(format:Format){formats[type]=format}
            override fun sampleData(input:DataReader,length:Int,allowEndOfInput:Boolean,sampleDataPart:Int):Int = input.read(ByteArray(length),0,length)
            override fun sampleData(data:ParsableByteArray,length:Int,sampleDataPart:Int){data.skipBytes(length)}
            override fun sampleMetadata(timeUs:Long,flags:Int,size:Int,offset:Int,cryptoData:TrackOutput.CryptoData?){samples[type]=(samples[type]?:0)+1}
        }
        }
        override fun endTracks()=Unit
        override fun seekMap(map:SeekMap){seekable=map.isSeekable;duration=map.durationUs}
    }
    private fun extract(reader:DataReader, audio:Boolean=true):Sink {
        // Pinned Media3 exposes this override. Enforce the stronger bounds checks without
        // consulting android.os.Build.FINGERPRINT, which is null in plain JVM Android stubs.
        ParsableByteArray.setShouldEnforceLimitOnLegacyMethods(true)
        try {
        val input=DefaultExtractorInput(reader,0,C.LENGTH_UNSET.toLong())
        val e=FlvExtractor();val s=Sink();e.init(s)
        repeat(2000){
            if(e.read(input,PositionHolder())==Extractor.RESULT_END_OF_INPUT) return s
            if((s.samples[C.TRACK_TYPE_VIDEO]?:0)>=20 && (!audio || (s.samples[C.TRACK_TYPE_AUDIO]?:0)>=20)) return s
        }
        error("bounded extractor sample gate not reached")
        } finally { ParsableByteArray.setShouldEnforceLimitOnLegacyMethods(null) }
    }
    private fun verify(s:Sink){
        assertEquals(s.declared,s.formats.keys,"Every declared track must have a format before Media3 preparation can finish")
        assertEquals("video/avc",s.formats[C.TRACK_TYPE_VIDEO]?.sampleMimeType)
        assertEquals("audio/mp4a-latm",s.formats[C.TRACK_TYPE_AUDIO]?.sampleMimeType)
        assertTrue((s.samples[C.TRACK_TYPE_VIDEO]?:0)>=20)
        assertTrue((s.samples[C.TRACK_TYPE_AUDIO]?:0)>=20)
        assertEquals(false,s.seekable);assertEquals(C.TIME_UNSET,s.duration)
        println("AVC samples=${s.samples[C.TRACK_TYPE_VIDEO]}, AAC samples=${s.samples[C.TRACK_TYPE_AUDIO]}, seekable=${s.seekable}, duration=${s.duration}")
    }
    @Test fun `real AVC AAC fixture passes owned FLV adapter into pinned Media3 extractor`() {
        val root=generateSequence(File(checkNotNull(System.getProperty("user.dir")))) { it.parentFile }.first { File(it,"tool/consumer_fixtures/apple_flutter/Resources/h264_aac.flv").exists() }
        val bytes=ByteArrayInputStream(File(root,"tool/consumer_fixtures/apple_flutter/Resources/h264_aac.flv").readBytes())
        bytes.exact(13)
        val f=YlRtmpFlvStream();val output=ByteArrayOutputStream();output.write(YlRtmpFlvStream.HEADER)
        while(bytes.available()>0){
            val type=bytes.u8();val size=bytes.u24();val low=bytes.u24();val time=low.toLong() or (bytes.u8().toLong() shl 24)
            bytes.u24();val payload=bytes.exact(size);bytes.u32()
            f.accept(YlRtmpMessage(type,1,time,payload))?.let(output::write)
        }
        val input=ByteArrayInputStream(output.toByteArray())
        verify(extract(DataReader { b,o,n -> input.read(b,o,n) }))
    }
    @Test fun `independent MediaMTX peer feeds AVC AAC samples to pinned extractor`() {
        val port=System.getenv("YL_RTMP_PEER_PORT")?.toIntOrNull()
        assumeTrue(port!=null,"Optional independent owned loopback peer is not running")
        val t=YlRtmpTransport(YlRtmpSourcePolicy.parse("rtmp://127.0.0.1:$port/live/owned"))
        try { t.open();verify(extract(DataReader(t::read))) } finally { t.finish() }
        val missing=YlRtmpTransport(YlRtmpSourcePolicy.parse("rtmp://127.0.0.1:$port/live/missing"))
        // This peer closes TCP without an AMF denial for absent streams. Do not infer a denial from its log.
        try { assertEquals(YlFailureKind.RTMP_HANDSHAKE_FAILED,assertFailsWith<YlRtmpException>{missing.open()}.kind) } finally { missing.finish() }
    }
    @Test fun `independent video-only peer formats every declared track`() {
        val port=System.getenv("YL_RTMP_PEER_PORT")?.toIntOrNull()
        assumeTrue(port!=null,"Optional independent owned loopback peer is not running")
        val t=YlRtmpTransport(YlRtmpSourcePolicy.parse("rtmp://127.0.0.1:$port/live/video"))
        try {
            t.open();val sink=extract(DataReader(t::read),audio=false)
            assertEquals(setOf(C.TRACK_TYPE_VIDEO),sink.declared)
            assertEquals(sink.declared,sink.formats.keys)
            assertTrue((sink.samples[C.TRACK_TYPE_VIDEO]?:0)>=20)
            assertEquals(false,sink.seekable);assertEquals(C.TIME_UNSET,sink.duration)
            println("video-only AVC samples=${sink.samples[C.TRACK_TYPE_VIDEO]}, all declared tracks formatted=${sink.formats.keys==sink.declared}")
        }finally{t.finish()}
    }
    @Test fun `independent peer transfers more than three negotiated ACK windows`() {
        val port=System.getenv("YL_RTMP_PEER_PORT")?.toIntOrNull()
        assumeTrue(port!=null,"Optional independent owned loopback peer is not running")
        val t=YlRtmpTransport(YlRtmpSourcePolicy.parse("rtmp://127.0.0.1:$port/live/burst"))
        val start=System.nanoTime();var bytes=0L
        try {
            t.open();val buffer=ByteArray(65536)
            while(bytes<8L*1024*1024){
                assertTrue(System.nanoTime()-start<45_000_000_000L,"bounded peer transfer exceeded 45 seconds")
                bytes+=t.read(buffer,0,buffer.size)
            }
            assertTrue(t.acknowledgementWindowBytes > 0)
            assertTrue(t.acknowledgedBytes >= t.acknowledgementWindowBytes * 3)
            println("independent sustained FLV bytes=$bytes, RTMP received=${t.receivedBytes}, window=${t.acknowledgementWindowBytes}, ACK bytes=${t.acknowledgedBytes}, elapsedMs=${(System.nanoTime()-start)/1_000_000}")
        }finally{t.finish()}
    }

}
