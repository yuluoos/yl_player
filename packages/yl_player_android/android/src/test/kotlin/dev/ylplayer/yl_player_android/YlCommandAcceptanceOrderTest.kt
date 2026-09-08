package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class YlCommandAcceptanceOrderTest {
    @Test fun `accepted position survives quiescence while its worker is active or queued behind track`() = runTest {
        for (queued in listOf(false, true)) {
            val f = fixture()
            val commandAck = CompletableDeferred<Unit>()
            if (queued) f.engine.commandAcknowledgement = commandAck else f.engine.seekCommandAcknowledgement = commandAck
            val track = if (queued) async { f.a.coordinator.selectAudioTrack(AndroidTrackCommand(f.id, "older")) } else null
            runCurrent()
            f.a.coordinator.seekTo(AndroidSeekCommand(f.id, 100)); runCurrent()
            val activation = f.holdPeer()
            val replacement = async { runCatching { f.b.coordinator.load(request("candidate")) } }; runCurrent()
            assertEquals(1, f.engine.quiesces)
            commandAck.complete(Unit); runCurrent(); track?.await()
            activation.complete(Unit); runCurrent(); assertTrue(replacement.await().isFailure)
            val restoredPosition = f.engine.position
            // A fully applied old seek must not make the next suspension rewind later progress.
            f.engine.position = 800
            f.a.coordinator.onBackground(); runCurrent(); f.a.coordinator.onForeground(); runCurrent()
            val progressedPosition = f.engine.position
            f.engine.position = 900
            val laterActivation = f.holdPeer()
            val laterPeer = async { runCatching { f.b.coordinator.load(request("later-peer")) } }; runCurrent()
            laterActivation.complete(Unit); runCurrent(); assertTrue(laterPeer.await().isFailure)
            val laterPeerPosition = f.engine.position
            f.finish()
            assertEquals(100L, restoredPosition, "queued=$queued")
            assertEquals(800L, progressedPosition, "queued=$queued")
            assertEquals(900L, laterPeerPosition, "queued=$queued")
        }
    }
    @Test fun `worker rejection settles quiescence without losing a newer accepted suspended track`() = runTest {
        val f = fixture()
        val commandAck = CompletableDeferred<Unit>()
        f.engine.commandAcknowledgement = commandAck
        f.engine.trackErrors["older"] = YlBoundaryException(YlFailureKind.SOURCE_MISSING)
        val older = async { runCatching { f.a.coordinator.selectAudioTrack(AndroidTrackCommand(f.id, "older")) } }; runCurrent()
        val activation = f.holdPeer()
        val replacement = async { runCatching { f.b.coordinator.load(request("candidate")) } }; runCurrent()
        f.a.coordinator.selectAudioTrack(AndroidTrackCommand(f.id, "newer"))
        commandAck.complete(Unit); runCurrent()
        assertEquals(YlFailureKind.SOURCE_MISSING, (older.await().exceptionOrNull() as YlBoundaryException).kind)
        activation.complete(Unit); runCurrent(); assertTrue(replacement.await().isFailure)
        val observed = f.engine.currentTrack
        assertTrue(f.a.events.failures.isEmpty())
        f.finish()
        assertEquals("newer", observed)
    }

    @Test fun `host invalidation cancels its worker and settles peer quiescence before late acknowledgement`() = runTest {
        val f = fixture()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val transport = RegistryFixture(dispatcher)
        val host = YlPigeonPlayerHost("order", transport.texture, transport.messenger, f.a.coordinator,
            YlFailureMapper(YlSafeDiagnostics {}), dispatcher, {}, {}, {}, {})
        Dispatchers.setMain(dispatcher)
        try {
            host.install(); host.attach()
            val commandAck = CompletableDeferred<Unit>()
            f.engine.commandAcknowledgement = commandAck
            val replies = mutableListOf<List<*>>()
            val message = AndroidPlayerHostApi.codec.encodeMessage(listOf(AndroidTrackCommand(f.id, "older")))!!.apply { flip() }
            transport.handlers.getValue(transport.channel("order", "selectAudioTrack")).onMessage(message) {
                replies += AndroidPlayerHostApi.codec.decodeMessage(it!!.apply { flip() }) as List<*>
            }
            runCurrent(); assertTrue(replies.isEmpty())
            val activation = f.holdPeer()
            val replacement = async { runCatching { f.b.coordinator.load(request("candidate")) } }; runCurrent()
            assertEquals(1, f.engine.quiesces)
            host.invalidate()
            val close = f.a.coordinator.close()
            runCurrent()
            assertTrue(close.isCompleted)
            assertTrue(replacement.await().isFailure)
            assertEquals(1, replies.size); assertEquals("load.cancelled", replies.single()[0])
            commandAck.complete(Unit); activation.complete(Unit); runCurrent()
            assertEquals(1, replies.size); assertEquals(0, f.engine.restores)
        } finally { host.invalidate(); f.finish(); Dispatchers.resetMain() }
    }

    @Test fun `reviewer probe older active track cannot replace newer accepted suspended track`() = runTest {
        val f = fixture()
        val commandAck = CompletableDeferred<Unit>()
        f.engine.commandAcknowledgement = commandAck
        val older = async { f.a.coordinator.selectAudioTrack(AndroidTrackCommand(f.id, "older")) }
        runCurrent(); assertFalse(older.isCompleted)
        val activation = f.holdPeer()
        val replacement = async { runCatching { f.b.coordinator.load(request("candidate")) } }
        runCurrent(); assertEquals(1, f.engine.quiesces)
        f.a.coordinator.selectAudioTrack(AndroidTrackCommand(f.id, "newer"))
        commandAck.complete(Unit); runCurrent(); older.await()
        activation.complete(Unit); runCurrent(); assertTrue(replacement.await().isFailure)
        val observed = f.engine.currentTrack
        f.finish()
        assertEquals("newer", observed)
    }

    @Test fun `older active live edge cannot replace newer suspended position`() = runTest {
        val f = fixture()
        val commandAck = CompletableDeferred<Unit>()
        f.engine.liveCommandAcknowledgement = commandAck
        val older = async { f.a.coordinator.seekToLiveEdge(AndroidSessionCommand(f.id)) }
        runCurrent(); assertFalse(older.isCompleted)
        val activation = f.holdPeer()
        val replacement = async { runCatching { f.b.coordinator.load(request("candidate")) } }
        runCurrent(); assertEquals(1, f.engine.quiesces)
        f.a.coordinator.seekTo(AndroidSeekCommand(f.id, 500))
        commandAck.complete(Unit); runCurrent(); older.await()
        activation.complete(Unit); runCurrent(); assertTrue(replacement.await().isFailure)
        val position = f.engine.position; val live = f.engine.currentLiveEdge
        f.finish()
        assertEquals(500L, position); assertFalse(live)
    }

    @Test fun `pending position yields only to successfully accepted newer timeline intent`() = runTest {
        for (newer in listOf("live", "position", "rejected")) {
            val f = fixture()
            val commandAck = CompletableDeferred<Unit>()
            f.engine.seekCommandAcknowledgement = commandAck
            f.a.coordinator.seekTo(AndroidSeekCommand(f.id, 100)); runCurrent()
            val activation = f.holdPeer()
            val replacement = async { runCatching { f.b.coordinator.load(request("candidate")) } }
            runCurrent(); assertEquals(1, f.engine.quiesces)
            when (newer) {
                "live" -> f.a.coordinator.seekToLiveEdge(AndroidSessionCommand(f.id))
                "position" -> f.a.coordinator.seekTo(AndroidSeekCommand(f.id, 500))
                else -> assertFailsWith<YlBoundaryException> { f.a.coordinator.seekTo(AndroidSeekCommand(f.id, -1)) }
            }
            commandAck.complete(Unit); runCurrent()
            activation.complete(Unit); runCurrent(); assertTrue(replacement.await().isFailure)
            val live = f.engine.currentLiveEdge; val position = f.engine.position
            f.finish()
            assertEquals(newer == "live", live)
            if (newer != "live") assertEquals(if (newer == "position") 500L else 100L, position)
        }
    }

    @Test fun `track and timeline acceptance remain independent across peer quiescence`() = runTest {
        for (trackFirst in listOf(true, false)) {
            val f = fixture()
            val commandAck = CompletableDeferred<Unit>()
            if (trackFirst) f.engine.commandAcknowledgement = commandAck else f.engine.liveCommandAcknowledgement = commandAck
            val older = async {
                if (trackFirst) f.a.coordinator.selectAudioTrack(AndroidTrackCommand(f.id, "older"))
                else f.a.coordinator.seekToLiveEdge(AndroidSessionCommand(f.id))
            }
            runCurrent(); assertFalse(older.isCompleted)
            val activation = f.holdPeer()
            val replacement = async { runCatching { f.b.coordinator.load(request("candidate")) } }; runCurrent()
            if (trackFirst) f.a.coordinator.seekTo(AndroidSeekCommand(f.id, 500))
            else f.a.coordinator.selectAudioTrack(AndroidTrackCommand(f.id, "newer"))
            commandAck.complete(Unit); runCurrent(); older.await()
            activation.complete(Unit); runCurrent(); assertTrue(replacement.await().isFailure)
            val track = f.engine.currentTrack; val position = f.engine.position; val live = f.engine.currentLiveEdge
            f.finish()
            assertEquals(if (trackFirst) "older" else "newer", track)
            if (trackFirst) { assertEquals(500L, position); assertFalse(live) } else assertTrue(live)
        }
    }

    @Test fun `new rejected suspended requests do not take ownership from older valid requests`() = runTest {
        for (trackCommand in listOf(true, false)) {
            val f = fixture()
            val commandAck = CompletableDeferred<Unit>()
            if (trackCommand) f.engine.commandAcknowledgement = commandAck else f.engine.liveCommandAcknowledgement = commandAck
            val older = async {
                if (trackCommand) f.a.coordinator.selectAudioTrack(AndroidTrackCommand(f.id, "older"))
                else f.a.coordinator.seekToLiveEdge(AndroidSessionCommand(f.id))
            }
            runCurrent()
            val activation = f.holdPeer()
            val replacement = async { runCatching { f.b.coordinator.load(request("candidate")) } }; runCurrent()
            if (trackCommand) assertFailsWith<YlBoundaryException> { f.a.coordinator.selectAudioTrack(AndroidTrackCommand(f.id, "absent")) }
            else assertFailsWith<YlBoundaryException> { f.a.coordinator.seekTo(AndroidSeekCommand(f.id, -1)) }
            commandAck.complete(Unit); runCurrent(); older.await()
            activation.complete(Unit); runCurrent(); assertTrue(replacement.await().isFailure)
            val track = f.engine.currentTrack; val live = f.engine.currentLiveEdge
            assertTrue(f.a.events.failures.isEmpty())
            f.finish()
            if (trackCommand) assertEquals("older", track) else assertTrue(live)
        }
    }

    @Test fun `new worker rejection does not replace the earlier successfully accepted track`() = runTest {
        val f = fixture()
        val commandAck = CompletableDeferred<Unit>()
        f.engine.commandAcknowledgement = commandAck
        f.engine.trackErrors["newer"] = YlBoundaryException(YlFailureKind.SOURCE_MISSING)
        val older = async { f.a.coordinator.selectAudioTrack(AndroidTrackCommand(f.id, "older")) }; runCurrent()
        val newer = async { runCatching { f.a.coordinator.selectAudioTrack(AndroidTrackCommand(f.id, "newer")) } }; runCurrent()
        commandAck.complete(Unit); runCurrent(); older.await()
        assertEquals(YlFailureKind.SOURCE_MISSING, (newer.await().exceptionOrNull() as YlBoundaryException).kind)
        val activation = f.holdPeer()
        val replacement = async { runCatching { f.b.coordinator.load(request("candidate")) } }; runCurrent()
        activation.complete(Unit); runCurrent(); assertTrue(replacement.await().isFailure)
        val track = f.engine.currentTrack
        assertTrue(f.a.events.failures.isEmpty())
        f.finish()
        assertEquals("older", track)
    }

    @Test fun `peer rollback cannot publish before its former players old worker has settled`() = runTest {
        val f = fixture()
        val commandAck = CompletableDeferred<Unit>()
        f.engine.commandAcknowledgement = commandAck
        val older = async { f.a.coordinator.selectAudioTrack(AndroidTrackCommand(f.id, "older")) }; runCurrent()
        val activation = f.holdPeer()
        val replacement = async { runCatching { f.b.coordinator.load(request("candidate")) } }; runCurrent()
        f.a.coordinator.selectAudioTrack(AndroidTrackCommand(f.id, "newer"))
        val publishedTracks = mutableListOf<String?>()
        f.a.events.stateObserved = { publishedTracks += f.engine.currentTrack }
        f.engine.onRestore = { f.engine.emit(YlEngineEvent.Snapshot(YlEngineSnapshot(AndroidPlaybackStatus.READY,
            audioTracks = tracks(f.engine.currentTrack)))) }
        activation.complete(Unit); runCurrent()
        val prematureRestores = f.engine.restores
        commandAck.complete(Unit); runCurrent(); older.await(); assertTrue(replacement.await().isFailure)
        val track = f.engine.currentTrack
        f.finish()
        assertEquals(0, prematureRestores)
        assertEquals("newer", track)
        assertEquals(listOf<String?>("newer"), publishedTracks)
    }

    @Test fun `stop while peer waits for former command settlement fences every late result`() = runTest {
        val f = fixture()
        val commandAck = CompletableDeferred<Unit>()
        f.engine.commandAcknowledgement = commandAck
        val older = async { runCatching { f.a.coordinator.selectAudioTrack(AndroidTrackCommand(f.id, "older")) } }; runCurrent()
        val activation = f.holdPeer()
        val replacement = async { runCatching { f.b.coordinator.load(request("candidate")) } }; runCurrent()
        f.a.coordinator.selectAudioTrack(AndroidTrackCommand(f.id, "newer"))
        val stopped = async { f.a.coordinator.stop() }; runCurrent()
        commandAck.complete(Unit); activation.complete(Unit); runCurrent()
        assertTrue(older.await().isFailure); assertTrue(replacement.await().isFailure); stopped.await()
        assertNull(f.a.coordinator.initialState.sessionId)
        assertEquals(0, f.engine.restores)
        f.finish()
    }
}

private fun tracks(selected: String? = null) = listOf("initial", "older", "newer").map {
    AndroidTrackMessage(it, AndroidTrackKind.AUDIO, isSelected = it == selected)
}

@OptIn(ExperimentalCoroutinesApi::class)
private suspend fun TestScope.fixture(): OrderFixture {
    val dispatcher = StandardTestDispatcher(testScheduler)
    val shared = YlDecoderLeaseCoordinator(dispatcher) { testScheduler.currentTime }
    val a = SessionFixture(dispatcher, 1).also { it.coordinator.bindLeases(shared) }
    val b = SessionFixture(dispatcher, 2).also { it.coordinator.bindLeases(shared) }
    val id = a.coordinator.load(request("old")).sessionId
    val engine = a.engines.single().apply { currentTrack = "initial" }
    engine.emit(YlEngineEvent.Snapshot(YlEngineSnapshot(AndroidPlaybackStatus.READY,
        timeline = emptyTimeline().copy(isLive = true), audioTracks = tracks("initial"))))
    return OrderFixture(a, b, engine, id)
}

private class OrderFixture(val a: SessionFixture, val b: SessionFixture, val engine: FakeSessionEngine, val id: String) {
    fun holdPeer() = CompletableDeferred<Unit>().also { acknowledgement ->
        b.next = FakeSessionEngine().apply { activationAcknowledgement = acknowledgement; activationError = IllegalStateException() }
    }
    suspend fun finish() { a.finish(); b.finish() }
}
