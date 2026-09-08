package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class YlSessionCoordinatorTest {
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
        assertEquals(1, f.engines.single().restores)
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
    @Test fun `safe cleanup error does not skip restoration or replace original preparation failure`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        f.coordinator.load(request("one"))
        f.next = FakeSessionEngine().apply {
            prepareError = YlBoundaryException(YlFailureKind.SOURCE_MISSING)
            release = CompletableDeferred<Unit>().apply { completeExceptionally(IllegalStateException()) }
        }
        assertEquals(YlFailureKind.SOURCE_MISSING, assertFailsWith<YlBoundaryException> { f.coordinator.load(request("two")) }.kind)
        assertEquals(1, f.engines.first().restores)
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
        assertEquals(1, f.engines.first().restores)
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
internal class SessionFixture(dispatcher: CoroutineDispatcher) {
    val output = FakeSessionOutput()
    val engines = mutableListOf<FakeSessionEngine>()
    var next: FakeSessionEngine? = null
    val events = SessionEvents()
    val coordinator = YlSessionCoordinator(7, sessionOptions, output, YlPlaybackEngineFactory { identity, _, _ ->
        (next ?: FakeSessionEngine()).also { next = null; it.identity = identity; engines += it }
    }, dispatcher, clockMs = { 123L }).also { it.attach(events) }
    suspend fun finish() { coordinator.close().await() }
}
internal class FakeSessionEngine : YlPlaybackEngineAdapter {
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
    var backgrounded = false
    var playing = false
    var playbackIntended = false
    var foregroundCalls = 0
    var foregroundAcknowledgement: CompletableDeferred<Unit>? = null
    override fun registerCallback(callback: (YlSessionIdentity, YlEngineEvent) -> Unit) { this.callback = callback }
    fun emit(event: YlEngineEvent) { callback?.invoke(identity, event) }
    override suspend fun prepare() { preparation?.await(); prepareError?.let { throw it } }
    override suspend fun activate(output: YlSessionVideoOutput) { onActivate?.invoke(); activationError?.let { throw it } }
    override suspend fun quiesce(): YlEngineRestorePoint { quiesces++; quiesceAcknowledgement?.await(); quiesceError?.let { throw it }; playing = false; return YlEngineRestorePoint(0, false, playbackIntended) }
    override suspend fun restore(point: YlEngineRestorePoint, output: YlSessionVideoOutput) { restores++; playbackIntended = point.playbackIntended; playing = playbackIntended }
    override suspend fun play() { playCalls++; playbackIntended = true; playing = true }
    override suspend fun pause() { playbackIntended = false; playing = false }
    override suspend fun seekTo(positionMs: Long) = Unit
    override suspend fun seekToLiveEdge() = Unit
    override suspend fun setPlaybackSpeed(speed: Double) = Unit
    override suspend fun selectAudioTrack(trackId: String) = Unit
    override suspend fun setVideoConstraints(constraints: AndroidVideoConstraintsMessage) = Unit
    override suspend fun setVolume(volume: Double) = Unit
    override suspend fun stop() { stops++ }
    override fun dispose(): Deferred<Unit> { disposals++; playing = false; return release ?: CompletableDeferred(Unit) }
    override suspend fun onForeground() { foregroundCalls++; foregroundAcknowledgement?.await(); backgrounded = false; playing = playbackIntended }
    override suspend fun onBackground() { backgrounded = true; playing = false }
    override suspend fun onTrimMemory(level: Int) = Unit
    override suspend fun onConfigurationChanged() = Unit
}
