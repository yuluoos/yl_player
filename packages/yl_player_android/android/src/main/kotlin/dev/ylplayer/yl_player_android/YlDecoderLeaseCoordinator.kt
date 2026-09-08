package dev.ylplayer.yl_player_android

import android.os.SystemClock
import dev.ylplayer.yl_player_android.pigeon.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal data class YlLeaseAttempt(val generation: Long, val deadlineMs: Long)
internal fun interface YlCancelHandle { fun cancel() }
/** Retains only immutable restoration inputs; mutable caller header maps are defensively copied. */
internal class YlLeaseSnapshot(
    val identity: YlSessionIdentity,
    source: AndroidSourceMessage,
    val options: AndroidLoadOptionsMessage,
    runtime: YlEngineRestorePoint,
    val output: YlOutputIdentity,
) {
    val source = source.copy(request = source.request?.let {
        it.copy(headers = java.util.Collections.unmodifiableMap(HashMap(it.headers)),
            credentials = java.util.Collections.unmodifiableMap(HashMap(it.credentials)))
    })
    val runtime = runtime.copy(selectedVideoTracks = java.util.Collections.unmodifiableList(ArrayList(runtime.selectedVideoTracks)))
}
internal interface YlDecoderLeaseParticipant {
    val leaseId: String
    val playerLeaseId: String
    val needsExclusiveLease: Boolean
    val canRestore: Boolean
    val leaseCommitVersion: Long get() = 0
    val activationTimeoutFailure: YlFailureKind get() = YlFailureKind.RESOURCE_EXHAUSTED
    fun publicationFailed(error: Throwable) {}
    fun quiesceForLease(attempt: YlLeaseAttempt, complete: (Result<YlLeaseSnapshot>) -> Unit): YlCancelHandle
    fun activateForLease(attempt: YlLeaseAttempt, complete: (Result<Unit>) -> Unit): YlCancelHandle
    fun commitLease()
    fun rollbackLease(snapshot: YlLeaseSnapshot, attempt: YlLeaseAttempt, complete: (Result<Unit>) -> Unit): YlCancelHandle
    fun deactivateAfterLeaseTransfer()
    fun disposeForLease(): Deferred<Unit>
    fun restorationFailed()
}

/** Single registry resource authority. Scarce transfers retain the global mutex through safe
 * release/rollback. Proven nonexclusive Players progress under independent per-player mutexes;
 * stage generations and cancellation ownership belong to their own transaction.
 */
internal class YlDecoderLeaseCoordinator(
    dispatcher: CoroutineDispatcher = Dispatchers.Main,
    private val clockMs: () -> Long = SystemClock::elapsedRealtime,
) {
    private val cleanup = CoroutineScope(SupervisorJob() + dispatcher)
    private val gate = Mutex()
    private class AttemptState(var generation: Long = 0)
    private val playerGates = mutableMapOf<String, Mutex>()
    private val jobs = mutableMapOf<Deferred<Unit>, YlDecoderLeaseParticipant>()
    private val latestByPlayer = mutableMapOf<String, Deferred<Unit>>()
    private var requestGeneration = 0L
    private var current: Deferred<Unit>? = null
    private var currentParticipant: YlDecoderLeaseParticipant? = null
    private var attached = true
    private val retiring = mutableMapOf<YlDecoderLeaseParticipant, Deferred<Unit>>()
    private val inFlightParticipants = mutableSetOf<YlDecoderLeaseParticipant>()
    var owner: YlDecoderLeaseParticipant? = null
        private set

    suspend fun acquire(
        candidate: YlDecoderLeaseParticipant,
        former: YlDecoderLeaseParticipant? = null,
        prepare: suspend () -> Unit,
    ) {
        check(attached)
        // A known nonexclusive restore has no scarce dependency. Replacing a same-player
        // video engine still participates in the shared resource transaction.
        val exclusive = candidate.needsExclusiveLease || former?.needsExclusiveLease == true
        val playerGate = playerGates.getOrPut(candidate.playerLeaseId) { Mutex() }
        latestByPlayer[candidate.playerLeaseId]?.cancel()
        val request = if (exclusive) ++requestGeneration else requestGeneration
        if (exclusive) current?.cancel()
        val job = cleanup.async(start = CoroutineStart.LAZY) {
            val attempts = AttemptState()
            suspend fun transfer() {
                currentCoroutineContext().ensureActive()
                if (!attached || (exclusive && request != requestGeneration)) throw CancellationException()
                val retirementDependencies = (if (exclusive) listOfNotNull(owner, former) else listOfNotNull(former)) +
                    retiring.keys.filter { it.playerLeaseId == candidate.playerLeaseId }
                for (prior in retirementDependencies.distinct()) retiring[prior]?.let { release ->
                    // An accepted Stop/close fences presentation immediately, but is not proof
                    // its decoder is free. Exceptional safe-close completion is an acknowledgement.
                    withContext(NonCancellable) { runCatching { release.await() } }
                    relinquish(prior)
                    currentCoroutineContext().ensureActive()
                }
                val originalOwner = owner
                val previous = (if (exclusive) listOfNotNull(owner, former) else listOfNotNull(former))
                    .distinct().filter { it !== candidate }
                inFlightParticipants.addAll(previous + candidate)
                val snapshots = linkedMapOf<YlDecoderLeaseParticipant, YlLeaseSnapshot>()
                val restored = mutableSetOf<YlDecoderLeaseParticipant>()
                var committed = false
                val commitVersion = candidate.leaseCommitVersion
                try {
                    prepare()
                    currentCoroutineContext().ensureActive()
                    for (prior in previous) {
                        // Acknowledgement must survive cancellation: it contains the real worker
                        // restore point, and establishes when another transfer is safe to start.
                        stage<YlLeaseSnapshot>(attempts, 5_000, retainAcknowledgement = true) { attempt, complete ->
                            prior.quiesceForLease(attempt) { result ->
                                result.getOrNull()?.let { snapshots[prior] = it }
                                complete(result)
                            }
                        }
                        currentCoroutineContext().ensureActive()
                    }
                    try { stage(attempts, 15_000, operation = candidate::activateForLease) }
                    catch (_: TimeoutCancellationException) { throw YlBoundaryException(candidate.activationTimeoutFailure) }
                    currentCoroutineContext().ensureActive()
                    if (!attached || (exclusive && request != requestGeneration)) throw CancellationException()
                    // READY can prove an unknown stream audio-only. Restore each peer before the
                    // candidate commits; its own former session is retired only after commit.
                    if (!candidate.needsExclusiveLease) {
                        for ((prior, snapshot) in snapshots) if (prior.playerLeaseId != candidate.playerLeaseId) {
                            restored += prior // An unsuccessful restore must not be attempted twice.
                            restore(prior, snapshot, attempts)
                        }
                    }
                    candidate.commitLease()
                    committed = true
                    if (exclusive) owner = if (candidate.needsExclusiveLease) candidate else originalOwner?.takeIf {
                        it !in snapshots || it in restored
                    }
                    snapshots.keys.filterNot { it in restored }.forEach { it.deactivateAfterLeaseTransfer() }
                } catch (error: Throwable) {
                    if (candidate.leaseCommitVersion != commitVersion) {
                        // Publication is irrevocable. Fail/close a defective event boundary;
                        // an observed candidate session cannot be rolled back to its predecessor.
                        committed = true
                        runCatching { candidate.publicationFailed(error) }.exceptionOrNull()?.let { YlFailureMapper().record(it) }
                        snapshots.keys.filterNot { it in restored }.forEach { it.deactivateAfterLeaseTransfer() }
                        withContext(NonCancellable) { runCatching { candidate.disposeForLease().await() } }
                        if (exclusive && owner === originalOwner) owner = originalOwner?.takeIf { it in restored }
                    }
                    if (!committed) withContext(NonCancellable) {
                        runCatching { candidate.disposeForLease().await() }.exceptionOrNull()?.let { YlFailureMapper().record(it) }
                        var restorationError: Throwable? = null
                        if (attached) for ((prior, snapshot) in snapshots.toList().asReversed()) if (prior !in restored) {
                            try { restore(prior, snapshot, attempts) } catch (failure: Throwable) { restorationError = failure }
                        }
                        restorationError?.let { throw it }
                    }
                    if (error is TimeoutCancellationException) throw YlBoundaryException(YlFailureKind.RESOURCE_EXHAUSTED)
                    throw error
                } finally {
                    ++attempts.generation
                    inFlightParticipants.removeAll(previous + candidate)
                }
            }
            playerGate.withLock {
                if (exclusive) gate.withLock { transfer() } else transfer()
            }
        }
        jobs[job] = candidate
        latestByPlayer[candidate.playerLeaseId] = job
        if (exclusive) { currentParticipant = candidate; current = job }
        job.start()
        try { job.await() }
        finally {
            if (!job.isCompleted) { job.cancel(); withContext(NonCancellable) { job.join() } }
            jobs.remove(job)
            if (latestByPlayer[candidate.playerLeaseId] === job) latestByPlayer.remove(candidate.playerLeaseId)
            if (jobs.values.none { it.playerLeaseId == candidate.playerLeaseId }) playerGates.remove(candidate.playerLeaseId)
            if (current === job) { current = null; currentParticipant = null }
        }
    }

    private suspend fun restore(previous: YlDecoderLeaseParticipant, snapshot: YlLeaseSnapshot, attempts: AttemptState) {
        if (!attached || !previous.canRestore) return
        try { stage<Unit>(attempts, 15_000) { attempt, complete -> previous.rollbackLease(snapshot, attempt, complete) } }
        catch (error: Throwable) {
            YlFailureMapper().record(error)
            if (attached) previous.restorationFailed()
            if (owner === previous) owner = null
            // A timed-out restore may still be using a codec/output. Quarantine transfer until
            // independent dispose acknowledges it; never infer release from a deadline.
            withContext(NonCancellable) { runCatching { previous.disposeForLease().await() }.exceptionOrNull()?.let { YlFailureMapper().record(it) } }
            throw YlBoundaryException(YlFailureKind.RESOURCE_EXHAUSTED)
        }
    }

    private suspend fun <T> stage(
        attempts: AttemptState,
        timeoutMs: Long,
        retainAcknowledgement: Boolean = false,
        operation: (YlLeaseAttempt, (Result<T>) -> Unit) -> YlCancelHandle,
    ): T {
        val attempt = YlLeaseAttempt(++attempts.generation, clockMs() + timeoutMs)
        val result = CompletableDeferred<T>()
        val handle = operation(attempt) { value ->
            // Only the immutable result enters here. Ownership changes occur after await and
            // caller generation checks, never inside a potentially late callback.
            value.fold(result::complete, result::completeExceptionally)
        }
        try {
            return withTimeout(timeoutMs) {
                val value = result.await()
                if (!attached || attempt.generation != attempts.generation || clockMs() >= attempt.deadlineMs) {
                    throw YlBoundaryException(YlFailureKind.RESOURCE_EXHAUSTED)
                }
                value
            }
        } catch (error: Throwable) {
            handle.cancel()
            if (retainAcknowledgement) {
                // Preserve the released engine's snapshot even when cancellation won the race.
                // The caller checks cancellation immediately after assigning this result.
                withContext(NonCancellable) { runCatching { result.await() } }
            }
            throw error
        }
    }

    fun retire(participant: YlDecoderLeaseParticipant, safeRelease: Deferred<Unit>) {
        retiring[participant] = safeRelease
        cleanup.launch {
            runCatching { safeRelease.await() }
            relinquish(participant)
            retiring.remove(participant)
        }
    }
    fun cancel(playerId: String) {
        jobs.filterValues { it.playerLeaseId == playerId }.keys.toList().forEach { it.cancel() }
        if (currentParticipant?.playerLeaseId == playerId || owner?.playerLeaseId == playerId) current?.cancel()
    }
    fun relinquish(participant: YlDecoderLeaseParticipant) {
        if (owner === participant) owner = null
    }
    fun detach() {
        if (!attached) return
        attached = false; ++requestGeneration
        jobs.keys.toList().forEach { it.cancel() }
        val participants = (listOfNotNull(owner, currentParticipant) + jobs.values + inFlightParticipants + retiring.keys).distinct()
        owner = null
        participants.forEach { participant -> cleanup.launch { runCatching { participant.disposeForLease().await() } } }
    }
}
