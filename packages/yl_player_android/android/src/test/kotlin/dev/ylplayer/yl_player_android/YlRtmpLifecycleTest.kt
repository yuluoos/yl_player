package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class YlRtmpLifecycleTest {
    private fun rtmp(id:String, scheme:String="rtmp") = request(id).let { it.copy(source=it.source.copy(locator="$scheme://owned.test/live/key",intent=AndroidStreamIntent.LIVE,format=AndroidMediaFormat.AUTOMATIC)) }
    @Test fun `coordinator preserves unsupported protocol before creating engine`() = runTest {
        val f=SessionFixture(StandardTestDispatcher(testScheduler))
        assertEquals(YlFailureKind.NETWORK_PROTOCOL_UNSUPPORTED, assertFailsWith<YlBoundaryException> { f.coordinator.load(rtmp("secure","rtmps")) }.kind)
        assertTrue(f.engines.isEmpty()); f.finish()
    }
    @Test fun `runtime time seek rejects zero and nonzero before changing intent`() = runTest {
        val f=SessionFixture(StandardTestDispatcher(testScheduler))
        val id=f.coordinator.load(rtmp("live")).sessionId
        for(position in listOf(0L,900L)) assertEquals(YlFailureKind.POLICY_UNSUPPORTED, assertFailsWith<YlBoundaryException> { f.coordinator.seekTo(AndroidSeekCommand(id,position)) }.kind)
        runCurrent()
        assertEquals(0L,f.engines.single().position)
        f.coordinator.onBackground(); runCurrent(); f.coordinator.onForeground(); runCurrent()
        assertEquals(0L,f.engines.single().position)
        f.finish()
    }
    @Test fun `fresh epochs fence stale callbacks and preserve spent automatic budget`() {
        val r=YlRtmpRecovery(); r.committed=true
        assertEquals(500L,r.next(YlFailureKind.RTMP_DISCONNECTED,true))
        val old=r.invalidate()
        repeat(10) { r.invalidate() }
        assertFalse(r.accepts(old)); assertTrue(r.accepts(r.epoch))
        assertEquals(1,r.attempts)
        assertEquals(1000L,r.next(YlFailureKind.RTMP_DISCONNECTED,true))
    }
    @Test fun `Core defers transient failure while paused without reserving and Stop discards it`() = recoveryCore { core,ledger,queue ->
        core.pause()
        assertTrue(core.recover(YlFailureKind.RTMP_DISCONNECTED,true))
        assertEquals(0,ledger.attempts);assertTrue(queue.isEmpty())
        core.play()
        assertEquals(1,ledger.attempts);assertEquals(500L,queue.single().second)
        core.pause();assertTrue(queue.isEmpty())
        core.stop();core.play()
        assertTrue(queue.isEmpty());assertEquals(1,ledger.attempts)
    }
    @Test fun `Core pause retains reserved backoff and rapid play cannot lose or double debit continuation`() = recoveryCore { core,ledger,queue ->
        core.play()
        assertTrue(core.recover(YlFailureKind.RTMP_DISCONNECTED,true))
        val callback=queue.single().first
        org.mockito.Mockito.`when`(android.os.SystemClock.elapsedRealtime()).thenReturn(200L)
        repeat(20) {
            core.pause();assertTrue(queue.isEmpty())
            callback.run() // Simulate an already dequeued cancelled Handler callback.
            core.play();assertEquals(1,queue.size);assertEquals(300L,queue.single().second);assertNotSame(callback,queue.single().first)
            callback.run();assertEquals(1,queue.size) // Old ticket cannot execute after resume.
        }
        assertEquals(1,ledger.attempts)
        val fakeMediaSource=org.mockito.Mockito.mock(androidx.media3.exoplayer.source.MediaSource::class.java)
        val factory=org.mockito.Mockito.mock(YlMediaSourceFactory::class.java) { call ->
            if(call.method.name=="create") fakeMediaSource else org.mockito.Mockito.RETURNS_DEFAULTS.answer(call)
        }
        core.field("sourceFactory",factory)
        val epoch=core.mediaEpoch
        org.mockito.Mockito.mockStatic(android.net.Uri::class.java).use { uri ->
            uri.`when`<android.net.Uri> { android.net.Uri.parse("rtmp://owned.test/live/key") }.thenReturn(org.mockito.Mockito.mock(android.net.Uri::class.java))
            queue.removeAt(0).first.run()
        }
        assertTrue(core.mediaEpoch>epoch);assertTrue(queue.isEmpty());assertEquals(1,ledger.attempts)
        val player=core.javaClass.getDeclaredField("exoPlayer").apply { isAccessible=true }.get(core) as androidx.media3.exoplayer.ExoPlayer
        org.mockito.Mockito.verify(player).prepare()
        core.stop();callback.run();assertTrue(queue.isEmpty());assertEquals(1,ledger.attempts)
    }
    @Test fun `Core keeps permanent and exhausted failures terminal while paused`() = recoveryCore { core,ledger,queue ->
        core.pause()
        assertFalse(core.recover(YlFailureKind.RTMP_STREAM_UNAVAILABLE,false))
        repeat(3) { ledger.next(YlFailureKind.RTMP_DISCONNECTED,true) }
        assertFalse(core.recover(YlFailureKind.RTMP_DISCONNECTED,true))
        assertTrue(queue.isEmpty());assertEquals(3,ledger.attempts)
    }
    @Test fun `Stop discards unreserved paused recovery and play does not resurrect it`() = recoveryCore { core,ledger,queue ->
        core.pause();assertTrue(core.recover(YlFailureKind.RTMP_DISCONNECTED,true))
        core.stop();core.play()
        assertEquals(0,ledger.attempts);assertTrue(queue.isEmpty())
    }
    private fun recoveryCore(action:(YlMedia3Core,YlRtmpRecovery,MutableList<Pair<Runnable,Long>>)->Unit) {
        val handler=org.mockito.Mockito.mock(android.os.Handler::class.java)
        val queue=mutableListOf<Pair<Runnable,Long>>()
        org.mockito.Mockito.doAnswer { call -> queue.add((call.arguments[0] as Runnable) to (call.arguments[1] as Long));true }
            .`when`(handler).postDelayed(org.mockito.Mockito.any(Runnable::class.java),org.mockito.Mockito.anyLong())
        org.mockito.Mockito.doAnswer { call -> queue.removeAll { it.first === call.arguments[0] };null }
            .`when`(handler).removeCallbacks(org.mockito.Mockito.any(Runnable::class.java))
        org.mockito.Mockito.doAnswer { queue.clear();null }.`when`(handler).removeCallbacksAndMessages(null)
        withCore(coreSource=rtmp("core").source,coreHandler=handler) { core,_,_ ->
            val ledger=YlRtmpRecovery().apply { committed=true }
            core.field("rtmpRecovery",ledger);core.field("active",true)
            action(core,ledger,queue)
        }
    }
    private fun YlMedia3Core.recover(kind:YlFailureKind, transient:Boolean):Boolean =
        javaClass.getDeclaredMethod("tryRtmpRecovery",androidx.media3.common.PlaybackException::class.java).apply { isAccessible=true }
            .invoke(this,androidx.media3.common.PlaybackException("owned test",YlRtmpException(kind,transient),androidx.media3.common.PlaybackException.ERROR_CODE_IO_UNSPECIFIED)) as Boolean

}
