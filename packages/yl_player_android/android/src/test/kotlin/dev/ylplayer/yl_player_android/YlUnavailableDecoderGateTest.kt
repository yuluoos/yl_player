package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import kotlinx.coroutines.runBlocking
import kotlin.test.*

class YlUnavailableDecoderGateTest {
    @Test fun networkFailureSurvivesTheReadinessFuture() = runBlocking {
        val gate = YlInitializedDecoderGate(AndroidDecoderPolicy.SYSTEM_DEFAULT)
        gate.fail(YlFailureKind.NETWORK_FAILED, YlHttpStatusException(503))
        val failure = assertFailsWith<YlBoundaryException> { gate.ready.await() }
        assertEquals("network.http_status.503", YlFailureMapper(YlSafeDiagnostics {}).toMessage(failure).code)
    }

    @Test fun declaredButUnselectedVideoCannotWaitForAnImpossibleDecoderIdentity() = runBlocking {
        val gate=YlInitializedDecoderGate(AndroidDecoderPolicy.HARDWARE_REQUIRED)
        gate.accept(YlEngineSnapshot(status=AndroidPlaybackStatus.READY,
            videoTracks=listOf(AndroidTrackMessage("av1",AndroidTrackKind.VIDEO,isSelected=false)),
            audioTracks=listOf(AndroidTrackMessage("opus",AndroidTrackKind.AUDIO,isSelected=true))))
        assertTrue(gate.ready.isCompleted,"Unsupported declared video must fail without waiting for decoder initialization")
        val error=assertFailsWith<YlBoundaryException> { gate.ready.await() }
        assertEquals(YlFailureKind.DECODER_UNAVAILABLE,error.kind)
    }
    @Test fun selectedVideoStillWaitsForActualIdentity() {
        val gate=YlInitializedDecoderGate(AndroidDecoderPolicy.HARDWARE_REQUIRED)
        gate.accept(YlEngineSnapshot(status=AndroidPlaybackStatus.READY,
            videoTracks=listOf(AndroidTrackMessage("avc",AndroidTrackKind.VIDEO,isSelected=true))))
        assertFalse(gate.ready.isCompleted)
    }
}
