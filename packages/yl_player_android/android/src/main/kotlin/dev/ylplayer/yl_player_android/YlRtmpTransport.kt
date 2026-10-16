package dev.ylplayer.yl_player_android

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.ScheduledFuture

/** Own the cancellable socket before DNS. One transport is one attempt and one FLV epoch. */
internal class YlRtmpTransport(
    private val address: YlRtmpAddress,
    private val dns: YlRtmpDns = YlRtmpDns(),
    private val setupMs: Long = 10000,
    private val inactivityMs: Long = 15000,
    private val socket: Socket = Socket(),
    private val networkBytes: YlNetworkByteCounter? = null,
) : AutoCloseable {
    companion object {
        private val timers = ScheduledThreadPoolExecutor(1) { r -> Thread(r,"yl-rtmp-deadlines").apply { isDaemon=true } }.apply { removeOnCancelPolicy = true }
    }
    @Volatile private var cancelled = false
    @Volatile private var expired = false
    @Volatile private var established = false
    @Volatile private var deadline = Long.MAX_VALUE
    private var alarm: ScheduledFuture<*>? = null
    private lateinit var reader: YlRtmpChunkReader
    private lateinit var writer: YlRtmpChunkWriter
    private lateinit var flow: YlRtmpFlowControl
    private val flv = YlRtmpFlvStream()
    private var streamId = 0
    private var stage = 0
    private var bytesReceived = 0L
    private var lastAcknowledged = 0L
    private var ackWindow = 0L
    internal val receivedBytes get() = bytesReceived
    internal val acknowledgedBytes get() = lastAcknowledged
    internal val acknowledgementWindowBytes get() = ackWindow
    private var videoConfig: ByteArray? = null
    private var audioConfig: ByteArray? = null
    private val initial = ArrayDeque<ByteArray>()
    private var current: ByteArray? = null
    private var offset = 0
    private var playbackPaused = false
    private var readActive = false
    private var mediaRemainingNanos = TimeUnit.MILLISECONDS.toNanos(inactivityMs)
    private fun now() = System.nanoTime()
    private fun arm(durationMs: Long) = armNanos(TimeUnit.MILLISECONDS.toNanos(durationMs))
    @Synchronized private fun armNanos(duration: Long) {
        checkState()
        deadline = now() + duration
        alarm?.cancel(false)
        alarm = timers.schedule({ synchronized(this) {
            if (!cancelled && now() >= deadline) { expired = true; runCatching { socket.close() } }
        } }, duration, TimeUnit.NANOSECONDS)
    }
    /** Consumer think/pause time does not consume the inactivity allowance. Keep nano precision
     * across short reads: a rapid config flood must not round every active interval to zero. */
    @Synchronized private fun suspendDemand() {
        if (!established) return
        if (deadline != Long.MAX_VALUE) mediaRemainingNanos = (deadline - now()).coerceAtLeast(0)
        alarm?.cancel(false); alarm = null; deadline = Long.MAX_VALUE
    }
    @Synchronized private fun resumeDemand() {
        readActive = true
        if (!established || playbackPaused) return
        armNanos(mediaRemainingNanos)
    }
    @Synchronized private fun endDemand() { suspendDemand(); readActive = false }
    /** Independent of loader demand: ExoPlayer.pause does not cancel an outstanding read. */
    @Synchronized fun setPlaybackPaused(paused: Boolean) {
        if (playbackPaused == paused) return
        playbackPaused = paused
        if (!established || cancelled || expired) return // Setup is always absolute.
        if (paused) suspendDemand() else if (readActive) resumeDemand()
    }
    @Synchronized private fun mediaProgress() {
        checkState()
        alarm?.cancel(false); alarm = null; deadline = Long.MAX_VALUE
        established = true
        mediaRemainingNanos = TimeUnit.MILLISECONDS.toNanos(inactivityMs)
        if (readActive && !playbackPaused) armNanos(mediaRemainingNanos)
    }
    private fun checkState() {
        if (cancelled) throw YlRtmpException(YlFailureKind.LOAD_CANCELLED)
        if (expired || now() >= deadline) throw YlRtmpException(if (established) YlFailureKind.RTMP_DISCONNECTED else YlFailureKind.RTMP_HANDSHAKE_FAILED, true)
    }
    private fun <T> guarded(block: () -> T): T {
        try { checkState(); return block() }
        catch (error: Throwable) {
            val safe = if (error is OutOfMemoryError) YlRtmpException(YlFailureKind.RESOURCE_EXHAUSTED) else if (error is YlRtmpException) error else try { checkState(); YlRtmpException(if (established) YlFailureKind.RTMP_DISCONNECTED else YlFailureKind.RTMP_HANDSHAKE_FAILED, true) } catch (typed: YlRtmpException) { typed }
            release(); clearBuffers()
            throw safe
        }
    }
    fun open() = guarded {
        arm(setupMs)
        val addresses = dns.resolve(address.host, ::checkState)
        checkState()
        socket.tcpNoDelay = true
        socket.connect(InetSocketAddress(addresses.first(), address.port), TimeUnit.NANOSECONDS.toMillis(deadline-now()).coerceIn(1,Int.MAX_VALUE.toLong()).toInt())
        checkState()
        val rawInput = socket.getInputStream()
        val output = socket.getOutputStream()
        val input = object: InputStream() {
            override fun read(): Int { val b=ByteArray(1); return if (read(b,0,1)<0) -1 else b[0].toInt() and 255 }
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                checkState()
                val amount = if (ackWindow > 0) minOf(len.toLong(), (ackWindow-(bytesReceived-lastAcknowledged)).coerceAtLeast(1)).toInt() else len
                if (::flow.isInitialized) flow.flush()
                val n=rawInput.read(b,off,amount)
                networkBytes?.received(n.toLong())
                checkState()
                if(n>0) {
                    bytesReceived+=n
                    if(ackWindow>0 && bytesReceived-lastAcknowledged>=ackWindow) {
                        lastAcknowledged=bytesReceived
                        control(3) { u32(bytesReceived and 0xffffffffL) }
                    }
                }
                return n
            }
        }
        handshake(input,output)
        flow = YlRtmpFlowControl(output, initialSent = 3073, check = ::checkState)
        writer = YlRtmpChunkWriter(flow)
        reader = YlRtmpChunkReader(input)
        command(0,"connect",1.0,mapOf("app" to address.app,"tcUrl" to address.tcUrl,"flashVer" to "FMLE/3.0", "fpad" to false,"capabilities" to 15.0,"audioCodecs" to 1024.0,"videoCodecs" to 128.0,"videoFunction" to 1.0,"objectEncoding" to 0.0))
        while (!established) receive()
        suspendDemand()
    }
    private fun handshake(input: InputStream, output: java.io.OutputStream) {
        val c1=ByteArray(1536); SecureRandom().nextBytes(c1); repeat(8) { c1[it]=0 }
        output.write(3); output.write(c1); output.flush(); checkState()
        if(input.u8()!=3) rtmpInvalid()
        val s1=input.exact(1536)
        // C2 must precede the read of S2. Some peers wait for C2 before sending S2.
        output.write(s1); output.flush(); checkState()
        val s2=input.exact(1536)
        if(!s2.copyOfRange(8,1536).contentEquals(c1.copyOfRange(8,1536))) throw YlRtmpException(YlFailureKind.RTMP_HANDSHAKE_INVALID)
    }
    private fun command(stream: Int, vararg values: Any?) { checkState(); writer.write(YlRtmpMessage(20,stream,0,YlRtmpAmf.encode(values.toList()))); checkState() }
    private fun control(type: Int, write: ByteArrayOutputStream.()->Unit) {
        checkState(); writer.write(YlRtmpMessage(type,0,0,ByteArrayOutputStream().apply(write).toByteArray())); checkState()
    }
    private fun receive(): ByteArray? {
        checkState()
        val m=reader.next()
        checkState()
        if (m.type <= 6) {
            if(m.streamId!=0) rtmpInvalid()
            val p=ByteArrayInputStream(m.payload)
            fun size(n:Int) { if(m.payload.size!=n) rtmpInvalid() }
            when(m.type) {
                1 -> { size(4); val n=p.u32(); if(n>65536) rtmpLimit(); reader.setChunkSize(n.toInt()) }
                2 -> { size(4); val id=p.u32(); if(id !in 2..65599) rtmpInvalid(); reader.abort(id.toInt()) }
                3 -> { size(4); flow.acknowledge(p.u32()) }
                4 -> {
                    if(m.payload.size<2) rtmpInvalid()
                    val event=(p.u8() shl 8) or p.u8()
                    when(event) {
                        6 -> { size(6); val stamp=p.u32(); control(4) { write(0); write(7); u32(stamp) } }
                        0,1,2,4 -> { size(6); val id=p.u32(); if(streamId!=0 && id!=streamId.toLong()) rtmpInvalid(); if(event==1) throw YlRtmpException(if(established) YlFailureKind.RTMP_DISCONNECTED else YlFailureKind.RTMP_STREAM_UNAVAILABLE, established) }
                        3 -> size(10)
                        7 -> size(6)
                        else -> rtmpInvalid()
                    }
                }
                5 -> { size(4); ackWindow=p.u32(); if(ackWindow==0L) rtmpInvalid(); if(bytesReceived-lastAcknowledged>=ackWindow) { lastAcknowledged=bytesReceived; control(3) { u32(bytesReceived and 0xffffffffL) } } }
                6 -> { size(5); val window=p.u32(); val mode=p.u8(); flow.bandwidth(window,mode)?.let { effective -> control(5) { u32(effective) } } }
            }
            return null
        }
        if(m.type==20) { onCommand(m); return null }
        if(m.streamId!=streamId || stage<2) rtmpInvalid()
        if(m.type==18) { YlRtmpAmf.decode(m.payload); return null } // no remote duration/seektable for live
        if(stage!=3) rtmpInvalid()
        val tag=flv.accept(m) ?: return null
        if(!established) {
            if(m.type==9 && m.payload[1].toInt()==0) videoConfig=tag
            if(m.type==8 && m.payload[1].toInt()==0) audioConfig=tag
            if(m.type==9 && m.payload[1].toInt()==1 && (m.payload[0].toInt() ushr 4 and 15)==1 && videoConfig!=null) {
                initial.add(flv.header())
                initial.add(checkNotNull(videoConfig)); audioConfig?.let(initial::add); initial.add(tag)
                videoConfig=null; audioConfig=null
                mediaProgress()
            }
            return null
        }
        if (m.payload[1].toInt() == 1) mediaProgress()
        return tag
    }
    private fun onCommand(m:YlRtmpMessage) {
        val v=YlRtmpAmf.decode(m.payload)
        val name=v.getOrNull(0) as? String ?: rtmpInvalid()
        val tx=v.getOrNull(1) as? Double ?: rtmpInvalid()
        if(name=="_error") throw YlRtmpException(YlFailureKind.RTMP_STREAM_UNAVAILABLE)
        when(name) {
            "_result" -> when {
                stage==0 && tx==1.0 && m.streamId==0 -> {
                    val info=v.getOrNull(3) as? Map<*,*> ?: rtmpInvalid()
                    if(info["code"]!="NetConnection.Connect.Success") throw YlRtmpException(YlFailureKind.RTMP_STREAM_UNAVAILABLE)
                    stage=1; command(0,"createStream",2.0,null)
                }
                stage==1 && tx==2.0 && m.streamId==0 -> {
                    val id=v.getOrNull(3) as? Double ?: rtmpInvalid()
                    if(id<1 || id>Int.MAX_VALUE || id%1!=0.0) rtmpInvalid()
                    streamId=id.toInt(); stage=2
                    control(4) { write(0); write(3); u32(streamId.toLong()); u32(1000) }
                    command(streamId,"play",0.0,null,address.playpath,-1.0)
                }
                else -> rtmpInvalid()
            }
            "onStatus" -> {
                if(tx!=0.0 || m.streamId!=streamId || stage<2) rtmpInvalid()
                val info=v.getOrNull(3) as? Map<*,*> ?: rtmpInvalid()
                val code=info["code"] as? String ?: rtmpInvalid()
                when(code) {
                    "NetStream.Play.Start" -> stage=3
                    "NetStream.Play.Reset", "NetStream.Data.Start", "NetStream.Play.PublishNotify" -> Unit
                    else -> throw YlRtmpException(YlFailureKind.RTMP_STREAM_UNAVAILABLE)
                }
                if(info["level"]=="error") throw YlRtmpException(YlFailureKind.RTMP_STREAM_UNAVAILABLE)
            }
            "onBWDone" -> if(m.streamId!=0) rtmpInvalid()
            else -> rtmpInvalid()
        }
    }
    fun read(target:ByteArray, start:Int, length:Int):Int = try { guarded {
        resumeDemand()
        if(length==0) return@guarded 0
        while(current==null) {
            current=if(initial.isNotEmpty()) initial.removeFirst() else receive()
            offset=0
        }
        val bytes=checkNotNull(current)
        val n=minOf(length,bytes.size-offset)
        bytes.copyInto(target,start,offset,offset+n); offset+=n
        if(offset==bytes.size) { current=null; offset=0 }
        n
    } } finally { endDemand() }
    @Synchronized private fun release() {
        alarm?.cancel(false); alarm=null
        runCatching { socket.close() }
        // Parser buffers are worker-owned. External close only closes socket; worker cleanup
        // runs after blocked I/O exits, avoiding concurrent parser state mutation.
    }
    private fun clearBuffers() { if(::flow.isInitialized) flow.clear(); if(::reader.isInitialized) reader.clear(); initial.clear(); current=null; videoConfig=null; audioConfig=null }
    @Synchronized override fun close() { cancelled=true; release() }
    fun finish() { close(); clearBuffers() }
}
