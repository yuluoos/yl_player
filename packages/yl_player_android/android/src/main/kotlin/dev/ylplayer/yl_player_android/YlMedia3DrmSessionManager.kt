package dev.ylplayer.yl_player_android

import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.drm.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.android.asCoroutineDispatcher
import java.util.IdentityHashMap
import java.util.UUID

internal val YL_WIDEVINE_UUID: UUID = UUID.fromString("edef8ba9-79d6-4ace-a3c8-27dcd51d21ed")

/** Only a CDM session handle crosses into Media3; content keys never do. */
@OptIn(UnstableApi::class)
internal interface YlDrmCryptoDriver : YlDrmSystemDriver {
    fun cryptoConfig(): FrameworkCryptoConfig
}
internal class YlMedia3DrmOwner(val dispatcher: CoroutineDispatcher,
    val checkThread: () -> Unit, val makeDriver: () -> YlDrmCryptoDriver)

/** One candidate's Media3 adapter. Caller supplies the separate license transport.
 * The public player does not instantiate this until protected output and bridge
 * admission are available. No default license URL, HttpMediaDrmCallback or clear
 * fallback exists here. Media3 owns each returned session reference.
 */
@OptIn(UnstableApi::class)
internal class YlMedia3DrmSessionManager(
    private val identity: YlDrmSessionIdentity,
    private val cbcs: Boolean,
    private val timeoutMs: Long,
    private val exchange: suspend (YlDrmKeyRequest) -> ByteArray,
    private val ownerFactory: (Looper) -> YlMedia3DrmOwner = { looper ->
        val handler = Handler(looper)
        YlMedia3DrmOwner(handler.asCoroutineDispatcher(),
            { check(Looper.myLooper() === looper) },
            { YlWidevineDriver(Build.VERSION.SDK_INT, cbcs, handler) })
    },
) : DrmSessionManager {
    private var looper: Looper? = null
    private var owner: YlMedia3DrmOwner? = null
    private var prepares = 0
    private var cycle = 0L
    private val sessions = mutableListOf<Session>()
    private val readiness = MutableStateFlow(false to (null as YlFailureKind?))
    suspend fun awaitUsableKeys() {
        val state = try { withTimeout(timeoutMs) { readiness.first { it.first || it.second != null } } }
        catch (_: TimeoutCancellationException) { throw YlBoundaryException(YlFailureKind.DRM_LICENSE_TIMEOUT) }
        state.second?.let { throw YlBoundaryException(it) }
    }
    private fun publishReadiness() {
        val active = sessions.filter { it.state != DrmSession.STATE_RELEASED }
        val error = active.firstNotNullOfOrNull { (it.error?.cause as? YlBoundaryException)?.kind }
        readiness.value = (active.isNotEmpty() && active.all { it.state == DrmSession.STATE_OPENED_WITH_KEYS }) to error
    }
    init { if (timeoutMs !in 1..60_000) throw YlBoundaryException(YlFailureKind.DRM_CONFIG_INVALID) }

    override fun setPlayer(playbackLooper: Looper, playerId: PlayerId) {
        // A manager is candidate-owned; moving live sessions to another Looper is forbidden.
        if (looper != null && looper !== playbackLooper) throw YlBoundaryException(YlFailureKind.SESSION_STALE)
        if (owner == null) { looper = playbackLooper; owner = ownerFactory(playbackLooper) }
    }
    override fun prepare() { owned().checkThread(); if (prepares++ == 0) cycle++ }
    override fun release() {
        owned().checkThread()
        if (prepares > 0) prepares--
        // This releases manager ownership, not decoder references. Sessions have
        // no keepalive reference and close only after their last consumer releases.
    }
    override fun getCryptoType(format: Format): Int {
        if (format.drmInitData == null) return C.CRYPTO_TYPE_NONE
        return try { initialization(format, allowMissingData = true).clear(); C.CRYPTO_TYPE_FRAMEWORK }
        catch (_: YlBoundaryException) { C.CRYPTO_TYPE_UNSUPPORTED }
    }
    override fun acquireSession(eventDispatcher: DrmSessionEventListener.EventDispatcher?, format: Format): DrmSession? {
        owned().checkThread()
        if (format.drmInitData == null) return null
        if (prepares == 0) return rejected(YlFailureKind.SESSION_STALE, eventDispatcher)
        val init = try { initialization(format) }
        catch (error: YlBoundaryException) { return rejected(error.kind, eventDispatcher) }
        val existing = sessions.firstOrNull { it.cycle == cycle && it.reusable && it.init.same(init) }
        if (existing != null) { init.clear(); existing.acquire(eventDispatcher); return existing }
        // Include sessions awaiting cleanup, failed sessions and prior prepare cycles.
        if (sessions.size >= 4) { init.clear(); return rejected(YlFailureKind.RESOURCE_EXHAUSTED, eventDispatcher) }
        val session = Session(cycle, init)
        sessions += session
        publishReadiness()
        session.acquire(eventDispatcher)
        return session
    }
    private fun owned() = owner ?: throw YlBoundaryException(YlFailureKind.DRM_SESSION_FAILED)
    private fun rejected(kind: YlFailureKind, events: DrmSessionEventListener.EventDispatcher?): DrmSession {
        val error = sessionError(kind)
        events?.drmSessionManagerError(error)
        return ErrorStateDrmSession(error)
    }
    private fun initialization(format: Format, allowMissingData: Boolean = false): Initialization {
        val data = format.drmInitData ?: throw YlBoundaryException(YlFailureKind.DRM_CONFIG_INVALID)
        val mode = data.schemeType ?: "cenc"
        if (mode != if (cbcs) "cbcs" else "cenc") throw YlBoundaryException(YlFailureKind.DRM_ENCRYPTION_MODE_UNSUPPORTED)
        var selected: androidx.media3.common.DrmInitData.SchemeData? = null
        for (index in 0 until data.schemeDataCount) {
            val item = data[index]
            if (item.uuid != YL_WIDEVINE_UUID) continue
            // DASH probes the manifest before it loads the initialization segment.
            // Missing PSSH is a capability unknown, never an acquisition allowance.
            val bytes = item.data
            if (bytes == null && !allowMissingData) continue
            if (bytes != null && bytes.isEmpty()) throw YlBoundaryException(YlFailureKind.DRM_CONFIG_INVALID)
            if (bytes != null && bytes.size > 1024 * 1024) throw YlBoundaryException(YlFailureKind.DRM_PAYLOAD_TOO_LARGE)
            if (item.mimeType !in setOf("video/mp4", "audio/mp4")) throw YlBoundaryException(YlFailureKind.DRM_UNSUPPORTED)
            if (selected?.data != null && bytes != null && (selected.mimeType != item.mimeType || !selected.data.contentEquals(bytes))) {
                // Never guess between multiple distinct initialization payloads.
                throw YlBoundaryException(YlFailureKind.DRM_UNSUPPORTED)
            }
            if (selected == null || bytes != null) selected = item
        }
        val item = selected ?: throw YlBoundaryException(YlFailureKind.DRM_UNSUPPORTED)
        return Initialization(item.mimeType, item.data?.copyOf() ?: byteArrayOf())
    }
    private class Initialization(val mime: String, val bytes: ByteArray) {
        fun same(other: Initialization) = mime == other.mime && bytes.contentEquals(other.bytes)
        fun clear() = bytes.fill(0)
    }

    private inner class Session(val cycle: Long, val init: Initialization) : DrmSession {
        private val owner = owned()
        private val scope = CoroutineScope(SupervisorJob() + owner.dispatcher)
        private val consumers = IdentityHashMap<DrmSessionEventListener.EventDispatcher?, Int>()
        private var references = 0
        private var state = DrmSession.STATE_OPENING
        private var error: DrmSession.DrmSessionException? = null
        private var crypto: FrameworkCryptoConfig? = null
        private var driver: YlDrmCryptoDriver? = null
        private var keys: YlDrmKeySession? = null
        private var started = false
        private var released = false
        val reusable get() = !released && state != DrmSession.STATE_ERROR

        override fun acquire(eventDispatcher: DrmSessionEventListener.EventDispatcher?) {
            owner.checkThread()
            if (released) throw YlBoundaryException(YlFailureKind.SESSION_STALE)
            references++
            val prior = consumers[eventDispatcher] ?: 0
            consumers[eventDispatcher] = prior + 1
            if (prior == 0 && eventDispatcher != null) {
                if (state == DrmSession.STATE_ERROR) eventDispatcher.drmSessionManagerError(checkNotNull(error))
                else if (crypto != null) {
                    eventDispatcher.drmSessionAcquired(state)
                    if (state == DrmSession.STATE_OPENED_WITH_KEYS) eventDispatcher.drmKeysLoaded(KeyRequestInfo.Builder().build())
                }
            }
            if (!started) {
                started = true
                scope.launch {
                    if (released) return@launch
                    try {
                        val system = owner.makeDriver().also { driver = it }
                        val guarded = object : YlDrmSystemDriver {
                            override fun open(callback: (YlDrmSystemEvent) -> Unit) {
                                system.open(callback)
                                val config = system.cryptoConfig()
                                if (config.uuid != YL_WIDEVINE_UUID || config.sessionId.isEmpty() || config.forceAllowInsecureDecoderComponents) {
                                    throw YlBoundaryException(YlFailureKind.DRM_PROTECTION_INSUFFICIENT)
                                }
                                crypto = config
                                state = DrmSession.STATE_OPENED
                                dispatch { it.drmSessionAcquired(state) }
                            }
                            override fun challenge(initData: ByteArray?, mime: String): ByteArray {
                                if (released) throw YlBoundaryException(YlFailureKind.LOAD_CANCELLED)
                                return system.challenge(initData, mime)
                            }
                            override fun install(response: ByteArray) {
                                if (released) throw YlBoundaryException(YlFailureKind.LOAD_CANCELLED)
                                system.install(response)
                            }
                            // The key state machine can invalidate immediately on failure;
                            // Media3 may still hold a CryptoConfig in its decoder. Defer the
                            // actual system close until every renderer/source reference ends.
                            override fun close() = Unit
                        }
                        val session = YlDrmKeySession(identity, init.bytes, init.mime, owner.dispatcher, timeoutMs,
                            { guarded }, exchange, ::fail, ::phaseChanged).also { keys = it }
                        session.start() // No HTTP/ready wait on Media3's playback thread.
                    } catch (failure: Exception) {
                        fail((failure as? YlBoundaryException)?.kind ?: YlFailureKind.DRM_SESSION_FAILED)
                    }
                }
            }
        }
        private fun phaseChanged(phase: YlDrmKeyPhase) {
            if (released || state == DrmSession.STATE_ERROR) return
            when (phase) {
                YlDrmKeyPhase.USABLE -> {
                    state = DrmSession.STATE_OPENED_WITH_KEYS
                    dispatch { it.drmKeysLoaded(KeyRequestInfo.Builder().build()) }
                }
                YlDrmKeyPhase.REQUESTING, YlDrmKeyPhase.AWAITING_KEYS ->
                    state = if (crypto == null) DrmSession.STATE_OPENING else DrmSession.STATE_OPENED
                else -> Unit // onFailure owns the sanitized error; release owns RELEASED.
            }
            publishReadiness()
        }
        private fun fail(kind: YlFailureKind) {
            if (released || state == DrmSession.STATE_ERROR) return
            error = sessionError(kind)
            state = DrmSession.STATE_ERROR
            publishReadiness()
            dispatch { it.drmSessionManagerError(checkNotNull(error)) }
        }
        private fun dispatch(action: (DrmSessionEventListener.EventDispatcher) -> Unit) {
            consumers.keys.filterNotNull().toList().forEach(action)
        }
        override fun release(eventDispatcher: DrmSessionEventListener.EventDispatcher?) {
            owner.checkThread()
            val count = consumers[eventDispatcher] ?: return
            if (count == 1) { consumers.remove(eventDispatcher); eventDispatcher?.drmSessionReleased() }
            else consumers[eventDispatcher] = count - 1
            if (--references != 0) return
            released = true // Fence callbacks and network results synchronously before cleanup.
            state = DrmSession.STATE_RELEASED
            publishReadiness()
            // Media3 may quit its playback Looper immediately after this returns.
            // Fence and wipe the key request, close CDM and cancel jobs on this owner turn.
            try { keys?.disposeOnOwner() }
            finally {
                try { driver?.close() } catch (_: Exception) {
                    // Teardown prose is never delivered to the coroutine exception handler.
                } finally {
                    crypto?.sessionId?.fill(0); crypto = null
                    init.clear(); sessions.remove(this@Session); scope.cancel()
                }
            }
        }

        override fun getState() = state
        override fun getError() = error.takeIf { state == DrmSession.STATE_ERROR }
        override fun getSchemeUuid() = YL_WIDEVINE_UUID
        override fun getCryptoConfig(): FrameworkCryptoConfig? = crypto.takeIf {
            state == DrmSession.STATE_OPENED || state == DrmSession.STATE_OPENED_WITH_KEYS }
        override fun playClearSamplesWithoutKeys() = false
        override fun requiresSecureDecoder(mimeType: String) = true
        override fun queryKeyStatus(): Map<String, String>? = null // No vendor diagnostic prose escapes.
        override fun getOfflineLicenseKeySetId(): ByteArray? = null
    }
}

private fun sessionError(kind: YlFailureKind) = DrmSession.DrmSessionException(
    YlBoundaryException(kind), when (kind) {
        YlFailureKind.DRM_LICENSE_EXPIRED -> PlaybackException.ERROR_CODE_DRM_LICENSE_EXPIRED
        YlFailureKind.DRM_PROTECTION_INSUFFICIENT -> PlaybackException.ERROR_CODE_DRM_DISALLOWED_OPERATION
        YlFailureKind.DRM_PROVISIONING_REQUIRED -> PlaybackException.ERROR_CODE_DRM_PROVISIONING_FAILED
        YlFailureKind.DRM_LICENSE_DENIED, YlFailureKind.DRM_LICENSE_FAILED,
        YlFailureKind.DRM_LICENSE_TIMEOUT -> PlaybackException.ERROR_CODE_DRM_LICENSE_ACQUISITION_FAILED
        else -> PlaybackException.ERROR_CODE_DRM_SYSTEM_ERROR
    })
