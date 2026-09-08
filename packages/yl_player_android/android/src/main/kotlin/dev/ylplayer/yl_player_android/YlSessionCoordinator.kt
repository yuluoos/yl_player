package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
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
    private val decoderEvidence: YlDecoderEvidenceProvider = YlDecoderEvidenceProvider.collect(),
    private val audioFocus: (() -> YlAudioFocusCoordinator)? = null,
) : YlPlayerSession {
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val cleanup = CoroutineScope(SupervisorJob() + dispatcher)
    private val reducer = YlStateReducer(clockMs = clockMs)
    private val transaction = Mutex()
    private lateinit var leases: YlDecoderLeaseCoordinator
    private var activeLease: SessionLease? = null
    override fun bindLeases(leases: YlDecoderLeaseCoordinator) { check(active == null); this.leases = leases }
    private val owned = mutableSetOf<YlPlaybackEngineAdapter>()
    private var active: YlPreparedSession? = null
    private var pending: Deferred<AndroidLoadReply>? = null
    private var pendingCommitted = false
    private var autoplayPending: YlSessionIdentity? = null
    private var pendingIdentity: YlSessionIdentity? = null
    private var candidateEngine: YlPlaybackEngineAdapter? = null
    private var candidateSnapshot: YlEngineSnapshot? = null
    private var candidateFailure: YlFailureKind? = null
    private var stopping = false
    private var candidateFrame: YlEngineEvent.FirstFrame? = null
    private val candidateRetries = mutableListOf<YlEngineEvent.Retry>()
    private var operation = 0L
    private var loadSequence = 0L
    private var closed = false
    private var transacting = false
    private var inCommit = false
    private var closeResult: Deferred<Unit>? = null
    private var volume = 1.0
    private val managedAudio = options.audioPolicy == AndroidAudioPolicy.PLUGIN_MANAGED_MEDIA_PLAYBACK
    private var audioOwner: YlAudioFocusCoordinator? = null
    private var audioIntended = false
    private var focusPaused = false
    private var duckMultiplier = 1.0
    private var audioGeneration = 0L
    private val audioParticipant = YlAudioFocusParticipant(::onAudioFocus)
    private fun effectiveVolume() = volume * duckMultiplier
    private fun acquireAudio() {
        if (!managedAudio) return
        val owner = audioOwner ?: checkNotNull(audioFocus).invoke()
        if (!owner.acquire(audioParticipant)) throw YlBoundaryException(YlFailureKind.RESOURCE_EXHAUSTED)
        audioOwner = owner
        duckMultiplier = owner.volumeMultiplier
    }
    private fun releaseAudio() {
        audioOwner?.release(audioParticipant)
        audioOwner = null
        focusPaused = false
        duckMultiplier = 1.0
        audioGeneration++
    }
    private fun onAudioFocus(change: YlAudioFocusChange) {
        if (closed || !managedAudio) return
        val identity = active?.identity ?: return
        val wasPaused = focusPaused
        when (change) {
            YlAudioFocusChange.DUCK -> duckMultiplier = 0.2
            YlAudioFocusChange.GAIN -> { duckMultiplier = 1.0; focusPaused = false }
            YlAudioFocusChange.LOSS_TRANSIENT -> { focusPaused = true; duckMultiplier = 1.0 }
            YlAudioFocusChange.LOSS, YlAudioFocusChange.NOISY -> {
                focusPaused = false; duckMultiplier = 1.0; audioIntended = false
                activeLease?.desiredPlay = false
                if (autoplayPending == identity) autoplayPending = null
                if (backgrounded) backgroundPlayIntent = identity to false
            }
        }
        val generation = ++audioGeneration
        scope.launch { transaction.withLock {
            if (closed || active?.identity != identity || generation != audioGeneration) return@withLock
            val lease = activeLease ?: return@withLock
            if (!backgrounded && !lease.quiescing && lease.suspended == null) runEngine(identity) {
                setVolume(effectiveVolume())
                if (closed || backgrounded || active?.identity != identity || generation != audioGeneration ||
                    activeLease !== lease || lease.quiescing || lease.suspended != null) return@runEngine
                when {
                    focusPaused -> pauseForAudioFocus()
                    !audioIntended -> pause()
                    change == YlAudioFocusChange.GAIN && wasPaused -> { acquireAudio(); play() }
                }
            }
            if (!audioIntended) releaseAudio()
        } }
    }
    private suspend fun playWithAudio(engine: YlPlaybackEngineAdapter) {
        val identity = active?.takeIf { it.engine === engine }?.identity ?: return
        val generation = audioGeneration
        acquireAudio()
        try {
            engine.setVolume(effectiveVolume())
            val lease = activeLease
            if (closed || active?.identity != identity) return
            if (backgrounded || generation != audioGeneration || lease?.quiescing == true || lease?.suspended != null || focusPaused) {
                // Preserve a current explicit/autoplay intention across the volume worker await.
                if (audioIntended) {
                    lease?.desiredPlay = true
                    if (backgrounded) backgroundPlayIntent = identity to true
                }
                return
            }
            engine.play()
        } catch (error: Throwable) { releaseAudio(); throw error }
    }
    private var backgrounded = false
    private var lifecycleGeneration = 0L
    private data class BackgroundRelease(
        val identity: YlSessionIdentity,
        val lease: SessionLease,
        val completion: Deferred<Unit>,
    )
    private var backgroundRelease: BackgroundRelease? = null
    private var foreground = CompletableDeferred(Unit)
    private var backgroundPlayIntent: Pair<YlSessionIdentity, Boolean>? = null
    override val initialState get() = reducer.state
    override val capabilities = AndroidCapabilitiesMessage("android", listOf(AndroidEngine.MEDIA3),
        decoderEvidence.capability, hardwareVideoCodecs = decoderEvidence.hardwareCodecs, supportedOperations = AndroidPlayerOperation.entries)
    private var eventSink: YlPlayerEventSink? = null
    override fun attach(events: YlPlayerEventSink) { eventSink = events; reducer.attach(events) }
    override fun assess(request: AndroidAssessRequest): AndroidAssessmentReply {
        checkOpen()
        return assessment.assess(request.source, request.options, request.options.decoderPolicyOverride ?: options.decoderPolicy)
    }
    private val assessment = YlSourceAssessment(decoderEvidence)
    private fun validate(source: AndroidSourceMessage, load: AndroidLoadOptionsMessage) {
        val decision = assessment.assess(source, load, load.decoderPolicyOverride ?: options.decoderPolicy)
        decision.rejection?.let { throw YlBoundaryException(when (it.code) {
            "policy.unsupported" -> YlFailureKind.POLICY_UNSUPPORTED
            "decoder.unavailable" -> YlFailureKind.DECODER_UNAVAILABLE
            else -> YlFailureKind.SOURCE_INVALID
        }) }
    }
    override suspend fun load(request: AndroidLoadRequest): AndroidLoadReply {
        checkOpen()
        YlBoundaryValidation.identity(request.loadRequestId)
        validate(request.source, request.options)
        stopping = false
        pendingCommitted = false
        val identity = YlSessionIdentity("a$playerId-s${++loadSequence}", request.loadRequestId)
        val token = ++operation
        pending?.cancel()
        leases.cancel(playerId.toString())
        val task = scope.async {
            transaction.withLock {
                checkGeneration(token)
                // A Load requested while hidden remains cancellable without allocating a decoder.
                foreground.await()
                checkGeneration(token)
                active?.let { session -> activeLease?.let { awaitBackgroundRelease(session.identity, it) } }
                checkGeneration(token)
                val former = active
                var candidate: YlPreparedSession? = null
                var committed = false
                transacting = false
                pendingIdentity = identity
                candidateFailure = null
                candidateSnapshot = null
                candidateFrame = null
                candidateRetries.clear()
                try {
                    val engine = engines.create(identity, request.source, request.options)
                    owned += engine
                    candidateEngine = engine
                    candidate = YlPreparedSession(identity, request.source, request.options, engine,
                        when (request.options.decoderPolicyOverride ?: options.decoderPolicy) {
                            AndroidDecoderPolicy.HARDWARE_REQUIRED -> YlDecoderRequirement.HARDWARE_REQUIRED
                            AndroidDecoderPolicy.HARDWARE_PREFERRED -> YlDecoderRequirement.PREFERRED
                            AndroidDecoderPolicy.SYSTEM_DEFAULT -> YlDecoderRequirement.DEFAULT
                        })
                    engine.registerCallback(::onEngineEvent)
                    val participant = SessionLease(candidate) {
                        active = candidate
                        audioIntended = request.options.autoplay
                        audioGeneration++
                        // Same-player replacement keeps its shared lease through successful handoff.
                        if (!audioIntended) releaseAudio()
                        backgroundPlayIntent = null
                        autoplayPending = identity.takeIf { request.options.autoplay }
                        pendingCommitted = true
                        committed = true
                        transacting = false
                        pendingIdentity = null
                        reducer.commit(identity, output.identity)
                        // commitLease has crossed its final fallible check and installed activeLease.
                        // Preserve occurrence time and retry order; the reducer only enqueues events.
                        val retries = candidateRetries.toList()
                        candidateRetries.clear()
                        for (retry in retries) {
                            if (!closed && active?.identity == identity && token == operation) reducer.retry(retry)
                        }
                        val snapshot = candidateSnapshot
                        val frame = candidateFrame
                        // Loading is installed before any staged decoder/Ready callback is published.
                        scope.launch {
                            if (active?.identity == identity && token == operation) {
                                snapshot?.let(reducer::snapshot)
                                frame?.let { reducer.firstFrame(it.output, it.occurredAtMs) }
                                if (autoplayPending == identity && !backgrounded) {
                                    runEngine(identity) { playWithAudio(this) }
                                    if (autoplayPending == identity) autoplayPending = null
                                }
                            }
                        }
                        former?.engine?.let(::releaseEngine)
                    }
                    leases.acquire(participant, activeLease?.takeIf { it.suspended == null }) {
                        engine.prepare()
                        candidateFailure?.let { throw YlBoundaryException(it) }
                        checkGeneration(token)
                    }
                    AndroidLoadReply(identity.loadRequestId, identity.sessionId)
                } catch (error: Throwable) {
                    if (!committed) withContext(NonCancellable) {
                        candidate?.engine?.let { runCatching { releaseEngine(it).await() } }
                    }
                    if (error is CancellationException) throw YlBoundaryException(YlFailureKind.LOAD_CANCELLED)
                    throw error
                } finally {
                    if (pendingIdentity == identity) { pendingIdentity = null; candidateRetries.clear() }
                    if (candidateEngine === candidate?.engine) candidateEngine = null
                    transacting = false
                }
            }
        }
        pending = task
        try { return task.await() }
        finally { if (!task.isCompleted) task.cancel(); if (pending === task) pending = null }
    }
    private inner class SessionLease(
        val session: YlPreparedSession,
        val commit: () -> Unit,
    ) : YlDecoderLeaseParticipant {
        override val leaseId get() = session.sessionId
        override val playerLeaseId get() = playerId.toString()
        override val needsExclusiveLease get() = session.engine.needsExclusiveLease
        override val canRestore get() = !resourcesFailed && !closed && !stopping && !backgrounded && active?.identity == session.identity
        var suspended: YlLeaseSnapshot? = null
        var quiescing = false
            private set
        private var quiesceOperation: Deferred<YlLeaseSnapshot>? = null
        private var committedOnce = false
        private var restoring = false
        private var restorationSnapshot: YlEngineSnapshot? = null
        fun stageRestoration(event: YlEngineEvent) {
            if (restoring && event is YlEngineEvent.Snapshot) restorationSnapshot = event.value
        }
        private fun beginRestore() { restoring = true; restorationSnapshot = null }
        private fun publishRestoration() {
            val snapshot = restorationSnapshot
            restoring = false
            restorationSnapshot = null
            if (canRestore) snapshot?.let(reducer::snapshot)
        }
        override var leaseCommitVersion = 0L
            private set
        override fun publicationFailed(error: Throwable) {
            try { eventSink?.onBoundaryFailure(error) } finally { close() }
        }
        private var resourcesFailed = false
        var desiredSpeed: Double? = null
        var desiredTrack: String? = null
        var desiredPosition: Long? = null
        var desiredLiveEdge: Boolean? = null
        var desiredPlay: Boolean? = null
        var desiredConstraints: AndroidVideoConstraintsMessage? = null
        var selectionVersion = 0L
        private suspend fun applyLateSelections(appliedVersion: Long) {
            var applied = appliedVersion
            while (applied != selectionVersion && canRestore) {
                val version = selectionVersion
                val track = desiredTrack
                val liveEdge = desiredLiveEdge
                val position = desiredPosition
                track?.let { session.engine.selectAudioTrack(it) }
                if (!canRestore) return
                if (version != selectionVersion) continue
                if (liveEdge == true) session.engine.seekToLiveEdge()
                else if (liveEdge == false && position != null) session.engine.seekTo(position)
                applied = version
            }
        }
        fun resetRuntimeEdits() {
            desiredSpeed = null; desiredTrack = null; desiredPosition = null
            desiredLiveEdge = null; desiredPlay = null; desiredConstraints = null
        }
        private fun restorePoint(point: YlEngineRestorePoint): YlEngineRestorePoint {
            val intended = backgroundPlayIntent?.takeIf { it.first == session.identity }?.second
                ?: desiredPlay ?: if (managedAudio) audioIntended else point.playbackIntended
            val permitted = intended && (!managedAudio || !focusPaused)
            if (permitted) acquireAudio()
            return point.copy(
                speed = desiredSpeed ?: point.speed,
                selectedAudioTrack = desiredTrack ?: point.selectedAudioTrack,
                positionMs = desiredPosition ?: point.positionMs,
                liveEdge = desiredLiveEdge ?: point.liveEdge,
                playbackIntended = permitted,
                volume = effectiveVolume(),
                maxWidth = if (desiredConstraints != null) desiredConstraints?.maxWidth else point.maxWidth,
                maxHeight = if (desiredConstraints != null) desiredConstraints?.maxHeight else point.maxHeight,
                maxBitrate = if (desiredConstraints != null) desiredConstraints?.maxBitrate else point.maxBitrate,
            )
        }
        private fun <T> operation(complete: (Result<T>) -> Unit, retain: Boolean = false, action: suspend () -> T): YlCancelHandle {
            val job = cleanup.launch { complete(runCatching { action() }) }
            return YlCancelHandle { if (!retain) job.cancel() }
        }
        override fun quiesceForLease(attempt: YlLeaseAttempt, complete: (Result<YlLeaseSnapshot>) -> Unit): YlCancelHandle {
            val lifecycleRelease = backgroundRelease?.takeIf { it.identity == session.identity && it.lease === this }
            if (lifecycleRelease != null) return operation(complete, retain = true) {
                lifecycleRelease.completion.await()
                beginQuiesce().await()
            }
            // Install the fence synchronously, before returning the cancellable stage handle.
            val pending = beginQuiesce()
            return operation(complete, retain = true) { pending.await() }
        }
        fun beginQuiesce(): Deferred<YlLeaseSnapshot> {
            ensureResourcesUsable()
            quiesceOperation?.takeUnless { it.isCompleted }?.let { return it }
            suspended?.let { return CompletableDeferred(it) }
            quiescing = true
            transacting = true
            resetRuntimeEdits()
            return cleanup.async(start = CoroutineStart.LAZY) {
                try {
                    YlLeaseSnapshot(session.identity, session.source, session.options, session.engine.quiesce(), output.identity)
                        .also { suspended = it }
                } catch (error: Throwable) {
                    restorationFailed()
                    // A partial native quiesce may have no safe acknowledgement. Retain ownership
                    // until independent disposal confirms release; failed metadata stays authoritative.
                    cleanup.launch {
                        runCatching { disposeForLease().await() }
                        leases.relinquish(this@SessionLease)
                    }
                    throw error
                } finally {
                    // Failure has a resource fence; success has its acknowledged snapshot. Clearing
                    // this pending flag alone is never evidence that a decoder can be reacquired.
                    quiescing = false
                }
            }.also { quiesceOperation = it; it.start() }
        }
        fun ensureResourcesUsable() {
            if (resourcesFailed) throw YlBoundaryException(YlFailureKind.RESOURCE_EXHAUSTED)
        }
        override val activationTimeoutFailure get() = if (session.decoderRequirement == YlDecoderRequirement.HARDWARE_REQUIRED) YlFailureKind.DECODER_UNAVAILABLE else YlFailureKind.RESOURCE_EXHAUSTED
        override fun activateForLease(attempt: YlLeaseAttempt, complete: (Result<Unit>) -> Unit) = operation(complete) {
            ensureResourcesUsable()
            val restore = suspended
            val selectionAtRestore = selectionVersion
            if (restore == null) session.engine.activate(output) else {
                beginRestore()
                session.engine.restore(restorePoint(restore.runtime), output)
            }
            // Player volume can change while codec initialization is suspended.
            session.engine.setVolume(effectiveVolume())
            if (restore != null) applyLateSelections(selectionAtRestore)
            candidateFailure?.takeIf { pendingIdentity == session.identity }?.let { throw YlBoundaryException(it) }
            if (closed || backgrounded || stopping) throw CancellationException()
        }
        override fun commitLease() {
            if (closed || backgrounded || stopping) throw CancellationException()
            candidateFailure?.takeIf { pendingIdentity == session.identity }?.let { throw YlBoundaryException(it) }
            // Linearization: all fallible validation precedes this point. The installed event
            // ingress only enqueues; asynchronous callback failure closes the host, not rollback.
            leaseCommitVersion++
            activeLease = this
            suspended = null
            transacting = false
            if (!committedOnce) {
                inCommit = true
                try { commit(); committedOnce = true } finally { inCommit = false }
            }
            publishRestoration()
        }
        override fun rollbackLease(snapshot: YlLeaseSnapshot, attempt: YlLeaseAttempt, complete: (Result<Unit>) -> Unit) = operation(complete) {
            beginRestore()
            val selectionAtRestore = selectionVersion
            session.engine.restore(restorePoint(snapshot.runtime), output)
            session.engine.setVolume(effectiveVolume())
            applyLateSelections(selectionAtRestore)
            if (canRestore) { suspended = null; transacting = false; publishRestoration() }
        }
        override fun deactivateAfterLeaseTransfer() {
            transacting = false
            if (active?.identity == session.identity) {
                releaseAudio()
                reducer.pauseForLifecycle()
            }
        }
        override fun disposeForLease() = releaseEngine(session.engine)
        override fun restorationFailed() { releaseAudio(); resourcesFailed = true; transacting = false; reducer.fail(YlFailureKind.RESOURCE_EXHAUSTED) }
    }

    private fun onEngineEvent(identity: YlSessionIdentity, event: YlEngineEvent) {
        if (closed) return
        if (pendingIdentity == identity) {
            when (event) {
                is YlEngineEvent.Snapshot -> candidateSnapshot = event.value
                is YlEngineEvent.FirstFrame -> if (event.output == output.identity) candidateFrame = event
                is YlEngineEvent.Failed -> candidateFailure = event.kind
                is YlEngineEvent.Retry -> candidateRetries += event
                else -> Unit
            }
            return
        }
        if (active?.identity != identity) return
        if (transacting || activeLease?.suspended != null) {
            activeLease?.stageRestoration(event)
            return
        }
        when (event) {
            is YlEngineEvent.Snapshot -> {
                reducer.snapshot(event.value)
                if (event.value.status == AndroidPlaybackStatus.COMPLETED) { audioIntended = false; releaseAudio() }
            }
            is YlEngineEvent.Tick -> reducer.tick(event.timeline, event.metrics)
            is YlEngineEvent.FirstFrame -> if (!backgrounded && event.output == output.identity) {
                reducer.updateOutput(output.identity)
                reducer.firstFrame(event.output, event.occurredAtMs)
            }
            is YlEngineEvent.Failed -> { releaseAudio(); reducer.fail(event.kind) }
            is YlEngineEvent.Retry -> reducer.retry(event)
        }
    }
    private fun checkOpen() { if (closed) throw YlBoundaryException(YlFailureKind.PLAYER_DISPOSED) }
    private suspend fun checkGeneration(token: Long) { checkOpen(); currentCoroutineContext().ensureActive(); if (token != operation) throw YlBoundaryException(YlFailureKind.LOAD_CANCELLED) }
    private fun current(id: String): YlPreparedSession {
        checkOpen()
        YlBoundaryValidation.identity(id)
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
        activeLease?.ensureResourcesUsable()
        activeLease?.desiredPlay = true
        audioIntended = true; audioGeneration++
        if (autoplayPending == session.identity) autoplayPending = null
        if (backgrounded) { backgroundPlayIntent = session.identity to true; return }
        transaction.withLock {
            val current = current(command.sessionId)
            val lease = activeLease
            if (lease != null) awaitBackgroundRelease(current.identity, lease)
            current(command.sessionId)
            if (backgrounded) backgroundPlayIntent = current.identity to true else {
                lease?.takeIf { it.quiescing || it.suspended != null }?.let { leases.acquire(it) {} }
                lease?.ensureResourcesUsable()
                playWithAudio(current.engine)
            }
        }
    }
    override fun pause(command: AndroidSessionCommand) {
        val session = current(command.sessionId)
        activeLease?.desiredPlay = false
        audioIntended = false; audioGeneration++
        if (autoplayPending == session.identity) autoplayPending = null
        if (backgrounded) backgroundPlayIntent = session.identity to false
        enqueue(command.sessionId) { pause(); releaseAudio() }
    }
    override fun seekTo(command: AndroidSeekCommand) {
        current(command.sessionId)
        YlBoundaryValidation.position(command.positionMs)
        activeLease?.desiredPosition = command.positionMs
        activeLease?.desiredLiveEdge = false
        activeLease?.let { it.selectionVersion++ }
        enqueue(command.sessionId) { seekTo(command.positionMs) }
    }
    override suspend fun seekToLiveEdge(command: AndroidSessionCommand) = acceptedCommand(command.sessionId,
        validate = {
            if (!reducer.state.timeline.isLive) throw YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED)
        }, apply = { seekToLiveEdge() }, remember = { desiredLiveEdge = true })

    /** Command rejection returns through the owned host coroutine. A worker exception here is
     * not a playback event. Retain intent only after eligibility/worker acknowledgement, and
     * never write an old command into a replacement, stopped or newly suspended lease. */
    private suspend fun acceptedCommand(
        id: String,
        validate: () -> Unit,
        apply: suspend YlPlaybackEngineAdapter.() -> Unit,
        remember: SessionLease.() -> Unit,
    ) {
        val session = current(id)
        val lease = checkNotNull(activeLease)
        validate()
        lease.ensureResourcesUsable()
        if (lease.quiescing || lease.suspended != null) { lease.remember(); lease.selectionVersion++; return }
        val token = operation
        transaction.withLock {
            current(id)
            currentCoroutineContext().ensureActive()
            if (activeLease !== lease || operation != token) throw YlBoundaryException(YlFailureKind.SESSION_STALE)
            validate()
            lease.ensureResourcesUsable()
            if (!lease.quiescing && lease.suspended == null) session.engine.apply()
            currentCoroutineContext().ensureActive()
            current(id)
            if (activeLease !== lease || operation != token) throw YlBoundaryException(YlFailureKind.SESSION_STALE)
            lease.remember()
            lease.selectionVersion++
        }
    }
    override fun setPlaybackSpeed(command: AndroidSpeedCommand) {
        current(command.sessionId)
        YlBoundaryValidation.speed(command.speed)
        activeLease?.desiredSpeed = command.speed
        enqueue(command.sessionId) { setPlaybackSpeed(command.speed) }
    }
    override suspend fun selectAudioTrack(command: AndroidTrackCommand) = acceptedCommand(command.sessionId,
        validate = {
            YlBoundaryValidation.identity(command.trackId)
            if (reducer.state.audioTracks.none { it.id == command.trackId }) throw YlBoundaryException(YlFailureKind.SOURCE_MISSING)
        }, apply = { selectAudioTrack(command.trackId) }, remember = { desiredTrack = command.trackId })
    override fun setVideoConstraints(command: AndroidVideoConstraintsCommand) {
        current(command.sessionId)
        YlBoundaryValidation.constraints(command.constraints)
        activeLease?.desiredConstraints = command.constraints
        enqueue(command.sessionId) { setVideoConstraints(command.constraints) }
    }
    override fun setVolume(volume: Double) {
        checkOpen()
        YlBoundaryValidation.volume(volume)
        this.volume = volume
        // This command is player-scoped: resolve the committed engine after any transfer.
        scope.launch { transaction.withLock {
            active?.let { runEngine(it.identity) { setVolume(effectiveVolume()) } }
        } }
    }
    override suspend fun stop() {
        checkOpen(); audioIntended = false; audioGeneration++; stopping = true; ++operation; pending?.cancel(); leases.cancel(playerId.toString())
        val previous = active
        val previousLease = activeLease
        val pendingBackground = backgroundRelease?.takeIf { it.lease === previousLease }
        // Stop is a presentation/session fence now, independent of native safe-release latency.
        active = null; activeLease = null
        backgroundPlayIntent = null; autoplayPending = null
        reducer.idle()
        val released = cleanup.async {
            transaction.withLock {
                pendingBackground?.let { runCatching { it.completion.await() } }
                previous?.engine?.let { engine ->
                    runCatching { engine.stop() }.exceptionOrNull()?.let { YlFailureMapper().record(it) }
                    releaseEngine(engine).await()
                }
                releaseAudio()
            }
            Unit
        }
        previousLease?.let { leases.retire(it, released) }
        released.await()
    }
    private fun releaseEngine(engine: YlPlaybackEngineAdapter): Deferred<Unit> = cleanup.async {
        try { engine.dispose().await() }
        catch (error: Throwable) { YlFailureMapper().record(error); throw error }
        finally { owned.remove(engine) }
    }
    override fun close(): Deferred<Unit> {
        closeResult?.let { return it }
        closed = true; audioIntended = false; audioGeneration++; ++operation; pending?.cancel(); scope.cancel(); leases.cancel(playerId.toString())
        val previousLease = activeLease
        val pendingBackground = backgroundRelease
        return cleanup.async {
            transaction.withLock {
                pendingBackground?.let { runCatching { it.completion.await() } }
                // Safe exceptional completion still requires *every* borrower to finish.
                val failures = owned.toList().map { engine -> async { runCatching { engine.dispose().await() }.exceptionOrNull() } }.awaitAll()
                releaseAudio()
                owned.clear(); active = null
                backgroundPlayIntent = null
                autoplayPending = null
                output.release()
                failures.filterNotNull().firstOrNull()?.let { throw it }
                Unit
            }
        }.also { result -> closeResult = result; previousLease?.let { leases.retire(it, result) } }
    }
    private suspend fun awaitBackgroundRelease(identity: YlSessionIdentity, lease: SessionLease) {
        backgroundRelease?.takeIf { it.identity == identity && it.lease === lease }?.completion?.await()
    }
    override fun onForeground() {
        if (closed || !backgrounded) return
        backgrounded = false
        val generation = ++lifecycleGeneration
        foreground.complete(Unit)
        scope.launch {
            transaction.withLock {
                if (backgrounded || generation != lifecycleGeneration) return@withLock
                val session = active ?: return@withLock
                val lease = activeLease ?: return@withLock
                var applied = false
                var intent: Pair<YlSessionIdentity, Boolean>? = null
                runEngine(session.identity) {
                    awaitBackgroundRelease(session.identity, lease)
                    if (backgrounded || generation != lifecycleGeneration || activeLease !== lease) return@runEngine
                    lease.ensureResourcesUsable()
                    intent = backgroundPlayIntent?.takeIf { it.first == session.identity }
                    if (intent?.second == false) pause()
                    if (lease.quiescing || lease.suspended != null) leases.acquire(lease) {}
                    if (backgrounded || generation != lifecycleGeneration || activeLease !== lease) return@runEngine
                    onForeground()
                    if (!backgrounded && generation == lifecycleGeneration && activeLease === lease && backgroundPlayIntent == intent) {
                        if (intent?.second == true) playWithAudio(this)
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
        ++lifecycleGeneration
        foreground = CompletableDeferred()
        // A bounce must not erase an explicit command whose foreground application is queued or
        // still suspended. Autoplay is only a fallback when no current-session intent is pending.
        backgroundPlayIntent = backgroundPlayIntent?.takeIf { it.first == active?.identity }
            ?: autoplayPending?.takeIf { it == active?.identity }?.let { it to true }
        ++operation
        // A committed state already owns its reply. Only an uncommitted candidate is cancelled.
        if (!pendingCommitted) pending?.cancel()
        if (!inCommit) leases.cancel(playerId.toString())
        val session = active ?: return
        val lease = activeLease?.takeIf { it.session.identity == session.identity } ?: return
        // A foreground waiting for this release cannot have resumed playback yet, so another
        // background entry shares the same owned release rather than racing a second producer.
        backgroundRelease?.takeIf { it.identity == session.identity && it.lease === lease && !it.completion.isCompleted }
            ?.let { return }
        val quiescence = lease.beginQuiesce()
        // Cleanup ownership survives Load/Stop/close cancellation. It does not wait behind a
        // candidate's disposal or the local command mutex; only resource-acquiring work awaits it.
        val completion = cleanup.async(start = CoroutineStart.LAZY) {
            quiescence.await()
            session.engine.onBackground()
            releaseAudio()
            leases.relinquish(lease)
            if (!closed && backgrounded && active?.identity == session.identity && activeLease === lease) reducer.pauseForLifecycle()
        }
        val pending = BackgroundRelease(session.identity, lease, completion)
        backgroundRelease = pending
        completion.invokeOnCompletion { if (backgroundRelease === pending) backgroundRelease = null }
        completion.start()
    }
    override fun onTrimMemory(level: Int) {
        if (level >= android.content.ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN) onBackground()
        notifyEngines { onTrimMemory(level) }
    }
    override fun onConfigurationChanged() = notifyEngines { onConfigurationChanged() }
    private fun notifyEngines(action: suspend YlPlaybackEngineAdapter.() -> Unit) {
        if (closed) return
        listOfNotNull(active?.engine, candidateEngine).distinct().forEach { engine ->
            scope.launch { runCatching { engine.action() }.exceptionOrNull()?.let { YlFailureMapper().record(it) } }
        }
    }
}
