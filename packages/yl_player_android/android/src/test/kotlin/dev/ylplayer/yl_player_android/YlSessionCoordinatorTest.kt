package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class YlSessionCoordinatorTest {
    @Test fun `pending retry events replay once after initial or replacement commit before live retries`() = runTest {
        for (replacement in listOf(false, true)) {
            val f = SessionFixture(StandardTestDispatcher(testScheduler))
            if (replacement) f.coordinator.load(request("old"))
            val gate = CompletableDeferred<Unit>()
            val engine = FakeSessionEngine().apply { activationAcknowledgement = gate }
            engine.onActivate = { engine.emit(YlEngineEvent.Retry(1, 100, 10)); engine.emit(YlEngineEvent.Retry(2, 200, 20)) }
            f.next = engine
            val load = async { f.coordinator.load(request("candidate")) }
            runCurrent()
            assertTrue(f.events.retries.isEmpty())
            gate.complete(Unit); runCurrent()
            val committed = load.await()
            engine.emit(YlEngineEvent.Retry(3, 400, 30)); runCurrent()
            assertEquals(listOf(1L, 2L, 3L), f.events.retries.map { it.retryIndex })
            assertEquals(listOf(100L, 200L, 400L), f.events.retries.map { it.delayMs })
            assertEquals(listOf(10L, 20L, 30L), f.events.retries.map { it.occurredAtMs })
            assertTrue(f.events.retries.all { it.sessionId == committed.sessionId })
            f.finish()
        }
    }
    @Test fun `failed and stopped candidates discard provisional retries`() = runTest {
        for (stop in listOf(false, true)) {
            val f = SessionFixture(StandardTestDispatcher(testScheduler))
            f.coordinator.load(request("old"))
            val gate = CompletableDeferred<Unit>()
            val engine = FakeSessionEngine().apply { activationAcknowledgement = gate }
            engine.onActivate = { engine.emit(YlEngineEvent.Retry(1, 100, 10)) }
            f.next = engine
            val load = async { runCatching { f.coordinator.load(request("failed")) } }
            runCurrent()
            if (stop) f.coordinator.stop() else { engine.activationError = YlBoundaryException(YlFailureKind.NETWORK_FAILED); gate.complete(Unit) }
            runCurrent(); assertTrue(load.await().isFailure)
            f.coordinator.load(request("next")); runCurrent()
            assertTrue(f.events.retries.isEmpty())
            f.finish()
        }
    }
    @Test fun `strict activation deadline reports decoder unavailable and restores former session`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val old = f.coordinator.load(request("old"))
        f.next = FakeSessionEngine().apply { activationAcknowledgement = CompletableDeferred() }
        val result = async { runCatching { f.coordinator.load(request("strict").let { it.copy(options = it.options.copy(decoderPolicyOverride = AndroidDecoderPolicy.HARDWARE_REQUIRED)) }) } }
        advanceUntilIdle()
        assertEquals(YlFailureKind.DECODER_UNAVAILABLE, (result.await().exceptionOrNull() as YlBoundaryException).kind)
        assertEquals(old.sessionId, f.events.states.last().sessionId)
        assertTrue(f.engines.first().restores > 0)
        f.finish()
    }
    @Test fun `managed credentials share assessment and load route without interim rejection`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val value = request("managed").let { it.copy(source = it.source.copy(request = AndroidHttpRequestMessage(mapOf("X-Ordinary" to "ok"), mapOf("X-Api-Key" to "secret")), networkPolicy = AndroidNetworkPolicyMessage(AndroidNetworkPolicyKind.MANAGED, 1000, 1000, 0, 0, 1000, 2))) }
        assertEquals(AndroidAssessmentOutcome.COMPATIBLE, f.coordinator.assess(AndroidAssessRequest(value.source, value.options)).outcome)
        assertEquals("managed", f.coordinator.load(value).loadRequestId)
        assertEquals(1, f.engines.size)
        f.finish()
    }
    @Test fun `background shares held peer quiesce and completes before candidate disposal`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val shared = YlDecoderLeaseCoordinator(dispatcher) { testScheduler.currentTime }
        val first = SessionFixture(dispatcher, 1).also { it.coordinator.bindLeases(shared) }
        val second = SessionFixture(dispatcher, 2).also { it.coordinator.bindLeases(shared) }
        val old = first.coordinator.load(request("old").withAutoplay(true)); runCurrent()
        val engine = first.engines.single()
        val quiesced = CompletableDeferred<Unit>()
        val disposed = CompletableDeferred<Unit>()
        engine.quiesceAcknowledgement = quiesced
        second.next = FakeSessionEngine().apply { release = disposed }
        val transfer = async { runCatching { second.coordinator.load(request("candidate")) } }
        runCurrent()
        first.coordinator.onBackground(); runCurrent()
        val quiescesBeforeAcknowledgement = engine.quiesces
        quiesced.complete(Unit); runCurrent()
        val backgroundBeforeCandidateDisposal = engine.backgrounded
        val transferBeforeCandidateDisposal = transfer.isCompleted
        first.coordinator.onForeground(); runCurrent()
        disposed.complete(Unit); runCurrent()
        assertTrue(transfer.await().isFailure)
        assertEquals(1, quiescesBeforeAcknowledgement)
        assertTrue(backgroundBeforeCandidateDisposal)
        assertFalse(transferBeforeCandidateDisposal)
        assertTrue(engine.playing)
        assertFalse(engine.backgrounded)
        assertEquals(old.sessionId, shared.owner?.leaseId)
        first.finish(); second.finish()
    }

    @Test fun `held background release survives stop close and caller cancellation before safe cleanup`() = runTest {
        for (close in listOf(false, true)) {
            val f = SessionFixture(StandardTestDispatcher(testScheduler))
            f.coordinator.load(request("old").withAutoplay(true)); runCurrent()
            val engine = f.engines.single()
            val quiesced = CompletableDeferred<Unit>()
            val backgroundFinished = CompletableDeferred<Unit>()
            engine.quiesceAcknowledgement = quiesced
            engine.backgroundAcknowledgement = backgroundFinished
            f.coordinator.onBackground(); runCurrent()
            val ended = async { if (close) f.coordinator.close().await() else f.coordinator.stop() }
            runCurrent()
            val completedBeforeQuiesce = ended.isCompleted
            val outputReleasedBeforeQuiesce = f.output.releases
            val idleBeforeQuiesce = f.events.states.last().status == AndroidPlaybackStatus.IDLE
            ended.cancel(); runCurrent()
            quiesced.complete(Unit); runCurrent()
            val outputReleasedBeforeBackground = f.output.releases
            backgroundFinished.complete(Unit); runCurrent()
            f.finish()
            assertFalse(completedBeforeQuiesce)
            assertEquals(0, outputReleasedBeforeQuiesce)
            assertEquals(0, outputReleasedBeforeBackground)
            if (!close) assertTrue(idleBeforeQuiesce)
            assertEquals(1, f.output.releases)
            assertEquals(listOf("background"), engine.lifecycleCalls)
            assertEquals(0, engine.restores)
        }
    }

    @Test fun `play queued during failed quiesce cannot reactivate failed resources`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val shared = YlDecoderLeaseCoordinator(dispatcher) { testScheduler.currentTime }
        val first = SessionFixture(dispatcher, 1).also { it.coordinator.bindLeases(shared) }
        val second = SessionFixture(dispatcher, 2).also { it.coordinator.bindLeases(shared) }
        val old = first.coordinator.load(request("old").withAutoplay(true)); runCurrent()
        val engine = first.engines.single()
        val acknowledged = CompletableDeferred<Unit>()
        engine.quiesceAcknowledgement = acknowledged
        engine.quiesceError = IllegalStateException()
        val transfer = async { runCatching { second.coordinator.load(request("next")) } }
        runCurrent()
        val priorPlays = engine.playCalls
        val play = async { runCatching { first.coordinator.play(AndroidSessionCommand(old.sessionId)) } }
        runCurrent(); acknowledged.complete(Unit); runCurrent()
        transfer.await()
        val played = play.await()
        assertTrue(played.isFailure)
        assertEquals(priorPlays, engine.playCalls)
        assertEquals(AndroidPlaybackStatus.FAILED, first.events.states.last().status)
        assertTrue(engine.disposals > 0)
        first.finish(); second.finish()
    }

    @Test fun `play during held predecessor quiesce cannot bypass shared lease`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val shared = YlDecoderLeaseCoordinator(dispatcher) { testScheduler.currentTime }
        val first = SessionFixture(dispatcher, 1).also { it.coordinator.bindLeases(shared) }
        val second = SessionFixture(dispatcher, 2).also { it.coordinator.bindLeases(shared) }
        val old = first.coordinator.load(request("old").withAutoplay(true)); runCurrent()
        val engine = first.engines.single()
        val acknowledgement = CompletableDeferred<Unit>()
        engine.quiesceAcknowledgement = acknowledgement
        val transfer = async { runCatching { second.coordinator.load(request("next")) } }
        runCurrent()
        assertEquals(1, engine.quiesces)
        val initialPlays = engine.playCalls
        val play = async { first.coordinator.play(AndroidSessionCommand(old.sessionId)) }
        runCurrent()
        val playsBeforeAcknowledgement = engine.playCalls
        val playCompletedBeforeAcknowledgement = play.isCompleted
        acknowledgement.complete(Unit)
        runCurrent(); play.await(); val transferResult = transfer.await()
        assertEquals(initialPlays, playsBeforeAcknowledgement, "Pending quiesce must fence direct engine Play")
        assertFalse(playCompletedBeforeAcknowledgement)
        assertTrue(transferResult.isFailure)
        assertEquals(0, second.engines.single().activationCalls)
        assertEquals(old.sessionId, shared.owner?.leaseId)
        assertTrue(engine.playing)
        first.finish(); second.finish()
    }

    @Test fun `foreground waits held background quiesce before restoring original play intent`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val shared = YlDecoderLeaseCoordinator(dispatcher) { testScheduler.currentTime }
        val f = SessionFixture(dispatcher).also { it.coordinator.bindLeases(shared) }
        val old = f.coordinator.load(request("playing").withAutoplay(true)); runCurrent()
        val engine = f.engines.single()
        val acknowledgement = CompletableDeferred<Unit>()
        engine.quiesceAcknowledgement = acknowledgement
        f.coordinator.onBackground(); runCurrent()
        f.coordinator.onForeground(); runCurrent()
        val foregroundBeforeAcknowledgement = engine.foregroundCalls
        val restoreBeforeAcknowledgement = engine.restores
        var responsive = false
        launch { responsive = true }; runCurrent()
        acknowledgement.complete(Unit); runCurrent()
        assertEquals(0, foregroundBeforeAcknowledgement)
        assertEquals(0, restoreBeforeAcknowledgement)
        assertTrue(responsive)
        assertTrue(engine.playing)
        assertFalse(engine.backgrounded)
        assertEquals(old.sessionId, shared.owner?.leaseId)
        assertEquals(1, engine.restores)
        assertTrue(engine.lifecycleCalls.indexOf("background") < engine.lifecycleCalls.indexOf("restore"))
        f.finish()
    }

    @Test fun `replacement waits captured background release and cannot lose new lease to its continuation`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val shared = YlDecoderLeaseCoordinator(dispatcher) { testScheduler.currentTime }
        val f = SessionFixture(dispatcher).also { it.coordinator.bindLeases(shared) }
        f.coordinator.load(request("old").withAutoplay(true)); runCurrent()
        val old = f.engines.single()
        val quiesced = CompletableDeferred<Unit>()
        val released = CompletableDeferred<Unit>()
        old.quiesceAcknowledgement = quiesced
        old.backgroundAcknowledgement = released
        f.coordinator.onBackground(); runCurrent()
        f.coordinator.onForeground()
        val replacement = async { f.coordinator.load(request("new").withAutoplay(true)) }
        runCurrent(); quiesced.complete(Unit); runCurrent()
        val committedBeforeBackgroundRelease = replacement.isCompleted
        val enginesBeforeBackgroundRelease = f.engines.size
        released.complete(Unit); runCurrent()
        val next = replacement.await(); runCurrent()
        assertFalse(committedBeforeBackgroundRelease)
        assertEquals(1, enginesBeforeBackgroundRelease)
        assertEquals(next.sessionId, shared.owner?.leaseId)
        assertEquals(next.sessionId, f.events.states.last().sessionId)
        assertTrue(f.engines.last().playing)
        assertFalse(f.engines.last().backgrounded)
        assertEquals(0, f.engines.last().quiesces)
        f.finish()
    }

    @Test fun `synchronous publication failure closes accepted session without restoring former`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        f.coordinator.load(request("old"))
        f.events.stateObserved = { if (it.loadRequestId == "new") error("sink") }
        assertFails { f.coordinator.load(request("new")) }
        runCurrent()
        assertEquals("new", f.events.states.last().loadRequestId)
        assertEquals(0, f.engines.first().restores)
        assertTrue(f.engines.all { it.disposals > 0 })
        assertEquals(1, f.output.releases)
        f.finish()
    }

    @Test fun `stop and close retain lease until acknowledged disposal while stop fences presentation`() = runTest {
        for (close in listOf(false, true)) {
            val dispatcher = StandardTestDispatcher(testScheduler)
            val shared = YlDecoderLeaseCoordinator(dispatcher) { testScheduler.currentTime }
            val first = SessionFixture(dispatcher, 1).also { it.coordinator.bindLeases(shared) }
            val second = SessionFixture(dispatcher, 2).also { it.coordinator.bindLeases(shared) }
            first.coordinator.load(request("old"))
            val release = CompletableDeferred<Unit>()
            first.engines.single().release = release
            val stopped = async { if (close) first.coordinator.close().await() else first.coordinator.stop() }
            runCurrent()
            if (!close) assertEquals(AndroidPlaybackStatus.IDLE, first.events.states.last().status)
            assertFalse(stopped.isCompleted)
            val next = FakeSessionEngine()
            second.next = next
            val load = async { second.coordinator.load(request("new")) }
            runCurrent()
            assertEquals(0, next.activationCalls)
            assertFalse(load.isCompleted)
            release.complete(Unit); runCurrent()
            stopped.await(); load.await()
            assertEquals(1, next.activationCalls)
            first.finish(); second.finish()
        }
    }

    @Test fun `rollback uses current position after earlier seek has advanced`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val old = f.coordinator.load(request("old"))
        f.coordinator.seekTo(AndroidSeekCommand(old.sessionId, 100)); runCurrent()
        f.engines.single().position = 900
        f.next = FakeSessionEngine().apply { activationError = IllegalStateException() }
        assertFailsWith<IllegalStateException> { f.coordinator.load(request("new")) }
        assertEquals(900L, f.engines.first().position)
        f.finish()
    }

    @Test fun `controls changed while peer activation fails survive rollback`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val shared = YlDecoderLeaseCoordinator(dispatcher) { testScheduler.currentTime }
        val first = SessionFixture(dispatcher, 1).also { it.coordinator.bindLeases(shared) }
        val second = SessionFixture(dispatcher, 2).also { it.coordinator.bindLeases(shared) }
        val old = first.coordinator.load(request("old").withAutoplay(true)); runCurrent()
        val hold = CompletableDeferred<Unit>()
        second.next = FakeSessionEngine().apply { activationAcknowledgement = hold; activationError = IllegalStateException() }
        val candidate = async { runCatching { second.coordinator.load(request("new")) } }
        runCurrent()
        first.coordinator.setPlaybackSpeed(AndroidSpeedCommand(old.sessionId, 1.5))
        first.coordinator.selectAudioTrack(AndroidTrackCommand(old.sessionId, "french"))
        first.coordinator.seekTo(AndroidSeekCommand(old.sessionId, 456))
        first.coordinator.pause(AndroidSessionCommand(old.sessionId))
        runCurrent(); hold.complete(Unit); runCurrent()
        assertTrue(candidate.await().isFailure)
        val restored = first.engines.single()
        assertEquals(1.5, restored.currentSpeed)
        assertEquals("french", restored.currentTrack)
        assertEquals(456L, restored.position)
        assertFalse(restored.playing)
        first.finish(); second.finish()
    }
    @Test fun `memory notification reaches candidate held in decoder activation`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val held = FakeSessionEngine().apply { activationAcknowledgement = CompletableDeferred() }
        f.next = held
        val load = async { runCatching { f.coordinator.load(request("held")) } }
        runCurrent(); f.coordinator.onTrimMemory(10); runCurrent()
        assertEquals(listOf(10), held.memoryLevels)
        f.coordinator.stop(); runCurrent()
        assertTrue(load.await().isFailure)
        held.activationAcknowledgement!!.complete(Unit)
        f.finish()
    }

    @Test fun `volume changed after worker assignment follows committed player`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        f.coordinator.load(request("old"))
        val assigned = CompletableDeferred<Unit>()
        val resume = CompletableDeferred<Unit>()
        val candidate = FakeSessionEngine().apply {
            volumeAcknowledgement = resume
            volumeAssigned = assigned
        }
        f.next = candidate
        val load = async { f.coordinator.load(request("new")) }
        runCurrent(); assigned.await()
        f.coordinator.setVolume(0.3)
        resume.complete(Unit)
        runCurrent(); load.await(); runCurrent()
        assertEquals(0.3, candidate.currentVolume)
        f.finish()
    }
    @Test fun `pause of playing background session remains paused after lease restoration`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val session = f.coordinator.load(request("playing").withAutoplay(true))
        runCurrent()
        f.coordinator.onBackground(); runCurrent()
        f.coordinator.pause(AndroidSessionCommand(session.sessionId)); runCurrent()
        f.coordinator.onForeground(); runCurrent()
        assertFalse(f.engines.single().playing)
        f.finish()
    }
    @Test fun `two nonexclusive sessions suspend on background and retain independent intent`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val shared = YlDecoderLeaseCoordinator(dispatcher) { testScheduler.currentTime }
        val first = SessionFixture(dispatcher, 1).also { it.coordinator.bindLeases(shared) }
        val second = SessionFixture(dispatcher, 2).also { it.coordinator.bindLeases(shared) }
        first.next = FakeSessionEngine().apply { needsExclusiveLease = false }
        second.next = FakeSessionEngine().apply { needsExclusiveLease = false }
        first.coordinator.load(request("audio1").withAutoplay(true))
        second.coordinator.load(request("audio2").withAutoplay(true)); runCurrent()
        assertTrue(first.engines.single().playing && second.engines.single().playing)
        assertNull(shared.owner)
        first.coordinator.onBackground(); second.coordinator.onBackground(); runCurrent()
        assertFalse(first.engines.single().playing || second.engines.single().playing)
        first.coordinator.onForeground(); second.coordinator.onForeground(); runCurrent()
        assertTrue(first.engines.single().playing && second.engines.single().playing)
        first.finish(); second.finish()
    }
    @Test fun `peer retains metadata and reacquires lease on play`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val shared = YlDecoderLeaseCoordinator(dispatcher) { testScheduler.currentTime }
        val first = SessionFixture(dispatcher, 1).also { it.coordinator.bindLeases(shared) }
        val second = SessionFixture(dispatcher, 2).also { it.coordinator.bindLeases(shared) }
        val prior = first.coordinator.load(request("old").withAutoplay(true)); runCurrent()
        second.coordinator.load(request("new").withAutoplay(true)); runCurrent()
        assertEquals(prior.sessionId, first.events.states.last().sessionId)
        assertFalse(first.engines.single().playing)
        assertEquals(0, first.engines.single().disposals)
        first.coordinator.play(AndroidSessionCommand(prior.sessionId)); runCurrent()
        assertTrue(first.engines.single().playing)
        assertFalse(second.engines.single().playing)
        first.finish(); second.finish()
    }

    @Test fun `candidate preparation failure leaves former decoder untouched`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val old = f.coordinator.load(request("old").withAutoplay(true))
        runCurrent()
        val former = f.engines.single()
        f.next = FakeSessionEngine().apply { prepareError = YlBoundaryException(YlFailureKind.SOURCE_MISSING) }
        assertFailsWith<YlBoundaryException> { f.coordinator.load(request("candidate")) }
        assertEquals(0, former.quiesces)
        assertEquals(0, former.restores)
        assertTrue(former.playing)
        assertEquals(old.sessionId, f.events.states.last().sessionId)
        f.finish()
    }

    @Test fun `background release stays independent of unacknowledged candidate cleanup`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        f.coordinator.load(request("old"))
        val former = f.engines.single()
        val released = CompletableDeferred<Unit>()
        f.next = FakeSessionEngine().apply { preparation = CompletableDeferred(); release = released }
        val load = async { runCatching { f.coordinator.load(request("candidate")) } }
        runCurrent()
        f.coordinator.onBackground()
        runCurrent()
        assertFalse(load.isCompleted)
        assertTrue(former.backgrounded)
        assertFalse(former.playing)
        var responsive = false
        launch { responsive = true }
        runCurrent()
        assertTrue(responsive)
        released.complete(Unit)
        runCurrent()
        assertTrue(load.await().isFailure)
        f.finish()
    }
    @Test fun `foreground background bounce preserves explicit play until applied`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val reply = f.coordinator.load(request("paused"))
        val engine = f.engines.single()
        f.coordinator.onBackground()
        runCurrent()
        f.coordinator.play(AndroidSessionCommand(reply.sessionId))
        f.coordinator.onForeground()
        f.coordinator.onBackground()
        runCurrent()
        assertEquals(0, engine.playCalls)
        f.coordinator.onForeground()
        runCurrent()
        assertTrue(engine.playing)
        assertEquals(1, engine.playCalls)
        f.finish()
    }
    @Test fun `background during held foreground restore retains unapplied explicit play`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val reply = f.coordinator.load(request("paused"))
        val engine = f.engines.single()
        val restored = CompletableDeferred<Unit>()
        engine.foregroundAcknowledgement = restored
        f.coordinator.onBackground()
        runCurrent()
        f.coordinator.play(AndroidSessionCommand(reply.sessionId))
        f.coordinator.onForeground()
        runCurrent()
        assertEquals(1, engine.foregroundCalls)
        f.coordinator.onBackground()
        runCurrent()
        restored.complete(Unit)
        runCurrent()
        assertEquals(0, engine.playCalls)
        f.coordinator.onForeground()
        runCurrent()
        assertTrue(engine.playing)
        assertEquals(1, engine.playCalls)
        f.finish()
    }
    @Test fun `background at committed loading keeps reply and saves not yet dispatched autoplay`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        f.events.stateObserved = { state ->
            if (state.status == AndroidPlaybackStatus.LOADING) {
                f.events.stateObserved = null
                f.coordinator.onBackground()
            }
        }
        val reply = f.coordinator.load(request("committed").withAutoplay(true))
        runCurrent()
        val engine = f.engines.single()
        assertEquals(reply.sessionId, f.events.states.last().sessionId)
        assertTrue(engine.backgrounded)
        assertEquals(0, engine.playCalls)
        f.coordinator.onForeground()
        runCurrent()
        assertTrue(engine.playing)
        assertEquals(1, engine.playCalls)
        f.finish()
    }
    @Test fun `background cancels held first load before it can autoplay`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val candidate = FakeSessionEngine().apply { preparation = CompletableDeferred() }
        f.next = candidate
        val load = async { runCatching { f.coordinator.load(request("first").withAutoplay(true)) } }
        runCurrent()
        f.coordinator.onBackground()
        runCurrent()
        assertTrue(load.isCompleted)
        assertEquals(YlFailureKind.LOAD_CANCELLED, (load.await().exceptionOrNull() as YlBoundaryException).kind)
        assertTrue(candidate.disposals > 0)
        assertEquals(0, candidate.playCalls)
        candidate.preparation!!.complete(Unit)
        f.coordinator.onForeground()
        runCurrent()
        assertEquals(0, candidate.playCalls)
        assertTrue(f.events.states.isEmpty())
        f.finish()
    }
    @Test fun `background cancels held replacement and foreground restores only saved intent`() = runTest {
        for (intended in listOf(false, true)) {
            val f = SessionFixture(StandardTestDispatcher(testScheduler))
            val old = f.coordinator.load(request("old").withAutoplay(intended))
            runCurrent()
            val former = f.engines.single()
            val oldPlayCalls = former.playCalls
            val candidate = FakeSessionEngine().apply { preparation = CompletableDeferred() }
            f.next = candidate
            val load = async { runCatching { f.coordinator.load(request("new").withAutoplay(true)) } }
            runCurrent()
            f.coordinator.onBackground()
            runCurrent()
            assertTrue(load.isCompleted)
            assertTrue(load.await().isFailure)
            assertTrue(candidate.disposals > 0)
            assertEquals(0, candidate.playCalls)
            assertTrue(former.backgrounded)
            assertFalse(former.playing)
            assertEquals(oldPlayCalls, former.playCalls)
            assertEquals(0, former.restores)
            assertEquals(old.sessionId, f.events.states.last().sessionId)
            f.coordinator.onForeground()
            runCurrent()
            assertEquals(intended, former.playing)
            assertFalse(candidate.playing)
            f.finish()
        }
    }
    @Test fun `new load in retained background waits without allocation or autoplay`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        f.coordinator.onBackground()
        val load = async { f.coordinator.load(request("background").withAutoplay(true)) }
        runCurrent()
        assertFalse(load.isCompleted)
        assertTrue(f.engines.isEmpty())
        f.coordinator.onForeground()
        runCurrent()
        load.await()
        assertEquals(1, f.engines.single().playCalls)
        f.finish()
    }
    @Test fun `play and pause while backgrounded only change foreground playback intention`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val reply = f.coordinator.load(request("old"))
        val engine = f.engines.single()
        f.coordinator.onBackground()
        runCurrent()
        f.coordinator.play(AndroidSessionCommand(reply.sessionId))
        runCurrent()
        assertEquals(0, engine.playCalls)
        f.coordinator.pause(AndroidSessionCommand(reply.sessionId))
        runCurrent()
        f.coordinator.onForeground()
        runCurrent()
        assertFalse(engine.playing)
        assertEquals(0, engine.playCalls)
        f.finish()
    }
    @Test fun `caller cancellation retains completed quiesce snapshot for rollback`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        f.coordinator.load(request("one"))
        val acknowledgement = CompletableDeferred<Unit>()
        f.engines.single().quiesceAcknowledgement = acknowledgement
        val candidate = async { f.coordinator.load(request("two")) }
        runCurrent()
        candidate.cancel()
        runCurrent()
        acknowledgement.complete(Unit)
        runCurrent()
        assertEquals(1, f.engines.first().restores)
        f.finish()
    }
    @Test fun `quiesce failure cannot retain a false playing state`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        f.coordinator.load(request("one"))
        f.engines.single().quiesceError = YlBoundaryException(YlFailureKind.PLATFORM_FAILURE)
        assertFailsWith<YlBoundaryException> { f.coordinator.load(request("two")) }
        assertEquals(AndroidPlaybackStatus.FAILED, f.events.states.last().status)
        f.finish()
    }
    @Test fun `safe cleanup error does not touch former or replace original preparation failure`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        f.coordinator.load(request("one"))
        f.next = FakeSessionEngine().apply {
            prepareError = YlBoundaryException(YlFailureKind.SOURCE_MISSING)
            release = CompletableDeferred<Unit>().apply { completeExceptionally(IllegalStateException()) }
        }
        assertEquals(YlFailureKind.SOURCE_MISSING, assertFailsWith<YlBoundaryException> { f.coordinator.load(request("two")) }.kind)
        assertEquals(0, f.engines.first().restores)
        assertEquals(0, f.engines.first().quiesces)
        f.finish()
    }
    @Test fun `candidate failure callback before commit keeps former authoritative`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val old = f.coordinator.load(request("one"))
        f.next = FakeSessionEngine().apply { onActivate = { emit(YlEngineEvent.Failed(YlFailureKind.DECODER_UNAVAILABLE)) } }
        assertFailsWith<YlBoundaryException> { f.coordinator.load(request("two")) }
        assertEquals(old.sessionId, f.events.states.last().sessionId)
        f.finish()
    }
    @Test fun `safe exceptional close waits for other retired engine release before freeing output`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        f.coordinator.load(request("one"))
        val retiredRelease = CompletableDeferred<Unit>()
        f.engines.single().release = retiredRelease
        f.coordinator.load(request("two"))
        f.engines.last().release = CompletableDeferred<Unit>().apply { completeExceptionally(IllegalStateException()) }
        val closing = f.coordinator.close()
        runCurrent()
        assertFalse(closing.isCompleted)
        assertEquals(0, f.output.releases)
        retiredRelease.complete(Unit)
        runCurrent()
        runCatching { closing.await() }
        assertEquals(1, f.output.releases)
    }
    @Test fun `stop cancels candidate without waiting for old restoration`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        f.coordinator.load(request("one"))
        f.next = FakeSessionEngine().apply { preparation = CompletableDeferred() }
        val candidate = async { runCatching { f.coordinator.load(request("two")) } }
        runCurrent()
        f.coordinator.stop()
        candidate.await()
        assertEquals(0, f.engines.first().restores)
        f.finish()
    }
    @Test fun `validation and prepare failure retain old session with no new state`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val first = f.coordinator.load(request("one"))
        val before = f.events.states.toList()
        assertFailsWith<YlBoundaryException> { f.coordinator.load(request("bad").copy(source = source().copy(locator = ""))) }
        f.next = FakeSessionEngine().apply { prepareError = YlBoundaryException(YlFailureKind.SOURCE_MISSING) }
        assertFailsWith<YlBoundaryException> { f.coordinator.load(request("two")) }
        assertEquals(before, f.events.states)
        f.coordinator.play(AndroidSessionCommand(first.sessionId))
        assertEquals(0, f.engines.first().restores)
        f.finish()
    }
    @Test fun `commit publishes correlated loading and uses player local monotonic identity`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val reply = f.coordinator.load(request("private-request"))
        assertEquals("a7-s1", reply.sessionId)
        assertEquals("private-request", reply.loadRequestId)
        assertEquals(AndroidPlaybackStatus.LOADING, f.events.states.last().status)
        assertEquals(reply.sessionId, f.events.states.last().sessionId)
        assertEquals(reply.loadRequestId, f.events.states.last().loadRequestId)
        f.finish()
    }
    @Test fun `second load cancels uncommitted candidate and ignores its late callback`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val held = FakeSessionEngine().apply { preparation = CompletableDeferred() }
        f.next = held
        val first = async { runCatching { f.coordinator.load(request("one")) } }
        runCurrent()
        val second = f.coordinator.load(request("two"))
        runCurrent()
        assertEquals(YlFailureKind.LOAD_CANCELLED, (first.await().exceptionOrNull() as YlBoundaryException).kind)
        held.emit(YlEngineEvent.Snapshot(YlEngineSnapshot(status = AndroidPlaybackStatus.READY)))
        runCurrent()
        assertEquals(second.sessionId, f.events.states.last().sessionId)
        assertEquals(AndroidPlaybackStatus.LOADING, f.events.states.last().status)
        f.finish()
    }
    @Test fun `old session command is stale and stop cancels candidate while preserving output`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val old = f.coordinator.load(request("one"))
        f.coordinator.load(request("two"))
        assertEquals(YlFailureKind.SESSION_STALE, assertFailsWith<YlBoundaryException> { f.coordinator.pause(AndroidSessionCommand(old.sessionId)) }.kind)
        f.next = FakeSessionEngine().apply { preparation = CompletableDeferred() }
        val candidate = async { runCatching { f.coordinator.load(request("three")) } }
        runCurrent()
        f.coordinator.stop()
        runCurrent()
        assertTrue(candidate.await().isFailure)
        assertEquals(1, f.engines[1].stops)
        assertNull(f.events.states.last().sessionId)
        assertNull(f.events.states.last().loadRequestId)
        assertEquals(AndroidPlaybackStatus.IDLE, f.events.states.last().status)
        assertEquals(0, f.output.releases)
        f.finish()
    }
    @Test fun `committed failure emits failed state and exactly one session failure`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val reply = f.coordinator.load(request("one"))
        repeat(2) { f.engines.last().emit(YlEngineEvent.Failed(YlFailureKind.NETWORK_FAILED)) }
        runCurrent()
        assertEquals(AndroidPlaybackStatus.FAILED, f.events.states.last().status)
        assertEquals(reply.sessionId, f.events.failures.single().sessionId)
        f.finish()
    }
    @Test fun `activation failure restores same player old engine before returning`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val first = f.coordinator.load(request("one"))
        f.next = FakeSessionEngine().apply { activationError = YlBoundaryException(YlFailureKind.DECODER_UNAVAILABLE) }
        assertFailsWith<YlBoundaryException> { f.coordinator.load(request("two")) }
        assertEquals(first.sessionId, f.events.states.last().sessionId)
        assertEquals(1, f.engines.first().quiesces)
        assertEquals(1, f.engines.first().restores)
        f.finish()
    }
    @Test fun `close remains pending until every engine safely releases and main keeps running`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        f.coordinator.load(request("one"))
        val release = CompletableDeferred<Unit>()
        f.engines.single().release = release
        val close = f.coordinator.close()
        runCurrent()
        assertFalse(close.isCompleted)
        var responsive = false
        launch { responsive = true }
        runCurrent()
        assertTrue(responsive)
        assertEquals(0, f.output.releases)
        release.complete(Unit)
        runCurrent()
        close.await()
        assertEquals(1, f.output.releases)
    }
    @Test fun `private frame does not consume public gate and late output frames are ignored`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val held = FakeSessionEngine().apply { preparation = CompletableDeferred() }
        f.next = held
        val load = async { f.coordinator.load(request("one")) }
        runCurrent()
        held.emit(YlEngineEvent.FirstFrame(YlOutputIdentity(9, false), 1))
        runCurrent()
        held.preparation!!.complete(Unit)
        runCurrent()
        load.await()
        held.emit(YlEngineEvent.FirstFrame(YlOutputIdentity(9, false), 2))
        held.emit(YlEngineEvent.FirstFrame(YlOutputIdentity(8, true), 3))
        repeat(2) { held.emit(YlEngineEvent.FirstFrame(f.output.identity, 4)) }
        runCurrent()
        assertEquals(1, f.events.frames.size)
        f.finish()
    }
}

internal fun AndroidLoadRequest.withAutoplay(value: Boolean) = copy(options = options.copy(autoplay = value))
internal fun source() = AndroidSourceMessage(AndroidSourceKind.NETWORK, "https://example.test/movie.mp4", AndroidStreamIntent.ON_DEMAND, AndroidMediaFormat.MP4)
internal fun request(id: String) = AndroidLoadRequest(id, source(), AndroidLoadOptionsMessage(false, bufferStrategy = AndroidBufferStrategyMessage(AndroidBufferKind.AUTOMATIC), videoConstraints = AndroidVideoConstraintsMessage()))
internal val sessionOptions = AndroidPlayerOptionsMessage(AndroidDecoderPolicy.SYSTEM_DEFAULT, AndroidAudioPolicy.APP_MANAGED, 250)
internal class FakeSessionOutput : YlSessionVideoOutput {
    override var identity = YlOutputIdentity(1, true)
    var releases = 0
    override fun release() { releases++ }
}
internal class SessionEvents : YlPlayerEventSink {
    var stateObserved: ((AndroidStateMessage) -> Unit)? = null
    val states = mutableListOf<AndroidStateMessage>()
    val deltas = mutableListOf<AndroidStateDeltaMessage>()
    val failures = mutableListOf<AndroidPlaybackFailedMessage>()
    val frames = mutableListOf<AndroidFirstFrameMessage>()
    val retries = mutableListOf<AndroidRetryScheduledMessage>()
    override fun onState(state: AndroidStateMessage) { states += state; stateObserved?.invoke(state) }
    override fun onStateDelta(delta: AndroidStateDeltaMessage) { deltas += delta }
    override fun onPlaybackFailed(event: AndroidPlaybackFailedMessage) { failures += event }
    override fun onFirstFrame(event: AndroidFirstFrameMessage) { frames += event }
    override fun onRetryScheduled(event: AndroidRetryScheduledMessage) { retries += event }
    override fun onEngineChanged(event: AndroidEngineChangedMessage) = Unit
}
internal class SessionFixture(dispatcher: CoroutineDispatcher, playerId: Long = 7, options: AndroidPlayerOptionsMessage = sessionOptions, audioFocus: (() -> YlAudioFocusCoordinator)? = null) {
    val output = FakeSessionOutput()
    val engines = mutableListOf<FakeSessionEngine>()
    var next: FakeSessionEngine? = null
    val events = SessionEvents()
    val coordinator = YlSessionCoordinator(playerId, options, output, YlPlaybackEngineFactory { identity, _, _ ->
        (next ?: FakeSessionEngine()).also { next = null; it.identity = identity; engines += it }
    }, dispatcher, clockMs = { 123L }, audioFocus = audioFocus).also { it.bindLeases(YlDecoderLeaseCoordinator(dispatcher) { 123L }); it.attach(events) }
    suspend fun finish() { coordinator.close().await() }
}
internal class FakeSessionEngine : YlPlaybackEngineAdapter {
    override var needsExclusiveLease = true
    var currentVolume = 1.0
    var currentSpeed = 1.0
    var currentTrack: String? = null
    var position = 0L
    val memoryLevels = mutableListOf<Int>()
    var activationCalls = 0
    var activationAcknowledgement: CompletableDeferred<Unit>? = null
    var volumeAcknowledgement: CompletableDeferred<Unit>? = null
    var volumeAssigned: CompletableDeferred<Unit>? = null
    lateinit var identity: YlSessionIdentity
    private var callback: ((YlSessionIdentity, YlEngineEvent) -> Unit)? = null
    var preparation: CompletableDeferred<Unit>? = null
    var prepareError: Throwable? = null
    var activationError: Throwable? = null
    var onActivate: (() -> Unit)? = null
    var release: CompletableDeferred<Unit>? = null
    var quiesceAcknowledgement: CompletableDeferred<Unit>? = null
    var quiesceError: Throwable? = null
    var quiesces = 0
    var restores = 0
    var stops = 0
    var disposals = 0
    var playCalls = 0
    val lifecycleCalls = mutableListOf<String>()
    var backgroundAcknowledgement: CompletableDeferred<Unit>? = null
    var backgrounded = false
    var playing = false
    var playbackIntended = false
    var foregroundCalls = 0
    var foregroundAcknowledgement: CompletableDeferred<Unit>? = null
    override fun registerCallback(callback: (YlSessionIdentity, YlEngineEvent) -> Unit) { this.callback = callback }
    fun emit(event: YlEngineEvent) { callback?.invoke(identity, event) }
    override suspend fun prepare() { preparation?.await(); prepareError?.let { throw it } }
    override suspend fun activate(output: YlSessionVideoOutput) { activationCalls++; onActivate?.invoke(); activationAcknowledgement?.await(); activationError?.let { throw it } }
    override suspend fun quiesce(): YlEngineRestorePoint { quiesces++; quiesceAcknowledgement?.await(); quiesceError?.let { throw it }; playing = false; return YlEngineRestorePoint(position, false, playbackIntended, currentTrack, speed = currentSpeed, volume = currentVolume) }
    override suspend fun restore(point: YlEngineRestorePoint, output: YlSessionVideoOutput) { lifecycleCalls += "restore"; restores++; playbackIntended = point.playbackIntended; playing = playbackIntended; currentSpeed = point.speed; currentTrack = point.selectedAudioTrack; currentVolume = point.volume; position = point.positionMs }
    override suspend fun play() { playCalls++; playbackIntended = true; playing = true }
    override suspend fun pause() { playbackIntended = false; playing = false }
    override suspend fun seekTo(positionMs: Long) { position = positionMs }
    override suspend fun seekToLiveEdge() = Unit
    override suspend fun setPlaybackSpeed(speed: Double) { currentSpeed = speed }
    override suspend fun selectAudioTrack(trackId: String) { currentTrack = trackId }
    override suspend fun setVideoConstraints(constraints: AndroidVideoConstraintsMessage) = Unit
    override suspend fun setVolume(volume: Double) {
        currentVolume = volume
        volumeAssigned?.complete(Unit)
        volumeAcknowledgement?.await()
    }
    override suspend fun stop() { stops++ }
    override fun dispose(): Deferred<Unit> { disposals++; playing = false; return release ?: CompletableDeferred(Unit) }
    override suspend fun onForeground() { lifecycleCalls += "foreground"; foregroundCalls++; foregroundAcknowledgement?.await(); backgrounded = false; playing = playbackIntended }
    override suspend fun onBackground() { backgroundAcknowledgement?.await(); lifecycleCalls += "background"; backgrounded = true; playing = false }
    override suspend fun onTrimMemory(level: Int) { memoryLevels += level }
    override suspend fun onConfigurationChanged() = Unit
}
