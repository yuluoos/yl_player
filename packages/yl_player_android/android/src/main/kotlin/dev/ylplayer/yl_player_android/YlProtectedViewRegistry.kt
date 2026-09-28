package dev.ylplayer.yl_player_android

import android.os.Looper
import android.view.Surface
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Main-owned registry; only the port crosses to Media3's worker. Holder Surfaces
 * are borrowed and NEVER released here. A view is presentation, not session ownership. */
internal interface YlProtectedOutputPort {
    suspend fun attach(surface: Surface, identity: YlOutputIdentity, isCurrent: () -> Boolean)
    suspend fun park()
    /** Synchronous worker acknowledgement; must not depend on dispatching back to main. */
    fun detachBeforeDestroy()
}
internal class YlProtectedViewRegistry(
    private val dispatcher: CoroutineDispatcher = Dispatchers.Main,
    private val checkMain: () -> Unit = { check(Looper.myLooper() == Looper.getMainLooper()) },
) {
    private val records = mutableMapOf<YlDrmSessionIdentity, Binding>()
    private val generations = mutableMapOf<Long, Long>()
    private var next = 0L
    fun nextIdentity(playerId: Long, sessionId: String): YlDrmSessionIdentity {
        checkMain(); val generation = ++next
        return YlDrmSessionIdentity(playerId, generation, sessionId, generation)
    }
    fun register(identity: YlDrmSessionIdentity, port: YlProtectedOutputPort, failure: (YlFailureKind) -> Unit): Binding {
        checkMain()
        if (identity.playerId < 0 || identity.surfaceId < 0 || identity.generation < 0 || identity.sessionId.isEmpty() ||
            identity.generation <= (generations[identity.playerId] ?: -1)) throw YlBoundaryException(YlFailureKind.SESSION_STALE)
        generations[identity.playerId] = identity.generation
        return Binding(identity, port, failure).also { records[identity] = it }
    }
    fun claim(identity: YlDrmSessionIdentity, viewId: Int): Claim? {
        checkMain()
        val record = records[identity] ?: return null
        if (!record.committed || record.retired || record.claim != null || viewId < 0) return null
        return Claim(record, viewId).also { record.claim = it }
    }
    fun detach() { checkMain(); records.values.toList().forEach { it.retire() } }

    inner class Binding internal constructor(val identity: YlDrmSessionIdentity,
        private val port: YlProtectedOutputPort, private val failure: (YlFailureKind) -> Unit) {
        internal var claim: Claim? = null
        internal var committed = false
        internal var retired = false
        private val scope = CoroutineScope(SupervisorJob() + dispatcher)
        private val serial = Mutex()
        @Volatile private var revision = 0L
        private var acknowledged: YlOutputIdentity? = null
        private var pendingFrame: Pair<YlOutputIdentity, () -> Unit>? = null
        internal var enabled = true
        internal var geometry: dev.ylplayer.yl_player_android.pigeon.AndroidVideoGeometryMessage? = null
        fun updateGeometry(value: dev.ylplayer.yl_player_android.pigeon.AndroidVideoGeometryMessage?) {
            checkMain(); if (!retired) { geometry = value; claim?.onGeometry?.invoke() }
        }
        val outputIdentity get() = YlOutputIdentity(revision, true)
        fun commit() {
            checkMain(); if (retired || committed) return
            records.values.filter { it !== this && it.identity.playerId == identity.playerId && it.committed }
                .toList().forEach { it.retire() }
            committed = true
        }
        internal fun change(surface: Surface?) {
            checkMain(); val ticket = ++revision; acknowledged = null; pendingFrame = null
            claim?.onHidden?.invoke()
            scope.launch { serial.withLock {
                if (surface != null && (retired || ticket != revision)) return@withLock
                try {
                    if (surface == null) port.park() else {
                        val output = YlOutputIdentity(ticket, true)
                        port.attach(surface, output) { ticket == revision }
                        if (!retired && ticket == revision) {
                            acknowledged = output
                            pendingFrame?.takeIf { it.first == output }?.let { frame(it.first, it.second) }
                        }
                    }
                } catch (error: Exception) {
                    if (!retired && ticket == revision) {
                        acknowledged = null
                        failure((error as? YlBoundaryException)?.kind ?: YlFailureKind.DRM_PROTECTION_INSUFFICIENT)
                    }
                }
            } }
        }
        internal fun detachBorrowedSurface() {
            checkMain(); ++revision; acknowledged = null; pendingFrame = null
            claim?.onHidden?.invoke()
            // Do not acquire serial: an attach may be awaiting its main-thread continuation.
            // The worker checks the volatile revision before attaching, and this worker barrier
            // follows any attach that already passed the check.
            try { port.detachBeforeDestroy() }
            catch (error: Exception) {
                enabled = false
                failure((error as? YlBoundaryException)?.kind ?: YlFailureKind.DRM_PROTECTION_INSUFFICIENT)
            }
        }
        fun frame(output: YlOutputIdentity, accepted: () -> Unit = {}) {
            checkMain()
            if (retired || !committed || !enabled || output != outputIdentity) return
            if (output != acknowledged) { pendingFrame = output to accepted; return }
            pendingFrame = null
            claim?.onFrame?.invoke(output)
            accepted()
        }
        fun suspendPresentation() { checkMain(); enabled = false; change(null) }
        fun resumePresentation() { checkMain(); if (!retired) { enabled = true; claim?.rebind() } }
        fun retire() {
            checkMain(); if (retired) return
            claim?.destroyed()
            retired = true; committed = false; records.remove(identity)
            ++revision; acknowledged = null; pendingFrame = null
            claim?.invalidate(); claim = null
            scope.cancel()
        }
    }
    inner class Claim internal constructor(private val record: Binding, val viewId: Int) {
        var onFrame: ((YlOutputIdentity) -> Unit)? = null
        var onHidden: (() -> Unit)? = null
        var onGeometry: (() -> Unit)? = null
        val geometry get() = record.geometry
        private var surface: Surface? = null
        private var disposed = false
        private var hasSurface = false
        fun available(surface: Surface) {
            checkMain(); if (disposed || record.retired || record.claim !== this) return
            hasSurface = true; this.surface = surface
            if (record.enabled) record.change(surface)
        }
        fun destroyed() {
            checkMain(); if (disposed || !hasSurface) return
            hasSurface = false; surface = null; record.detachBorrowedSurface()
        }
        internal fun rebind() { surface?.let(::available) }
        internal fun invalidate() { onHidden?.invoke(); disposed = true; onFrame = null; onHidden = null; onGeometry = null; hasSurface = false; surface = null }
        fun dispose() {
            checkMain(); if (disposed) return
            destroyed(); invalidate()
            if (record.claim === this) record.claim = null
        }
    }
}
