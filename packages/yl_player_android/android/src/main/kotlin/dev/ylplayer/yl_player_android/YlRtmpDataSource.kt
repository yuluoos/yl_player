package dev.ylplayer.yl_player_android

import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec

/** Source lifetime ownership is independent of the Media3 loader's open/close lifecycle. */
@OptIn(UnstableApi::class)
internal class YlRtmpDataSources(private val locator:String, private val networkBytes: YlNetworkByteCounter? = null) {
    private val active=mutableSetOf<YlRtmpTransport>()
    private var generation=0L
    private var playbackPaused=false
    @Synchronized fun factory():DataSource.Factory {
        val epoch=generation
        return DataSource.Factory { YlRtmpDataSource(locator, { transport ->
            synchronized(this) {
                if(epoch!=generation) { transport.close(); throw YlRtmpException(YlFailureKind.LOAD_CANCELLED) }
                transport.setPlaybackPaused(playbackPaused)
                active.add(transport)
            }
        }, { transport -> synchronized(this) { active.remove(transport) } }, networkBytes) }
    }
    @Synchronized fun setPlaybackPaused(paused:Boolean) {
        playbackPaused=paused
        active.forEach { it.setPlaybackPaused(paused) }
    }
    @Synchronized fun cancelAll() { generation++; active.forEach { it.close() }; active.clear() }
}

@OptIn(UnstableApi::class)
internal class YlRtmpDataSource(private val locator:String, private val register:(YlRtmpTransport)->Unit,
    private val unregister:(YlRtmpTransport)->Unit, private val networkBytes: YlNetworkByteCounter? = null) : BaseDataSource(true) {
    @Volatile private var transport:YlRtmpTransport?=null
    private var opened=false
    override fun open(dataSpec:DataSpec):Long {
        if(dataSpec.position!=0L) throw YlRtmpException(YlFailureKind.POLICY_UNSUPPORTED)
        transferInitializing(dataSpec)
        val owner=YlRtmpTransport(YlRtmpSourcePolicy.parse(locator), networkBytes = networkBytes)
        transport=owner
        try {
            register(owner) // Published before DNS, TCP, handshake or reads.
            owner.open()
            opened=true; transferStarted(dataSpec)
            return C.LENGTH_UNSET.toLong()
        } catch(e:Exception) { owner.finish(); unregister(owner); transport=null; throw e }
    }
    override fun getUri():Uri? = if(transport!=null) Uri.parse(locator) else null
    override fun read(buffer:ByteArray, offset:Int, length:Int):Int {
        val owner=transport ?: throw YlRtmpException(YlFailureKind.LOAD_CANCELLED)
        return try { owner.read(buffer,offset,length).also { if(it>0) bytesTransferred(it) } }
        catch(e:Exception) { owner.finish(); throw e }
    }
    override fun close() {
        val owner=transport; transport=null
        owner?.let { it.finish(); unregister(it) }
        if(opened) { opened=false; transferEnded() }
    }
}
