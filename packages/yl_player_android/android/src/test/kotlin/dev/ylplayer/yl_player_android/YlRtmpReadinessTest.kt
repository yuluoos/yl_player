package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class YlRtmpReadinessTest {
    private val snapshot=YlEngineSnapshot(status=AndroidPlaybackStatus.READY,
        videoTracks=listOf(AndroidTrackMessage("video",AndroidTrackKind.VIDEO,isSelected=true)),
        decoderMode=AndroidDecoderMode.HARDWARE,decoderIdentity="verified-hardware",reachedReady=true)
    @Test fun `automatic epoch replacement resolves existing restore waiter with fresh decoder evidence`() = runTest {
        val gate=YlInitializedDecoderGate(AndroidDecoderPolicy.HARDWARE_REQUIRED)
        gate.reset();gate.resetForEpoch()
        val restoreWaiter=gate.ready
        val operation=async { runCatching { withTimeout(1000){restoreWaiter.await()} } };runCurrent()
        val budget=YlRtmpRecovery().apply{committed=true}
        assertEquals(500L,budget.next(YlFailureKind.RTMP_HANDSHAKE_FAILED,true))
        gate.resetForEpoch()
        gate.accept(snapshot.copy(decoderMode=AndroidDecoderMode.UNKNOWN,decoderIdentity=null))
        assertFalse(operation.isCompleted)
        gate.accept(snapshot);runCurrent()
        assertTrue(operation.await().isSuccess,"Retry READY must complete the original operation waiter")
    }
    @Test fun `terminal failure after an automatic epoch reaches original operation waiter`() = runTest {
        val gate=YlInitializedDecoderGate(AndroidDecoderPolicy.SYSTEM_DEFAULT)
        gate.reset();val before=gate.ready
        gate.resetForEpoch();gate.fail(YlFailureKind.RTMP_STREAM_UNAVAILABLE)
        val result=runCatching { withTimeout(1000){before.await()} }
        assertEquals(YlFailureKind.RTMP_STREAM_UNAVAILABLE,(result.exceptionOrNull() as? YlBoundaryException)?.kind)
    }
    @Test fun `completed epoch never supplies readiness to the next epoch`() {
        val gate=YlInitializedDecoderGate(AndroidDecoderPolicy.HARDWARE_REQUIRED)
        gate.accept(snapshot);val prior=gate.ready
        gate.resetForEpoch()
        assertNotSame(prior,gate.ready);assertFalse(gate.ready.isCompleted)
        gate.accept(snapshot.copy(decoderMode=AndroidDecoderMode.UNKNOWN,decoderIdentity=null))
        assertFalse(gate.ready.isCompleted)
    }
    @Test fun `committed coordinator foreground restore completes through automatic recovery epoch`() = runTest {
        val dispatcher=StandardTestDispatcher(testScheduler)
        val fake=FakeSessionEngine()
        val gate=YlInitializedDecoderGate(AndroidDecoderPolicy.HARDWARE_REQUIRED)
        val recovery=YlRtmpRecovery()
        val started=CompletableDeferred<Deferred<YlEngineSnapshot>>()
        var restored=0
        val engine=object:YlPlaybackEngineAdapter by fake {
            override fun markCommitted(){recovery.committed=true}
            override suspend fun restore(point:YlEngineRestorePoint,output:YlSessionVideoOutput){
                fake.restore(point,output)
                gate.reset();gate.resetForEpoch()
                val waiter=gate.ready;started.complete(waiter)
                waiter.await();restored++
            }
        }
        val output=FakeSessionOutput()
        val coordinator=YlSessionCoordinator(77,sessionOptions,output,YlPlaybackEngineFactory { identity,_,_ ->
            fake.identity=identity;engine
        },dispatcher,clockMs={testScheduler.currentTime}).also {
            it.bindLeases(YlDecoderLeaseCoordinator(dispatcher){testScheduler.currentTime});it.attach(SessionEvents())
        }
        val source=request("rtmp-restoration").let { it.copy(source=it.source.copy(locator="rtmp://owned.test/live/x",intent=AndroidStreamIntent.LIVE,format=AndroidMediaFormat.AUTOMATIC)) }
        coordinator.load(source);assertTrue(recovery.committed)
        coordinator.onBackground();runCurrent();coordinator.onForeground();runCurrent()
        val waiter=started.await()
        assertEquals(500L,recovery.next(YlFailureKind.RTMP_HANDSHAKE_FAILED,true))
        gate.resetForEpoch();assertSame(waiter,gate.ready)
        gate.accept(snapshot.copy(decoderIdentity=null,decoderMode=AndroidDecoderMode.UNKNOWN));runCurrent();assertEquals(0,restored)
        gate.accept(snapshot);runCurrent();assertEquals(1,restored)
        advanceTimeBy(16000);runCurrent()
        assertNotEquals(AndroidPlaybackStatus.FAILED,coordinator.initialState.status)
        assertEquals(1,recovery.attempts)
        coordinator.close().await();assertEquals(1,output.releases)
    }

}
