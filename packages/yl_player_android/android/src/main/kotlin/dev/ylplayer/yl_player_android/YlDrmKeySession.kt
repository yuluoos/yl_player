package dev.ylplayer.yl_player_android

import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Owner identity is never inferred from a mutable "current session" pointer. */
internal data class YlDrmSessionIdentity(val playerId: Long, val surfaceId: Long,
    val sessionId: String, val generation: Long)
internal enum class YlDrmKeyPhase { IDLE, REQUESTING, AWAITING_KEYS, USABLE, SUSPENDED, FAILED, DISPOSED }
internal enum class YlDrmSystemEvent { KEY_REQUIRED, USABLE, PENDING, EXPIRED, OUTPUT_RESTRICTED, PROVISION_REQUIRED, FAILED }
internal interface YlDrmSystemDriver {
    fun open(callback: (YlDrmSystemEvent) -> Unit)
    fun challenge(initData: ByteArray?, mime: String): ByteArray
    fun install(response: ByteArray)
    fun close()
}
internal class YlDrmKeyRequest(val identity: YlDrmSessionIdentity, val epoch: Long,
    val requestId: Long, bytes: ByteArray) {
    // Several Media3 track/Period sessions can share the same output identity.
    val exchangeId: String = java.util.UUID.randomUUID().toString()
    private val value = bytes.copyOf()
    val bytes get() = value.copyOf()
    fun clear() { value.fill(0) }
    override fun toString() = "YlDrmKeyRequest(<redacted>)"
}

/** One internal candidate's key lifecycle. Not a playback/output capability.
 * All state and driver calls are confined to dispatcher; exchange must suspend
 * without blocking it and implement the separate bounded license POST policy.
 */
internal class YlDrmKeySession(
    private val identity: YlDrmSessionIdentity,
    initData: ByteArray,
    private val mime: String,
    private val dispatcher: CoroutineDispatcher,
    private val timeoutMs: Long,
    private val makeDriver: () -> YlDrmSystemDriver,
    private val exchange: suspend (YlDrmKeyRequest) -> ByteArray,
    private val onFailure: (YlFailureKind) -> Unit,
    private val onPhaseChanged: (YlDrmKeyPhase) -> Unit = {},
) {
    // Also serializes immediate/reentrant driver callbacks on the same dispatcher.
    private val mutex = Mutex()
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val initData = initData.copyOf()
    private var epoch = 0L
    private var serial = 0L
    private var driver: YlDrmSystemDriver? = null
    private var pending: Job? = null
    private var deadline: Job? = null
    private var ready = CompletableDeferred<Unit>()
    private var request: YlDrmKeyRequest? = null
    private var renewQueued = false
    var phase = YlDrmKeyPhase.IDLE
        private set(value) {
            field = value
            onPhaseChanged(value)
        }
    init {
        if (initData.isEmpty() || initData.size > 1024 * 1024 ||
            mime !in setOf("video/mp4", "audio/mp4") || timeoutMs !in 1..60_000 ||
            identity.playerId < 0 || identity.surfaceId < 0 || identity.generation < 0 || identity.sessionId.isEmpty()) {
            throw YlBoundaryException(YlFailureKind.DRM_CONFIG_INVALID)
        }
    }

    suspend fun start(): Deferred<Unit> = withContext(dispatcher) { mutex.withLock {
        if (phase !in setOf(YlDrmKeyPhase.IDLE, YlDrmKeyPhase.SUSPENDED)) {
            throw YlBoundaryException(YlFailureKind.SESSION_STALE)
        }
        epoch++
        val current = epoch
        ready = CompletableDeferred()
        phase = YlDrmKeyPhase.REQUESTING
        try {
            val system = makeDriver().also { driver = it }
            system.open { event -> scope.launch { mutex.withLock { if (current == epoch) receive(event) } } }
            issue(initial = true)
        } catch (error: Exception) {
            fail(kind(error))
        }
        ready
    } }

    private fun issue(initial: Boolean) {
        val system = driver ?: return
        phase = YlDrmKeyPhase.REQUESTING
        val current = epoch
        val id = ++serial
        val raw = system.challenge(if (initial) initData.copyOf() else null, mime)
        try {
            if (raw.isEmpty()) throw YlBoundaryException(YlFailureKind.DRM_LICENSE_RESPONSE_INVALID)
            if (raw.size > 1024 * 1024) throw YlBoundaryException(YlFailureKind.DRM_PAYLOAD_TOO_LARGE)
            request = YlDrmKeyRequest(identity, current, id, raw)
        } finally { raw.fill(0) }
        val challenge = checkNotNull(request)
        deadline?.cancel()
        deadline = scope.launch {
            delay(timeoutMs)
            mutex.withLock { if (current == epoch && id == serial) fail(YlFailureKind.DRM_LICENSE_TIMEOUT) }
        }
        pending = scope.launch {
            try {
                val response = exchange(challenge)
                mutex.withLock {
                    // A transport that ignores cancellation cannot install into any new session.
                    if (current != epoch || id != serial || driver !== system) return@withLock
                    if (response.isEmpty()) throw YlBoundaryException(YlFailureKind.DRM_LICENSE_RESPONSE_INVALID)
                    if (response.size > 4 * 1024 * 1024) throw YlBoundaryException(YlFailureKind.DRM_PAYLOAD_TOO_LARGE)
                    val owned = response.copyOf()
                    try { system.install(owned) } finally { owned.fill(0) }
                    // System callbacks wait on the mutex until installation and this state
                    // transition finish. A thrown install can never publish USABLE first.
                    if (current != epoch || id != serial || driver !== system) return@withLock
                    phase = YlDrmKeyPhase.AWAITING_KEYS
                    if (renewQueued) {
                        renewQueued = false
                        try { issue(initial = false) } catch (error: Exception) { fail(kind(error)) }
                    }
                }
            } catch (error: Exception) {
                withContext(NonCancellable) { mutex.withLock {
                    if (current == epoch && id == serial) {
                        fail(if (error is CancellationException) YlFailureKind.LOAD_CANCELLED else kind(error))
                    }
                } }
            } finally {
                withContext(NonCancellable) { mutex.withLock {
                    challenge.clear()
                    if (request === challenge) request = null
                } }
            }
        }
    }

    private fun receive(event: YlDrmSystemEvent) {
        if (driver == null) return
        when (event) {
            YlDrmSystemEvent.KEY_REQUIRED -> {
                if (phase != YlDrmKeyPhase.REQUESTING) {
                    try { issue(initial = false) } catch (error: Exception) { fail(kind(error)) }
                } else renewQueued = true
            }
            YlDrmSystemEvent.USABLE -> if (phase == YlDrmKeyPhase.AWAITING_KEYS) {
                deadline?.cancel(); deadline = null
                phase = YlDrmKeyPhase.USABLE
                if (renewQueued) {
                    renewQueued = false
                    try { issue(initial = false) } catch (error: Exception) { fail(kind(error)) }
                } else ready.complete(Unit)
            }
            YlDrmSystemEvent.EXPIRED -> fail(YlFailureKind.DRM_LICENSE_EXPIRED)
            YlDrmSystemEvent.OUTPUT_RESTRICTED -> fail(YlFailureKind.DRM_PROTECTION_INSUFFICIENT)
            YlDrmSystemEvent.PROVISION_REQUIRED -> fail(YlFailureKind.DRM_PROVISIONING_REQUIRED)
            YlDrmSystemEvent.FAILED -> fail(YlFailureKind.DRM_SESSION_FAILED)
            YlDrmSystemEvent.PENDING -> if (phase == YlDrmKeyPhase.USABLE) {
                phase = YlDrmKeyPhase.AWAITING_KEYS
                val current = epoch
                val id = ++serial
                deadline = scope.launch {
                    delay(timeoutMs)
                    mutex.withLock { if (current == epoch && id == serial) fail(YlFailureKind.DRM_LICENSE_TIMEOUT) }
                }
            }
        }
    }

    private fun kind(error: Exception): YlFailureKind =
        (error as? YlBoundaryException)?.kind ?: YlFailureKind.DRM_SESSION_FAILED

    private fun invalidate(next: YlDrmKeyPhase) {
        epoch++ // Revoke callbacks before cancellation or external cleanup can reenter.
        phase = next
        deadline?.cancel(); deadline = null
        pending?.cancel(); pending = null
        request?.clear(); request = null
        renewQueued = false
        val old = driver; driver = null
        try { old?.close() } catch (_: Exception) { /* terminal cleanup still completes */ }
    }
    private fun fail(failure: YlFailureKind) {
        invalidate(YlDrmKeyPhase.FAILED)
        ready.completeExceptionally(YlBoundaryException(failure))
        try { onFailure(failure) } catch (_: Exception) { /* callbacks cannot prevent cleanup */ }
    }
    suspend fun suspendSession() = withContext(dispatcher) { mutex.withLock {
        if (phase !in setOf(YlDrmKeyPhase.DISPOSED, YlDrmKeyPhase.FAILED, YlDrmKeyPhase.SUSPENDED)) {
            invalidate(YlDrmKeyPhase.SUSPENDED)
            ready.cancel()
        }
    } }
    private fun disposeLocked() {
        if (phase != YlDrmKeyPhase.DISPOSED) {
            invalidate(YlDrmKeyPhase.DISPOSED)
            ready.cancel(); initData.fill(0); scope.cancel()
        }
    }
    suspend fun dispose() = withContext(dispatcher) { mutex.withLock { disposeLocked() } }
    /** Called only by the Media3 owner at its last decoder reference. No driver call or
     * suspension holds this mutex across an owner turn; teardown cannot be posted to
     * a playback Looper which Media3 is about to quit. */
    internal fun disposeOnOwner() {
        check(mutex.tryLock()) { "Reentrant DRM disposal" }
        try { disposeLocked() } finally { mutex.unlock() }
    }
}
