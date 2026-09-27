package dev.ylplayer.yl_player_android

import android.media.MediaDrm
import android.media.DeniedByServerException
import android.media.NotProvisionedException
import android.media.ResourceBusyException
import android.media.UnsupportedSchemeException
import android.os.Handler
import java.util.UUID

/** Internal system boundary consumed by the Media3 DRM adapter; public playback
 * still requires the protected output and session transaction integration. Must be constructed/called on its owner Looper.
 * Does no networking, provisioning, logging, content-key extraction or L3 fallback.
 */
@Suppress("DEPRECATION")
internal class YlWidevineDriver(
    private val api: Int,
    private val cbcs: Boolean,
    private val handler: Handler?,
    private val create: () -> MediaDrm = { MediaDrm(UUID.fromString("edef8ba9-79d6-4ace-a3c8-27dcd51d21ed")) },
) : YlDrmCryptoDriver {
    private var media: MediaDrm? = null
    private var session: ByteArray? = null
    private var closed = false
    override fun open(callback: (YlDrmSystemEvent) -> Unit) {
        if (closed || media != null) throw YlBoundaryException(YlFailureKind.SESSION_STALE)
        if (api < 24) throw YlBoundaryException(YlFailureKind.DRM_UNSUPPORTED)
        if (cbcs && api < 25) throw YlBoundaryException(YlFailureKind.DRM_ENCRYPTION_MODE_UNSUPPORTED)
        // API24–27 cannot query the actual per-session security level through the
        // public API. A requested Widevine property alone isn't proof of L1.
        if (api < 28) throw YlBoundaryException(YlFailureKind.DRM_PROTECTION_INSUFFICIENT)
        try {
            val system = create().also { media = it }
            val id = system.openSession(MediaDrm.SECURITY_LEVEL_HW_SECURE_ALL).also { session = it }
            if (id.isEmpty() || system.getSecurityLevel(id) != MediaDrm.SECURITY_LEVEL_HW_SECURE_ALL) {
                throw YlBoundaryException(YlFailureKind.DRM_PROTECTION_INSUFFICIENT)
            }
            fun current(value: ByteArray?) = !closed && media === system && value != null && session?.contentEquals(value) == true
            system.setOnKeyStatusChangeListener({ _, value, statuses, _ ->
                if (current(value)) callback(when {
                    statuses.any { it.statusCode == MediaDrm.KeyStatus.STATUS_OUTPUT_NOT_ALLOWED } -> YlDrmSystemEvent.OUTPUT_RESTRICTED
                    statuses.any { it.statusCode == MediaDrm.KeyStatus.STATUS_EXPIRED } -> YlDrmSystemEvent.EXPIRED
                    statuses.any { it.statusCode == MediaDrm.KeyStatus.STATUS_INTERNAL_ERROR } -> YlDrmSystemEvent.FAILED
                    statuses.isNotEmpty() && statuses.all { it.statusCode == MediaDrm.KeyStatus.STATUS_USABLE } -> YlDrmSystemEvent.USABLE
                    else -> YlDrmSystemEvent.PENDING
                })
            }, handler)
            system.setOnEventListener { _, value, event, _, _ ->
                if (current(value)) when (event) {
                    MediaDrm.EVENT_KEY_REQUIRED -> callback(YlDrmSystemEvent.KEY_REQUIRED)
                    MediaDrm.EVENT_KEY_EXPIRED -> callback(YlDrmSystemEvent.EXPIRED)
                    MediaDrm.EVENT_SESSION_RECLAIMED -> callback(YlDrmSystemEvent.FAILED)
                    MediaDrm.EVENT_PROVISION_REQUIRED -> callback(YlDrmSystemEvent.PROVISION_REQUIRED)
                }
            }
        } catch (error: Exception) {
            close()
            throw sanitized(error)
        }
    }
    override fun cryptoConfig(): androidx.media3.exoplayer.drm.FrameworkCryptoConfig = checked { _, id ->
        androidx.media3.exoplayer.drm.FrameworkCryptoConfig(YL_WIDEVINE_UUID, id.copyOf(), false)
    }
    override fun challenge(initData: ByteArray?, mime: String): ByteArray = checked { system, id ->
        // The source's configured license endpoint owns routing; never use the
        // CDM request's defaultUrl or silently invoke a provisioning endpoint.
        system.getKeyRequest(id, initData, mime, MediaDrm.KEY_TYPE_STREAMING, hashMapOf()).data
    }
    override fun install(response: ByteArray) {
        checked { system, id -> system.provideKeyResponse(id, response)?.fill(0) }
    }
    private fun <T> checked(body: (MediaDrm, ByteArray) -> T): T {
        val system = media; val id = session
        if (closed || system == null || id == null) throw YlBoundaryException(YlFailureKind.SESSION_STALE)
        try { return body(system, id) } catch (error: Exception) { throw sanitized(error) }
    }
    override fun close() {
        if (closed) return
        closed = true
        val system = media; val id = session
        media = null; session = null
        if (system != null) {
            try {
                try { system.setOnKeyStatusChangeListener(null, handler) } catch (_: Exception) {}
                try { system.setOnEventListener(null) } catch (_: Exception) {}
                if (id != null) try { system.closeSession(id) } catch (_: Exception) {}
            } finally {
                id?.fill(0)
                try { system.release() } catch (_: Exception) {}
            }
        }
    }
    private fun sanitized(error: Exception) = if (error is YlBoundaryException) error else YlBoundaryException(when (error) {
        is NotProvisionedException -> YlFailureKind.DRM_PROVISIONING_REQUIRED
        is DeniedByServerException -> YlFailureKind.DRM_LICENSE_DENIED
        is ResourceBusyException -> YlFailureKind.RESOURCE_EXHAUSTED
        is UnsupportedSchemeException -> YlFailureKind.DRM_UNSUPPORTED
        else -> YlFailureKind.DRM_SESSION_FAILED
    })
}
