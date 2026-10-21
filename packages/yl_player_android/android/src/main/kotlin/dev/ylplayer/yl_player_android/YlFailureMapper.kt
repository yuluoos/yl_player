package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.AndroidFailureCategory
import dev.ylplayer.yl_player_android.pigeon.AndroidFailureMessage
import dev.ylplayer.yl_player_android.pigeon.AndroidFailureScope
import dev.ylplayer.yl_player_android.pigeon.FlutterError
import java.io.FileNotFoundException
import java.io.IOException
import java.net.UnknownHostException
import java.util.concurrent.CancellationException
import androidx.media3.datasource.HttpDataSource

/** Code-owned classifications. Callers cannot supply public prose, codes or diagnostic details. */
internal enum class YlFailureKind(
    val category: AndroidFailureCategory,
    val code: String,
    val publicMessage: String,
    val retryable: Boolean = false,
) {
    DRM_CONFIG_INVALID(AndroidFailureCategory.SOURCE, "drm.config_invalid", "The DRM configuration is incomplete or invalid. Check delivery format, certificate, content ID and license policy."),
    DRM_LICENSE_REDIRECT_REJECTED(AndroidFailureCategory.NETWORK, "drm.license_redirect_rejected", "The license redirect was rejected. Check the configured license endpoint and allowed redirect origins."),
    DRM_LICENSE_DENIED(AndroidFailureCategory.NETWORK, "drm.license_denied", "The license server refused the request. Check authorization and license request configuration."),
    DRM_LICENSE_EXPIRED(AndroidFailureCategory.PLATFORM, "drm.license_expired", "The license has expired according to explicit DRM evidence. Renew authorization."),
    DRM_LICENSE_TIMEOUT(AndroidFailureCategory.NETWORK, "drm.license_timeout", "The license request exceeded its deadline."),
    DRM_LICENSE_FAILED(AndroidFailureCategory.NETWORK, "drm.license_failed", "The license request failed. Check the connection and license service."),
    DRM_LICENSE_RESPONSE_INVALID(AndroidFailureCategory.NETWORK, "drm.license_response_invalid", "The license server returned an empty or unsupported response."),
    DRM_PAYLOAD_TOO_LARGE(AndroidFailureCategory.RESOURCE, "drm.payload_too_large", "The DRM request or response exceeds its byte limit."),
    DRM_SESSION_FAILED(AndroidFailureCategory.PLATFORM, "drm.session_failed", "The system DRM session failed. Reload the source or check device DRM support."),
    DRM_PROTECTION_INSUFFICIENT(AndroidFailureCategory.UNSUPPORTED, "drm.protection_insufficient", "The required DRM protection is unavailable. Use a device and output path meeting the content protection requirements."),
    DRM_PROVISIONING_REQUIRED(AndroidFailureCategory.UNSUPPORTED, "drm.provisioning_required", "The device DRM system requires provisioning. Complete device DRM initialization before retrying."),
    DRM_UNSUPPORTED(AndroidFailureCategory.UNSUPPORTED, "drm.unsupported", "This adapter does not support the requested protected playback path."),
    DRM_ENCRYPTION_MODE_UNSUPPORTED(AndroidFailureCategory.UNSUPPORTED, "drm.encryption_mode_unsupported", "The requested encryption mode is unavailable on this operating system."),
    PLAYER_DISPOSED(AndroidFailureCategory.RESOURCE, "player.disposed", "The player has been disposed."),
    PLATFORM_UNAVAILABLE(AndroidFailureCategory.PLATFORM, "platform.unavailable", "The playback platform is unavailable."),
    PLATFORM_INCOMPATIBLE(AndroidFailureCategory.PLATFORM, "platform.incompatible", "The playback platform is incompatible."),
    LOAD_CANCELLED(AndroidFailureCategory.CANCELLED, "load.cancelled", "The operation was cancelled."),
    SESSION_STALE(AndroidFailureCategory.CANCELLED, "session.stale", "The playback session is no longer current."),
    POLICY_UNSUPPORTED(AndroidFailureCategory.UNSUPPORTED, "policy.unsupported", "The requested playback policy is unsupported."),
    SOURCE_INVALID(AndroidFailureCategory.SOURCE, "source.invalid", "The playback source is invalid."),
    TRACK_NOT_FOUND(AndroidFailureCategory.SOURCE, "track.not_found", "The requested audio track is unavailable."),
    SOURCE_MISSING(AndroidFailureCategory.SOURCE, "source.missing", "The playback source is unavailable."),
    NETWORK_FAILED(AndroidFailureCategory.NETWORK, "network.failed", "The media request failed before a usable response was received.", true),
    NETWORK_DNS_FAILED(AndroidFailureCategory.NETWORK, "network.dns_failed", "The media host could not be resolved. Check the network connection and source host configuration.", true),
    NETWORK_HTTP_FORBIDDEN(AndroidFailureCategory.NETWORK, "network.http_forbidden", "The media server refused the request. Check access credentials and request configuration."),
    NETWORK_CONNECT_TIMEOUT(AndroidFailureCategory.NETWORK, "network.connect_timeout", "The connection to the media server timed out.", true),
    NETWORK_READ_TIMEOUT(AndroidFailureCategory.NETWORK, "network.read_timeout", "The media request timed out while reading.", true),
    NETWORK_TLS_FAILED(AndroidFailureCategory.NETWORK, "network.tls_failed", "The secure media connection failed. Check the server certificate and TLS configuration."),
    NETWORK_CONNECTION_FAILED(AndroidFailureCategory.NETWORK, "network.connection_failed", "The connection to the media server could not be established.", true),
    NETWORK_CONNECTION_LOST(AndroidFailureCategory.NETWORK, "network.connection_lost", "The connection to the media server was interrupted.", true),
    NETWORK_REDIRECT_LIMIT(AndroidFailureCategory.NETWORK, "network.redirect_limit", "The media request exceeded the configured redirect limit."),
    NETWORK_PROTOCOL_UNSUPPORTED(AndroidFailureCategory.UNSUPPORTED, "network.protocol_unsupported", "This streaming protocol is unsupported. Use standard RTMP over TCP."),
    RTMP_HANDSHAKE_FAILED(AndroidFailureCategory.NETWORK, "network.rtmp_handshake_failed", "RTMP setup failed or timed out. Check the connection and stream configuration.", true),
    RTMP_HANDSHAKE_INVALID(AndroidFailureCategory.NETWORK, "network.rtmp_handshake_failed", "The RTMP handshake is invalid. Check server protocol compatibility."),
    RTMP_DISCONNECTED(AndroidFailureCategory.NETWORK, "network.rtmp_disconnected", "The RTMP connection was interrupted or media timed out.", true),
    RTMP_STREAM_UNAVAILABLE(AndroidFailureCategory.NETWORK, "network.rtmp_stream_unavailable", "The RTMP server denied or could not provide the stream. Check stream access and availability."),
    RTMP_TRACK_LAYOUT_CHANGED(AndroidFailureCategory.CONTAINER, "container.rtmp_track_layout_changed", "The RTMP track configuration changed. Reload the stream to continue playback."),
    CONTAINER_UNSUPPORTED(AndroidFailureCategory.CONTAINER, "container.unsupported", "The media container is unsupported."),
    DECODER_UNSUPPORTED(AndroidFailureCategory.DECODER, "decoder.unsupported", "The required decoder is unsupported."),
    DECODER_UNAVAILABLE(AndroidFailureCategory.DECODER, "decoder.unavailable", "The required decoder is unavailable."),
    RESOURCE_EXHAUSTED(AndroidFailureCategory.RESOURCE, "resource.exhausted", "Playback resources are exhausted."),
    PROTOCOL_MISMATCH(AndroidFailureCategory.PROTOCOL, "protocol.mismatch", "The player transport failed."),
    PLATFORM_FAILURE(AndroidFailureCategory.PLATFORM, "platform.failure", "The playback platform failed."),
    INTERNAL(AndroidFailureCategory.INTERNAL, "internal.failure", "An internal player failure occurred."),
}

internal class YlBoundaryException(val kind: YlFailureKind, cause: Throwable? = null) : RuntimeException(cause)
internal class YlHttpStatusException(val status: Int) : IOException()
internal class YlRequestCancelledException : java.io.InterruptedIOException()
internal class YlHeaderTimeoutException : java.net.SocketTimeoutException()
internal class YlRedirectException(val status: Int) : java.net.ProtocolException()

internal data class YlFailureDescription(
    val kind: YlFailureKind,
    val code: String = kind.code,
    val message: String = kind.publicMessage,
    val httpStatus: Int? = null,
    val retryable: Boolean = kind.retryable,
)

/** Derives public data only from exception types and numeric HTTP evidence. */
internal object YlFailureDescriptions {
    private val generic = setOf(YlFailureKind.NETWORK_FAILED, YlFailureKind.PLATFORM_FAILURE, YlFailureKind.INTERNAL)
    fun describe(error: Throwable): YlFailureDescription {
        val causes = error.boundedCauses().toList()
        val status = causes.firstNotNullOfOrNull {
            when (it) {
                is YlHttpStatusException -> it.status
                is HttpDataSource.InvalidResponseCodeException -> it.responseCode
                is YlRedirectException -> it.status
                else -> null
            }?.takeIf { value -> value in 100..599 }
        }
        val explicit = causes.filterIsInstance<YlBoundaryException>().firstOrNull { it.kind !in generic }?.kind
            ?: causes.filterIsInstance<YlRtmpException>().firstOrNull()?.kind
        if (explicit != null) return if (explicit == YlFailureKind.NETWORK_HTTP_FORBIDDEN) http(403)
            else YlFailureDescription(explicit, httpStatus = status)
        if (causes.any { it is CancellationException || it is YlRequestCancelledException })
            return YlFailureDescription(YlFailureKind.LOAD_CANCELLED)
        if (causes.any { it is YlRedirectException }) return YlFailureDescription(YlFailureKind.NETWORK_REDIRECT_LIMIT, httpStatus = status)
        if (status != null) return http(status)
        val kind = when {
            causes.any { it is UnknownHostException } -> YlFailureKind.NETWORK_DNS_FAILED
            causes.any { it is javax.net.ssl.SSLException } -> YlFailureKind.NETWORK_TLS_FAILED
            causes.any { it is YlHeaderTimeoutException } -> YlFailureKind.NETWORK_CONNECT_TIMEOUT
            causes.any { it is java.net.SocketTimeoutException } -> YlFailureKind.NETWORK_READ_TIMEOUT
            causes.any { it is java.net.ConnectException } -> YlFailureKind.NETWORK_CONNECTION_FAILED
            causes.any { it is java.net.SocketException || it is java.io.EOFException } -> YlFailureKind.NETWORK_CONNECTION_LOST
            causes.any { it is FileNotFoundException } -> YlFailureKind.SOURCE_MISSING
            causes.any { it is IOException } -> YlFailureKind.NETWORK_FAILED
            causes.any { it is OutOfMemoryError } -> YlFailureKind.RESOURCE_EXHAUSTED
            else -> causes.filterIsInstance<YlBoundaryException>().firstOrNull()?.kind ?: YlFailureKind.INTERNAL
        }
        return YlFailureDescription(kind)
    }

    fun http(status: Int): YlFailureDescription {
        if (status !in 100..599) return YlFailureDescription(YlFailureKind.NETWORK_FAILED)
        val reason = when (status) {
            401 -> "The media server requires authentication. Check access credentials."
            403 -> "The media server refused the request. Check access credentials and request configuration."
            404 -> "The requested media resource was not found."
            408 -> "The media server timed out waiting for the request."
            410 -> "The requested media resource is no longer available."
            416 -> "The media server rejected the requested byte range."
            429 -> "Too many requests. Wait before retrying."
            in 500..599 -> "The upstream media service is unavailable or failed to complete the request."
            in 300..399 -> "The media redirect could not be followed."
            else -> "The media server returned an unexpected HTTP response."
        }
        return YlFailureDescription(
            if (status == 403) YlFailureKind.NETWORK_HTTP_FORBIDDEN else YlFailureKind.NETWORK_FAILED,
            if (status == 403) "network.http_forbidden" else "network.http_status.$status",
            "HTTP $status: $reason", status, status in listOf(408, 429, 500, 502, 503, 504))
    }
}

internal class YlFailureMapper(private val diagnostics: YlSafeDiagnostics = YlSafeDiagnostics()) {
    fun toMessage(error: Throwable, scope: AndroidFailureScope = AndroidFailureScope.COMMAND): AndroidFailureMessage {
        val failure = YlFailureDescriptions.describe(error)
        return AndroidFailureMessage(failure.kind.category, failure.code, failure.message,
            failure.retryable, scope, diagnostics.record(error))
    }

    fun toFlutterError(error: Throwable, scope: AndroidFailureScope = AndroidFailureScope.COMMAND): FlutterError {
        val failure = toMessage(error, scope)
        return FlutterError(failure.code, failure.message, failure)
    }

    fun record(error: Throwable) { diagnostics.record(error) }
}

internal fun Throwable.boundedCauses(limit: Int = 8): Sequence<Throwable> = sequence {
    var current: Throwable? = this@boundedCauses
    val seen = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Throwable, Boolean>())
    repeat(limit) {
        val value = current ?: return@sequence
        if (!seen.add(value)) return@sequence
        yield(value)
        current = value.cause
    }
}
