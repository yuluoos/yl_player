package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import java.net.URI
import android.os.SystemClock
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Main-owned transaction authority. Worker results enter only through immutable session identity. */
internal class YlSessionCoordinator(
    private val playerId: Long,
    private val options: AndroidPlayerOptionsMessage,
    private val output: YlSessionVideoOutput,
    private val engines: YlPlaybackEngineFactory,
    dispatcher: CoroutineDispatcher = Dispatchers.Main,
    clockMs: () -> Long = SystemClock::elapsedRealtime,
) : YlPlayerSession {
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val cleanup = CoroutineScope(SupervisorJob() + dispatcher)
    private val reducer = YlStateReducer(clockMs = clockMs)
    private val transaction = Mutex()
    private val owned = mutableSetOf<YlPlaybackEngineAdapter>()
    private var active: YlPreparedSession? = null
    private var pending: Deferred<AndroidLoadReply>? = null
    private var pendingCommitted = false
    private var autoplayPending: YlSessionIdentity? = null
    private var pendingIdentity: YlSessionIdentity? = null
    private var candidateSnapshot: YlEngineSnapshot? = null
    private var candidateFailure: YlFailureKind? = null
    private var stopping = false
    private var candidateFrame: YlEngineEvent.FirstFrame? = null
    private var operation = 0L
    private var loadSequence = 0L
    private var closed = false
    private var transacting = false
    private var closeResult: Deferred<Unit>? = null
    private var volume = 1.0
    private var backgrounded = false
    private var foreground = CompletableDeferred(Unit)
    private var backgroundPlayIntent: Pair<YlSessionIdentity, Boolean>? = null
    override val initialState get() = reducer.state
    override val capabilities = AndroidCapabilitiesMessage("android", listOf(AndroidEngine.MEDIA3),
        AndroidDecoderEvidence.NONE, hardwareVideoCodecs = emptyList(), supportedOperations = AndroidPlayerOperation.entries)
    override fun attach(events: YlPlayerEventSink) = reducer.attach(events)
    override fun assess(request: AndroidAssessRequest): AndroidAssessmentReply {
        checkOpen()
        val rejection = runCatching { validate(request.source, request.options) }.exceptionOrNull()
        return if (rejection != null) AndroidAssessmentReply(AndroidAssessmentOutcome.INCOMPATIBLE,
            AndroidEngine.MEDIA3, emptyList(), emptyList(), YlFailureMapper().toMessage(rejection))
        else AndroidAssessmentReply(AndroidAssessmentOutcome.REQUIRES_INSPECTION, AndroidEngine.MEDIA3,
            emptyList(), listOf("Media inspection is required."))
    }
    private fun validate(source: AndroidSourceMessage, load: AndroidLoadOptionsMessage) {
        val uri = runCatching { URI(source.locator) }.getOrNull()
        val validScheme = when (source.kind) {
            AndroidSourceKind.NETWORK -> uri?.scheme?.lowercase() in listOf("http", "https") && !uri?.host.isNullOrBlank()
            AndroidSourceKind.FILE -> uri?.scheme == "file" || (uri?.scheme == null && source.locator.startsWith("/"))
            AndroidSourceKind.CONTENT -> uri?.scheme == "content"
        }
        if (source.locator.isBlank() || !validScheme || (load.startPositionMs ?: 0) < 0) throw YlBoundaryException(YlFailureKind.SOURCE_INVALID)
        // Strict managed-route proof and hardware-required acquisition are supplied in Task 6.
        if (load.bufferStrategy.kind == AndroidBufferKind.BOUNDED ||
            source.networkPolicy?.kind == AndroidNetworkPolicyKind.MANAGED ||
            (load.decoderPolicyOverride ?: options.decoderPolicy) == AndroidDecoderPolicy.HARDWARE_REQUIRED ||
            !source.request?.credentials.isNullOrEmpty()) throw YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED)
    }
    override suspend fun load(request: AndroidLoadRequest): AndroidLoadReply {
        checkOpen()
        validate(request.source, request.options)
        stopping = false
        pendingCommitted = false
        val identity = YlSessionIdentity("a$playerId-s${++loadSequence}", request.loadRequestId)
        val token = ++operation
        pending?.cancel()
        val task = scope.async {
            transaction.withLock {
                checkGeneration(token)
                // A Load requested while hidden remains cancellable without allocating a decoder.
                foreground.await()
                checkGeneration(token)
                val former = active
                var restore: YlEngineRestorePoint? = null
                var candidate: YlPreparedSession? = null
                var committed = false
                transacting = true
                pendingIdentity = identity
                candidateFailure = null
                candidateSnapshot = null
                candidateFrame = null
                try {
                    // Include the same-player former engine in conservative scarce-decoder accounting.
                    try {
                        // Keep the acknowledged snapshot even if the caller cancels as the worker
                        // finishes; rollback needs it before the transaction can hand off resources.
                        restore = withContext(NonCancellable) { former?.engine?.quiesce() }
                    }
                    catch (error: Throwable) {
                        // A failed partial quiesce cannot leave a claimed playing former state.
                        if (former != null && error !is CancellationException) reducer.fail(YlFailureKind.DECODER_UNAVAILABLE)
                        throw error
                    }
                    checkGeneration(token)
                    val engine = engines.create(identity, request.source, request.options)
                    owned += engine
                    candidate = YlPreparedSession(identity, request.source, request.options, engine,
                        if ((request.options.decoderPolicyOverride ?: options.decoderPolicy) == AndroidDecoderPolicy.HARDWARE_PREFERRED)
                            YlDecoderRequirement.PREFERRED else YlDecoderRequirement.DEFAULT)
                    engine.registerCallback(::onEngineEvent)
                    engine.prepare()
                    candidateFailure?.let { throw YlBoundaryException(it) }
                    checkGeneration(token)
                    engine.setVolume(volume)
                    engine.activate(output)
                    candidateFailure?.let { throw YlBoundaryException(it) }
                    checkGeneration(token)
                    active = candidate
                    backgroundPlayIntent = null
                    autoplayPending = identity.takeIf { request.options.autoplay }
                    pendingCommitted = true
                    committed = true
                    transacting = false
                    pendingIdentity = null
                    reducer.commit(identity, output.identity)
                    val snapshot = candidateSnapshot
                    val frame = candidateFrame
                    // Loading is installed before any staged decoder/Ready callback is published.
                    scope.launch {
                        if (active?.identity == identity && token == operation) {
                            snapshot?.let(reducer::snapshot)
                            frame?.let { reducer.firstFrame(it.output, it.occurredAtMs) }
                            if (autoplayPending == identity && !backgrounded) {
                                runEngine(identity) { play() }
                                if (autoplayPending == identity) autoplayPending = null
                            }
                        }
                    }
                    former?.engine?.let(::releaseEngine)
                    AndroidLoadReply(identity.loadRequestId, identity.sessionId)
                } catch (error: Throwable) {
                    if (!committed) withContext(NonCancellable) {
                        candidate?.engine?.let { runCatching { releaseEngine(it).await() } }
                        if (!closed && !stopping && !backgrounded && restore != null && former != null) {
                            try { former.engine.restore(restore, output) }
                            catch (restoreError: Throwable) { reducer.fail(YlFailureKind.DECODER_UNAVAILABLE) }
                        }
                    }
                    if (error is CancellationException) throw YlBoundaryException(YlFailureKind.LOAD_CANCELLED)
                    throw error
                } finally {
                    if (pendingIdentity == identity) pendingIdentity = null
                    transacting = false
                }
            }
        }
        pending = task
        try { return task.await() }
        finally { if (!task.isCompleted) task.cancel(); if (pending === task) pending = null }
    }
    private fun onEngineEvent(identity: YlSessionIdentity, event: YlEngineEvent) {
        if (closed) return
        if (pendingIdentity == identity) {
            when (event) {
                is YlEngineEvent.Snapshot -> candidateSnapshot = event.value
                is YlEngineEvent.FirstFrame -> if (event.output == output.identity) candidateFrame = event
                is YlEngineEvent.Failed -> candidateFailure = event.kind
                else -> Unit
            }
            return
        }
        if (active?.identity != identity || transacting) return
        when (event) {
            is YlEngineEvent.Snapshot -> reducer.snapshot(event.value)
            is YlEngineEvent.Tick -> reducer.tick(event.timeline, event.metrics)
            is YlEngineEvent.FirstFrame -> if (!backgrounded && event.output == output.identity) {
                reducer.updateOutput(output.identity)
                reducer.firstFrame(event.output, event.occurredAtMs)
            }
            is YlEngineEvent.Failed -> reducer.fail(event.kind)
            is YlEngineEvent.Retry -> reducer.retry(event)
        }
    }
    private fun checkOpen() { if (closed) throw YlBoundaryException(YlFailureKind.PLAYER_DISPOSED) }
    private suspend fun checkGeneration(token: Long) { checkOpen(); currentCoroutineContext().ensureActive(); if (token != operation) throw YlBoundaryException(YlFailureKind.LOAD_CANCELLED) }
    private fun current(id: String): YlPreparedSession {
        checkOpen()
        return active?.takeIf { it.sessionId == id } ?: throw YlBoundaryException(YlFailureKind.SESSION_STALE)
    }
    private suspend fun runEngine(identity: YlSessionIdentity, action: suspend YlPlaybackEngineAdapter.() -> Unit) {
        val session = active?.takeIf { it.identity == identity } ?: return
        try { session.engine.action() } catch (error: Throwable) {
            if (active?.identity == identity && !closed) reducer.fail((error as? YlBoundaryException)?.kind ?: YlFailureKind.PLATFORM_FAILURE)
        }
    }
    private fun enqueue(id: String, action: suspend YlPlaybackEngineAdapter.() -> Unit) {
        val identity = current(id).identity
        scope.launch { transaction.withLock { runEngine(identity, action) } }
    }
    override suspend fun play(command: AndroidSessionCommand) {
        val session = current(command.sessionId)
        if (autoplayPending == session.identity) autoplayPending = null
        if (backgrounded) { backgroundPlayIntent = session.identity to true; return }
        transaction.withLock {
            val current = current(command.sessionId)
            if (backgrounded) backgroundPlayIntent = current.identity to true else current.engine.play()
        }
    }
    override fun pause(command: AndroidSessionCommand) {
        val session = current(command.sessionId)
        if (autoplayPending == session.identity) autoplayPending = null
        if (backgrounded) backgroundPlayIntent = session.identity to false
        enqueue(command.sessionId) { pause() }
    }
    override fun seekTo(command: AndroidSeekCommand) = enqueue(command.sessionId) { seekTo(command.positionMs.coerceAtLeast(0)) }
    override fun seekToLiveEdge(command: AndroidSessionCommand) = enqueue(command.sessionId) { seekToLiveEdge() }
    override fun setPlaybackSpeed(command: AndroidSpeedCommand) {
        current(command.sessionId)
        if (!command.speed.isFinite() || command.speed !in 0.25..4.0) throw YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED)
        enqueue(command.sessionId) { setPlaybackSpeed(command.speed) }
    }
    override fun selectAudioTrack(command: AndroidTrackCommand) = enqueue(command.sessionId) { selectAudioTrack(command.trackId) }
    override fun setVideoConstraints(command: AndroidVideoConstraintsCommand) = enqueue(command.sessionId) { setVideoConstraints(command.constraints) }
    override fun setVolume(volume: Double) { checkOpen(); this.volume = volume.coerceIn(0.0, 1.0); active?.let { enqueue(it.sessionId) { setVolume(this@YlSessionCoordinator.volume) } } }
    override suspend fun stop() {
        checkOpen(); stopping = true; ++operation; pending?.cancel()
        transaction.withLock {
            active?.engine?.stop()
            active?.engine?.let(::releaseEngine)
            active = null
            backgroundPlayIntent = null
            autoplayPending = null
            reducer.idle()
        }
    }
    private fun releaseEngine(engine: YlPlaybackEngineAdapter): Deferred<Unit> = cleanup.async {
        try { engine.dispose().await() }
        catch (error: Throwable) { YlFailureMapper().record(error); throw error }
        finally { owned.remove(engine) }
    }
    override fun close(): Deferred<Unit> {
        closeResult?.let { return it }
        closed = true; ++operation; pending?.cancel(); scope.cancel()
        return cleanup.async {
            transaction.withLock {
                // Safe exceptional completion still requires *every* borrower to finish.
                val failures = owned.toList().map { engine -> async { runCatching { engine.dispose().await() }.exceptionOrNull() } }.awaitAll()
                owned.clear(); active = null
                backgroundPlayIntent = null
                autoplayPending = null
                output.release()
                failures.filterNotNull().firstOrNull()?.let { throw it }
                Unit
            }
        }.also { closeResult = it }
    }
    override fun onForeground() {
        if (closed || !backgrounded) return
        backgrounded = false
        foreground.complete(Unit)
        scope.launch {
            transaction.withLock {
                if (backgrounded) return@withLock
                val session = active ?: return@withLock
                val intent = backgroundPlayIntent?.takeIf { it.first == session.identity }
                var applied = false
                runEngine(session.identity) {
                    if (intent?.second == false) pause()
                    onForeground()
                    if (!backgrounded && backgroundPlayIntent == intent) {
                        if (intent?.second == true) play()
                        applied = true
                    }
                }
                if (applied && backgroundPlayIntent == intent) backgroundPlayIntent = null
                if (applied && intent != null && autoplayPending == session.identity) autoplayPending = null
            }
        }
    }
    override fun onBackground() {
        if (closed || backgrounded) return
        backgrounded = true
        foreground = CompletableDeferred()
        // A bounce must not erase an explicit command whose foreground application is queued or
        // still suspended. Autoplay is only a fallback when no current-session intent is pending.
        backgroundPlayIntent = backgroundPlayIntent?.takeIf { it.first == active?.identity }
            ?: autoplayPending?.takeIf { it == active?.identity }?.let { it to true }
        ++operation
        // A committed state already owns its reply. Only an uncommitted candidate is cancelled.
        if (!pendingCommitted) pending?.cancel()
        // Background only relinquishes resources, so it need not wait behind a candidate's safe
        // cleanup. The immutable former identity prevents it from affecting a later session.
        val session = active ?: return
        scope.launch {
            runEngine(session.identity) { onBackground() }
            if (backgrounded && active?.identity == session.identity) reducer.pauseForLifecycle()
        }
    }
    override fun onTrimMemory(level: Int) { active?.let { enqueue(it.sessionId) { onTrimMemory(level) } } }
    override fun onConfigurationChanged() { active?.let { enqueue(it.sessionId) { onConfigurationChanged() } } }
}
