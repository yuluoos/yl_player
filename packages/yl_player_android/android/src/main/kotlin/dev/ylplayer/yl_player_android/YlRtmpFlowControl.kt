package dev.ylplayer.yl_player_android

import java.io.OutputStream

/** Single reader-thread control outbox. Never recursively read a chunk while sending a reply.
 * A fixed 64 KiB ring holds pending bytes when the peer's unacknowledged-byte window is full.
 * Reads continue so peer ACKs can release credit; the transport deadline bounds a silent peer.
 */
internal class YlRtmpFlowControl(private val output:OutputStream, initialSent:Long=0,
    private val check:()->Unit={}) : OutputStream() {
    private var queue=ByteArray(65536)
    private var head=0
    var pendingBytes=0;private set
    private var sent=initialSent
    private var acknowledged=0L
    private var window:Long?=null
    private var previousLimit=2
    val outstandingBytes get()=sent-acknowledged
    fun bandwidth(value:Long,mode:Int):Long? {
        if(value !in 1..0xffffffffL || mode !in 0..2) rtmpInvalid()
        val effective=when(mode){0->value;1->minOf(window?:value,value);else->if(previousLimit==0)value else return null}
        previousLimit=if(mode==2)0 else mode
        val changed=window!=effective;window=effective
        return if(changed)effective else null
    }
    fun acknowledge(sequence:Long) {
        if(sequence !in 0..0xffffffffL) rtmpInvalid()
        val delta=(sequence-(acknowledged and 0xffffffffL)) and 0xffffffffL
        if(delta>outstandingBytes) rtmpInvalid()
        acknowledged+=delta;flush()
    }
    override fun write(value:Int) {
        check()
        if(pendingBytes==queue.size){flush();if(pendingBytes==queue.size)rtmpLimit()}
        queue[(head+pendingBytes)%queue.size]=value.toByte();pendingBytes++
    }
    override fun write(bytes:ByteArray,offset:Int,length:Int) {
        check()
        if(length>queue.size-pendingBytes){flush();if(length>queue.size-pendingBytes)rtmpLimit()}
        var copied=0
        while(copied<length){
            val tail=(head+pendingBytes)%queue.size
            val n=minOf(length-copied,queue.size-tail)
            bytes.copyInto(queue,tail,offset+copied,offset+copied+n);pendingBytes+=n;copied+=n
        }
    }
    override fun flush() {
        check()
        while(pendingBytes>0){
            val credit=window?.let{(it-outstandingBytes).coerceAtLeast(0)}?:Long.MAX_VALUE
            val count=minOf(pendingBytes.toLong(),(queue.size-head).toLong(),credit).toInt()
            if(count==0)break
            output.write(queue,head,count);check()
            head=(head+count)%queue.size;pendingBytes-=count;sent+=count
        }
        output.flush();check()
    }
    fun clear(){queue=ByteArray(0);head=0;pendingBytes=0}
}
