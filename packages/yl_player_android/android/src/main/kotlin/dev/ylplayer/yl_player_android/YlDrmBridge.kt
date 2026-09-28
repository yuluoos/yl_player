package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import kotlinx.coroutines.*

internal fun YlDrmSessionIdentity.wire() = AndroidProtectedSurfaceMessage(playerId, surfaceId, sessionId, generation)
internal fun AndroidProtectedSurfaceMessage.identity() = YlDrmSessionIdentity(playerId, surfaceId, sessionId, generation)

/** Main-owned bridge. License endpoint/credentials never enter native code. */
internal class YlDrmBridge(
    val playerId: Long,
    val views: YlProtectedViewRegistry,
    private val send: suspend (AndroidDrmLicenseRequest) -> AndroidDrmLicenseReply,
    private val cancel: suspend (AndroidDrmExchangeId) -> Unit,
    private val frame: suspend (AndroidProtectedViewAck) -> Unit,
    private val dispatcher: CoroutineDispatcher = Dispatchers.Main,
) : AndroidDrmHostApi {
    private val notifications = CoroutineScope(SupervisorJob() + dispatcher)
    private val pending = mutableMapOf<String, Job>()
    private var closed = false
    var cancelPending: (String) -> Unit = {}
    override fun cancelProtectedLoad(loadRequestId: String) {
        try {
            if (closed) throw YlBoundaryException(YlFailureKind.PLAYER_DISPOSED)
            YlBoundaryValidation.identity(loadRequestId)
            cancelPending(loadRequestId)
        } catch (error: Throwable) { throw YlFailureMapper().toFlutterError(error) }
    }
    init { views.frameSinks[playerId] = { value -> notifications.launch { runCatching { withTimeout(5000) { frame(value) } } } } }
    suspend fun exchange(loadRequestId: String, request: YlDrmKeyRequest): ByteArray = withContext(dispatcher) {
        if (closed) throw YlBoundaryException(YlFailureKind.LOAD_CANCELLED)
        if (request.identity.playerId != playerId || request.epoch < 1 || request.requestId < 1) throw YlBoundaryException(YlFailureKind.PROTOCOL_MISMATCH)
        YlBoundaryValidation.identity(loadRequestId)
        val id = AndroidDrmExchangeId(request.identity.wire(), loadRequestId, request.epoch, request.requestId, request.exchangeId)
        if (pending.size >= 4) throw YlBoundaryException(YlFailureKind.RESOURCE_EXHAUSTED)
        if (pending.containsKey(id.exchangeId)) throw YlBoundaryException(YlFailureKind.PROTOCOL_MISMATCH)
        val challenge = request.bytes
        if (challenge.isEmpty() || challenge.size > 1024 * 1024) throw YlBoundaryException(YlFailureKind.DRM_PAYLOAD_TOO_LARGE)
        pending[id.exchangeId] = currentCoroutineContext().job
        try {
            val reply = send(AndroidDrmLicenseRequest(id, challenge))
            currentCoroutineContext().ensureActive()
            if (closed) throw YlBoundaryException(YlFailureKind.LOAD_CANCELLED)
            if (reply.id != id) throw YlBoundaryException(YlFailureKind.PROTOCOL_MISMATCH)
            val response = reply.response
            try {
                reply.failureCode?.let { code ->
                    if (response != null) throw YlBoundaryException(YlFailureKind.PROTOCOL_MISMATCH)
                    throw YlBoundaryException(licenseFailures.firstOrNull { it.code == code } ?: YlFailureKind.DRM_LICENSE_FAILED)
                }
                if (response == null || response.isEmpty()) throw YlBoundaryException(YlFailureKind.DRM_LICENSE_RESPONSE_INVALID)
                if (response.size > 4 * 1024 * 1024) throw YlBoundaryException(YlFailureKind.DRM_PAYLOAD_TOO_LARGE)
                response.copyOf()
            } finally { response?.fill(0) }
        } catch (error: CancellationException) { throw error }
        catch (error: YlBoundaryException) { throw error }
        catch (_: Exception) { throw YlBoundaryException(YlFailureKind.DRM_LICENSE_FAILED) }
        finally {
            challenge.fill(0); pending.remove(id.exchangeId)
            // Also settles Dart cancellation listeners after successful completion.
            notifications.launch { runCatching { withTimeout(5000) { cancel(id) } } }
        }
    }
    private fun check(command: AndroidProtectedViewCommand) {
        if (closed || command.surface.playerId != playerId || command.viewId < 0) throw YlBoundaryException(YlFailureKind.SESSION_STALE)
    }
    override suspend fun attachProtectedView(command: AndroidProtectedViewCommand): AndroidProtectedViewAck {
        return try { check(command); views.acknowledge(command) }
        catch (error: Throwable) { throw YlFailureMapper().toFlutterError(error) }
    }
    override suspend fun detachProtectedView(command: AndroidProtectedViewCommand): AndroidProtectedViewAck {
        return try { check(command); views.detachView(command) }
        catch (error: Throwable) { throw YlFailureMapper().toFlutterError(error) }
    }
    fun close() {
        if (closed) return
        closed = true
        views.frameSinks.remove(playerId)
        pending.values.toList().forEach { it.cancel() }
        // Cancellation notifications must outlive host commands, but never own this player forever.
        notifications.launch { delay(5000); notifications.cancel() }
    }
    companion object {
        private val licenseFailures = setOf(YlFailureKind.DRM_LICENSE_DENIED, YlFailureKind.DRM_LICENSE_REDIRECT_REJECTED, YlFailureKind.DRM_LICENSE_TIMEOUT,
            YlFailureKind.DRM_LICENSE_FAILED, YlFailureKind.DRM_LICENSE_RESPONSE_INVALID, YlFailureKind.DRM_PAYLOAD_TOO_LARGE,
            YlFailureKind.LOAD_CANCELLED, YlFailureKind.RESOURCE_EXHAUSTED)
    }
}
