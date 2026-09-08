package dev.ylplayer.yl_player_android

import android.app.Application
import androidx.media3.common.C
import dev.ylplayer.yl_player_android.pigeon.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.mockito.Mockito.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class YlFinalBoundaryTest {
    @Test fun `newer position intent wins over live edge captured by held rollback track application`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val shared = YlDecoderLeaseCoordinator(dispatcher) { testScheduler.currentTime }
        val a = SessionFixture(dispatcher, 1).also { it.coordinator.bindLeases(shared) }
        val b = SessionFixture(dispatcher, 2).also { it.coordinator.bindLeases(shared) }
        val id = a.coordinator.load(request("live")).sessionId
        val engine = a.engines.single()
        engine.emit(YlEngineEvent.Snapshot(YlEngineSnapshot(AndroidPlaybackStatus.READY,
            timeline = emptyTimeline().copy(isLive = true),
            audioTracks = listOf(AndroidTrackMessage("track", AndroidTrackKind.AUDIO, isSelected = false)))))
        val activation = CompletableDeferred<Unit>()
        b.next = FakeSessionEngine().apply { activationAcknowledgement = activation; activationError = IllegalStateException() }
        val transfer = async { runCatching { b.coordinator.load(request("failed")) } }; runCurrent()
        engine.restoreAcknowledgement = CompletableDeferred()
        activation.complete(Unit); runCurrent()
        a.coordinator.selectAudioTrack(AndroidTrackCommand(id, "track"))
        a.coordinator.seekToLiveEdge(AndroidSessionCommand(id))
        engine.commandAcknowledgement = CompletableDeferred()
        engine.restoreAcknowledgement!!.complete(Unit); runCurrent()
        a.coordinator.seekTo(AndroidSeekCommand(id, 500)); runCurrent()
        engine.commandAcknowledgement!!.complete(Unit); runCurrent()
        assertTrue(transfer.await().isFailure)
        assertEquals(500L, engine.position)
        assertFalse(engine.currentLiveEdge)
        a.finish(); b.finish()
    }
    @Test fun `accepted track and live edge during held restoration apply after its captured restore point`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val id = f.coordinator.load(request("live")).sessionId
        val engine = f.engines.single()
        engine.emit(YlEngineEvent.Snapshot(YlEngineSnapshot(AndroidPlaybackStatus.READY,
            timeline = emptyTimeline().copy(isLive = true),
            audioTracks = listOf(AndroidTrackMessage("new-track", AndroidTrackKind.AUDIO, isSelected = false)))))
        f.coordinator.onBackground(); runCurrent()
        engine.restoreAcknowledgement = CompletableDeferred()
        f.coordinator.onForeground(); runCurrent()
        f.coordinator.selectAudioTrack(AndroidTrackCommand(id, "new-track"))
        f.coordinator.seekToLiveEdge(AndroidSessionCommand(id))
        engine.restoreAcknowledgement!!.complete(Unit); runCurrent()
        assertEquals("new-track", engine.currentTrack)
        assertTrue(engine.currentLiveEdge)
        f.finish()
    }
    @Test fun `real host waits for worker rejection and returns exactly once without storing rejected intent`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val f = SessionFixture(dispatcher)
        val fixture = RegistryFixture(dispatcher, YlPlayerSessionFactory { { f.coordinator } })
        Dispatchers.setMain(dispatcher)
        val clock = mockStatic(android.os.SystemClock::class.java)
        try {
            val player = fixture.registry.create(createRequest())
            fixture.call(player.channelSuffix, "attach")
            val session = f.coordinator.load(request("good"))
            val engine = f.engines.single()
            engine.emit(YlEngineEvent.Snapshot(YlEngineSnapshot(AndroidPlaybackStatus.READY,
                audioTracks = listOf(AndroidTrackMessage("advertised", AndroidTrackKind.AUDIO, isSelected = false)))))
            val acknowledged = CompletableDeferred<Unit>()
            engine.commandAcknowledgement = acknowledged
            engine.commandError = YlBoundaryException(YlFailureKind.SOURCE_MISSING)
            val replies = mutableListOf<List<*>>()
            val message = AndroidPlayerHostApi.codec.encodeMessage(listOf(AndroidTrackCommand(session.sessionId, "advertised")))!!.apply { flip() }
            fixture.handlers.getValue(fixture.channel(player.channelSuffix, "selectAudioTrack")).onMessage(message) {
                replies += AndroidPlayerHostApi.codec.decodeMessage(it!!.apply { flip() }) as List<*>
            }
            runCurrent(); assertTrue(replies.isEmpty())
            acknowledged.complete(Unit); runCurrent()
            assertEquals(1, replies.size); assertEquals("source.missing", replies.single()[0])
            assertEquals(AndroidPlaybackStatus.READY, f.coordinator.initialState.status)
            f.coordinator.onBackground(); runCurrent(); f.coordinator.onForeground(); runCurrent()
            assertNull(engine.currentTrack)
            engine.commandError = null
            f.coordinator.selectAudioTrack(AndroidTrackCommand(session.sessionId, "advertised"))
            f.coordinator.play(AndroidSessionCommand(session.sessionId))
            assertEquals("advertised", engine.currentTrack); assertTrue(engine.playing)
        } finally { fixture.registry.detach(); runCurrent(); Dispatchers.resetMain(); clock.close() }
    }

    @Test fun `worker completion after stop or replacement cannot store intent in the new session`() = runTest {
        for (stop in listOf(false, true)) {
            val f = SessionFixture(StandardTestDispatcher(testScheduler))
            val id = f.coordinator.load(request("old")).sessionId
            val engine = f.engines.single()
            engine.emit(YlEngineEvent.Snapshot(YlEngineSnapshot(AndroidPlaybackStatus.READY,
                audioTracks = listOf(AndroidTrackMessage("old-track", AndroidTrackKind.AUDIO, isSelected = true)))))
            engine.commandAcknowledgement = CompletableDeferred()
            val command = async { runCatching { f.coordinator.selectAudioTrack(AndroidTrackCommand(id, "old-track")) } }
            runCurrent(); assertFalse(command.isCompleted)
            val replacement = async { if (stop) f.coordinator.stop() else f.coordinator.load(request("new")) }
            runCurrent()
            engine.commandAcknowledgement!!.complete(Unit); runCurrent()
            assertEquals(YlFailureKind.SESSION_STALE, (command.await().exceptionOrNull() as YlBoundaryException).kind)
            replacement.await()
            if (stop) f.coordinator.load(request("new"))
            f.coordinator.onBackground(); runCurrent(); f.coordinator.onForeground(); runCurrent()
            assertNull(f.engines.last().currentTrack)
            assertTrue(f.events.failures.isEmpty())
            f.finish()
        }
    }

    @Test fun `real host detach settles a pending asynchronous command once and ignores late worker result`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val f = SessionFixture(dispatcher)
        val fixture = RegistryFixture(dispatcher, YlPlayerSessionFactory { { f.coordinator } })
        Dispatchers.setMain(dispatcher)
        val clock = mockStatic(android.os.SystemClock::class.java)
        try {
            val player = fixture.registry.create(createRequest()); fixture.call(player.channelSuffix, "attach")
            val id = f.coordinator.load(request("good")).sessionId
            val engine = f.engines.single()
            engine.emit(YlEngineEvent.Snapshot(YlEngineSnapshot(AndroidPlaybackStatus.READY,
                audioTracks = listOf(AndroidTrackMessage("track", AndroidTrackKind.AUDIO, isSelected = true)))))
            engine.commandAcknowledgement = CompletableDeferred()
            val replies = mutableListOf<List<*>>()
            val message = AndroidPlayerHostApi.codec.encodeMessage(listOf(AndroidTrackCommand(id, "track")))!!.apply { flip() }
            fixture.handlers.getValue(fixture.channel(player.channelSuffix, "selectAudioTrack")).onMessage(message) {
                replies += AndroidPlayerHostApi.codec.decodeMessage(it!!.apply { flip() }) as List<*>
            }
            runCurrent(); assertTrue(replies.isEmpty())
            fixture.registry.detach(); runCurrent()
            assertEquals(1, replies.size); assertEquals("load.cancelled", replies.single()[0])
            engine.commandAcknowledgement!!.complete(Unit); runCurrent()
            assertEquals(1, replies.size); assertNull(engine.currentTrack)
        } finally { fixture.registry.detach(); runCurrent(); Dispatchers.resetMain(); clock.close() }
    }

    @Test fun `actual core rejects absent track and nonlive edge before mutating restore inputs`() = withCore { core, _, _ ->
        val prior = core.snapshotRestorePoint()
        assertEquals(YlFailureKind.SOURCE_MISSING, assertFailsWith<YlBoundaryException> { core.selectAudioTrack("missing-but-nonempty") }.kind)
        assertEquals(YlFailureKind.POLICY_UNSUPPORTED, assertFailsWith<YlBoundaryException> { core.seekToLiveEdge() }.kind)
        assertEquals(prior, core.snapshotRestorePoint())
        for (limit in listOf(1L, Int.MAX_VALUE.toLong())) {
            core.setVideoConstraints(AndroidVideoConstraintsMessage(limit, limit, limit))
            assertEquals(limit, core.snapshotRestorePoint().maxWidth)
            assertEquals(limit, core.snapshotRestorePoint().maxHeight)
            assertEquals(limit, core.snapshotRestorePoint().maxBitrate)
        }
        val accepted = core.snapshotRestorePoint()
        assertFailsWith<YlBoundaryException> { core.setVideoConstraints(AndroidVideoConstraintsMessage(maxWidth = 4_294_967_296L)) }
        assertEquals(accepted, core.snapshotRestorePoint())
    }

    @Test fun `two proven audio coordinators restore independently while first worker is held`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val shared = YlDecoderLeaseCoordinator(dispatcher) { testScheduler.currentTime }
        val a = SessionFixture(dispatcher, 1).also { it.coordinator.bindLeases(shared); it.next = FakeSessionEngine().apply { needsExclusiveLease = false } }
        val b = SessionFixture(dispatcher, 2).also { it.coordinator.bindLeases(shared); it.next = FakeSessionEngine().apply { needsExclusiveLease = false } }
        a.coordinator.load(request("a").withAutoplay(true)); b.coordinator.load(request("b").withAutoplay(true)); runCurrent()
        a.coordinator.onBackground(); b.coordinator.onBackground(); runCurrent()
        val acknowledgement = CompletableDeferred<Unit>()
        a.engines.single().restoreAcknowledgement = acknowledgement
        a.coordinator.onForeground(); runCurrent()
        b.coordinator.onForeground(); runCurrent()
        assertEquals(1, a.engines.single().restores)
        assertEquals(1, b.engines.single().foregroundCalls)
        assertTrue(b.engines.single().playing)
        assertEquals(0, a.engines.single().foregroundCalls)
        acknowledgement.complete(Unit); runCurrent()
        assertTrue(a.engines.single().playing)
        assertTrue(a.events.failures.isEmpty()); assertTrue(b.events.failures.isEmpty())
        a.finish(); b.finish()
    }
    @Test fun `production create rejects invalid intervals before texture allocation`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val factory = YlMedia3SessionFactory(mock(Application::class.java), dispatcher)
        val fixture = RegistryFixture(dispatcher, factory)
        for (interval in listOf(-1L, 0L, Int.MAX_VALUE.toLong() + 1, Long.MAX_VALUE)) {
            assertFailsWith<FlutterError>("interval=$interval") {
                fixture.registry.create(createRequest().copy(options = sessionOptions.copy(positionUpdateIntervalMs = interval)))
            }
        }
        verify(fixture.textures, never()).createSurfaceTexture()
        for (interval in listOf(1L, 5_000L, Int.MAX_VALUE.toLong())) {
            factory.prepare(sessionOptions.copy(positionUpdateIntervalMs = interval))
            assertEquals(interval, createMedia3Configuration(source(), request("x").options,
                sessionOptions.copy(positionUpdateIntervalMs = interval)).positionEventIntervalMs)
        }
    }

    @Test fun `load constraint ranges reject before cancelling pending load or creating engine`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val engine = FakeSessionEngine().apply { preparation = CompletableDeferred() }
        f.next = engine
        val pending = async { f.coordinator.load(request("held")) }
        runCurrent()
        for (value in listOf(-1L, 0L, Int.MAX_VALUE.toLong() + 1, 4_294_967_296L, Long.MAX_VALUE)) {
            for (constraints in listOf(AndroidVideoConstraintsMessage(maxWidth = value),
                AndroidVideoConstraintsMessage(maxHeight = value), AndroidVideoConstraintsMessage(maxBitrate = value))) {
                val invalid = request("invalid").let { it.copy(options = it.options.copy(videoConstraints = constraints)) }
                assertEquals(AndroidAssessmentOutcome.INCOMPATIBLE,
                    f.coordinator.assess(AndroidAssessRequest(invalid.source, invalid.options)).outcome)
                assertFailsWith<YlBoundaryException> { f.coordinator.load(invalid) }
                assertFalse(pending.isCompleted)
                assertEquals(1, f.engines.size)
            }
        }
        assertFailsWith<YlBoundaryException> { f.coordinator.load(request("")) }
        assertFalse(pending.isCompleted)
        engine.preparation!!.complete(Unit)
        runCurrent(); pending.await(); f.finish()
    }

    @Test fun `managed delays validate signed32 and ordering in actual assess and load`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val valid = AndroidNetworkPolicyMessage(AndroidNetworkPolicyKind.MANAGED, 1, 1, 0, 0, 0, 0)
        for (network in listOf(valid.copy(baseRetryDelayMs = -1), valid.copy(maxRetryDelayMs = -1),
            valid.copy(baseRetryDelayMs = 1), valid.copy(maxRetryDelayMs = Int.MAX_VALUE.toLong() + 1),
            valid.copy(baseRetryDelayMs = Int.MAX_VALUE.toLong() + 1, maxRetryDelayMs = Int.MAX_VALUE.toLong() + 1))) {
            val invalid = request("bad").copy(source = source().copy(networkPolicy = network))
            assertEquals(AndroidAssessmentOutcome.INCOMPATIBLE, f.coordinator.assess(AndroidAssessRequest(invalid.source, invalid.options)).outcome)
            assertFailsWith<YlBoundaryException> { f.coordinator.load(invalid) }
            assertTrue(f.engines.isEmpty())
        }
        for (delay in listOf(0L, Int.MAX_VALUE.toLong())) {
            val input = request("valid").copy(source = source().copy(networkPolicy = valid.copy(baseRetryDelayMs = delay, maxRetryDelayMs = delay)))
            f.coordinator.load(input)
        }
        f.finish()
    }

    @Test fun `all managed native integer fields preserve min max and reject one past before acceptance`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val max = Int.MAX_VALUE.toLong()
        val base = AndroidNetworkPolicyMessage(AndroidNetworkPolicyKind.MANAGED, 1, 1, 0, 0, 0, 0)
        val fields: List<Pair<Long, (Long) -> AndroidNetworkPolicyMessage>> = listOf(
            1L to { base.copy(connectTimeoutMs = it) }, 1L to { base.copy(readTimeoutMs = it) },
            0L to { base.copy(maxRetries = it) }, 0L to { base.copy(maxRedirects = it) },
            0L to { base.copy(baseRetryDelayMs = it, maxRetryDelayMs = max) },
            0L to { base.copy(maxRetryDelayMs = it) })
        for ((min, policy) in fields) {
            for (invalid in listOf(min - 1, max + 1)) {
                val input = request("invalid").copy(source = source().copy(networkPolicy = policy(invalid)))
                assertFailsWith<YlBoundaryException> { f.coordinator.load(input) }
            }
            for (valid in listOf(min, max)) {
                val input = request("valid").copy(source = source().copy(networkPolicy = policy(valid)))
                val result = f.coordinator.load(input)
                assertEquals(result.sessionId, f.coordinator.initialState.sessionId)
                val config = createMedia3Configuration(input.source, input.options, sessionOptions).network
                val actual = listOf(config.connectTimeoutMs.toLong(), config.readTimeoutMs.toLong(),
                    config.maxRetries.toLong(), config.baseRetryDelayMs, config.maxRetryDelayMs, config.maxRedirects.toLong())
                assertEquals(listOf(policy(valid).connectTimeoutMs, policy(valid).readTimeoutMs, policy(valid).maxRetries,
                    policy(valid).baseRetryDelayMs, policy(valid).maxRetryDelayMs, policy(valid).maxRedirects), actual)
            }
        }
        for (position in listOf(0L, Long.MAX_VALUE)) f.coordinator.load(request("position").let { it.copy(options = it.options.copy(startPositionMs = position)) })
        assertFailsWith<YlBoundaryException> { f.coordinator.load(request("negative").let { it.copy(options = it.options.copy(startPositionMs = -1)) }) }
        assertFailsWith<YlBoundaryException> { f.coordinator.play(AndroidSessionCommand("")) }
        f.finish()
    }

    @Test fun `runtime malformed commands leave healthy session and restore inputs unchanged`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val id = f.coordinator.load(request("good")).sessionId
        val engine = f.engines.single()
        for (volume in listOf(Double.NaN, Double.NEGATIVE_INFINITY, Double.POSITIVE_INFINITY, -0.1, 1.1))
            assertFailsWith<YlBoundaryException> { f.coordinator.setVolume(volume) }
        assertFailsWith<YlBoundaryException> { f.coordinator.seekTo(AndroidSeekCommand(id, -1)) }
        assertFailsWith<YlBoundaryException> { f.coordinator.selectAudioTrack(AndroidTrackCommand(id, "")) }
        for (value in listOf(0L, -1L, Int.MAX_VALUE.toLong() + 1, 4_294_967_296L))
            for (constraint in listOf(AndroidVideoConstraintsMessage(maxWidth = value), AndroidVideoConstraintsMessage(maxHeight = value), AndroidVideoConstraintsMessage(maxBitrate = value)))
                assertFailsWith<YlBoundaryException> { f.coordinator.setVideoConstraints(AndroidVideoConstraintsCommand(id, constraint)) }
        for (speed in listOf(Double.NaN, Double.NEGATIVE_INFINITY, Double.POSITIVE_INFINITY, 0.249, 4.001))
            assertFailsWith<YlBoundaryException> { f.coordinator.setPlaybackSpeed(AndroidSpeedCommand(id, speed)) }
        runCurrent()
        assertEquals(1.0, engine.currentVolume); assertEquals(0L, engine.position)
        f.coordinator.onBackground(); runCurrent(); f.coordinator.onForeground(); runCurrent()
        assertEquals(1.0, engine.currentVolume); assertEquals(0L, engine.position)
        assertTrue(f.events.failures.isEmpty())
        for (volume in listOf(0.0, 1.0)) { f.coordinator.setVolume(volume); runCurrent(); assertEquals(volume, engine.currentVolume) }
        for (speed in listOf(0.25, 4.0)) { f.coordinator.setPlaybackSpeed(AndroidSpeedCommand(id, speed)); runCurrent(); assertEquals(speed, engine.currentSpeed) }
        for (position in listOf(0L, Long.MAX_VALUE)) { f.coordinator.seekTo(AndroidSeekCommand(id, position)); runCurrent(); assertEquals(position, engine.position) }
        for (limit in listOf(1L, Int.MAX_VALUE.toLong())) f.coordinator.setVideoConstraints(AndroidVideoConstraintsCommand(id, AndroidVideoConstraintsMessage(limit, limit, limit)))
        f.finish()
    }

    @Test fun `real queued host replies reject missing track and VOD live edge without failing playback`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val f = SessionFixture(dispatcher)
        val fixture = RegistryFixture(dispatcher, YlPlayerSessionFactory { { f.coordinator } })
        Dispatchers.setMain(dispatcher)
        val clock = mockStatic(android.os.SystemClock::class.java)
        try {
            val player = fixture.registry.create(createRequest())
            fixture.call(player.channelSuffix, "attach")
            val load = fixture.load(player.channelSuffix, request("good"))
            load.first(); runCurrent()
            val id = (load.second().single() as AndroidLoadReply).sessionId
            val engine = f.engines.single()
            engine.commandError = YlBoundaryException(YlFailureKind.SOURCE_MISSING)
            for ((method, argument, code) in listOf(
                Triple("selectAudioTrack", AndroidTrackCommand(id, "missing-but-nonempty"), "source.missing"),
                Triple("seekToLiveEdge", AndroidSessionCommand(id), "policy.unsupported"))) {
                val response = fixture.invoke(fixture.handlers.getValue(fixture.channel(player.channelSuffix, method)), listOf(argument))
                runCurrent()
                assertEquals(code, response()[0])
                assertNotEquals(AndroidPlaybackStatus.FAILED, f.coordinator.initialState.status)
            }
            engine.commandError = null
            f.coordinator.play(AndroidSessionCommand(id))
            f.coordinator.onBackground(); runCurrent(); f.coordinator.onForeground(); runCurrent()
            assertNull(engine.currentTrack)
            assertFalse(engine.restoredLiveEdge)
            assertTrue(engine.playing)
            engine.emit(YlEngineEvent.Failed(YlFailureKind.NETWORK_FAILED))
            assertEquals(AndroidPlaybackStatus.FAILED, f.coordinator.initialState.status)
        } finally { fixture.registry.detach(); runCurrent(); Dispatchers.resetMain(); clock.close() }
    }

    @Test fun `core measured live offset preserves unknown and clamps negative for timeline metrics and restore`() = withCore { core, player, events ->
        `when`(player.isCurrentMediaItemLive).thenReturn(true)
        for ((raw, normalized) in listOf(C.TIME_UNSET to null, -1L to 0L, 0L to 0L, 3_000L to 3_000L)) {
            `when`(player.currentLiveOffset).thenReturn(raw)
            core.emitState()
            val snapshot = (events.last() as YlEngineEvent.Snapshot).value
            assertEquals(normalized, snapshot.timeline.liveOffsetMs, "raw=$raw")
            assertEquals(normalized, snapshot.metrics.liveOffsetMs, "raw=$raw")
            assertEquals(normalized?.let { it <= 2_000 }, snapshot.timeline.isAtLiveEdge)
            assertEquals(normalized?.let { it <= 2_000 } ?: false, core.snapshotRestorePoint().liveEdge)
        }
    }
}
