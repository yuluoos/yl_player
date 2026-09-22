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
    PLAYER_DISPOSED(AndroidFailureCategory.RESOURCE, "player.disposed", "The player has been disposed."),
    PLATFORM_UNAVAILABLE(AndroidFailureCategory.PLATFORM, "platform.unavailable", "The playback platform is unavailable."),
    PLATFORM_INCOMPATIBLE(AndroidFailureCategory.PLATFORM, "platform.incompatible", "The playback platform is incompatible."),
    LOAD_CANCELLED(AndroidFailureCategory.CANCELLED, "load.cancelled", "The operation was cancelled."),
    SESSION_STALE(AndroidFailureCategory.CANCELLED, "session.stale", "The playback session is no longer current."),
    POLICY_UNSUPPORTED(AndroidFailureCategory.UNSUPPORTED, "policy.unsupported", "The requested playback policy is unsupported."),
    SOURCE_INVALID(AndroidFailureCategory.SOURCE, "source.invalid", "The playback source is invalid."),
    SOURCE_MISSING(AndroidFailureCategory.SOURCE, "source.missing", "The playback source is unavailable."),
    NETWORK_FAILED(AndroidFailureCategory.NETWORK, "network.failed", "The network request failed.", true),
    NETWORK_DNS_FAILED(AndroidFailureCategory.NETWORK, "network.dns_failed", "The media host could not be resolved. Check the network connection and source host configuration.", true),
    NETWORK_HTTP_FORBIDDEN(AndroidFailureCategory.NETWORK, "network.http_forbidden", "The media server refused the request. Check access credentials and request configuration."),
    CONTAINER_UNSUPPORTED(AndroidFailureCategory.CONTAINER, "container.unsupported", "The media container is unsupported."),
    DECODER_UNSUPPORTED(AndroidFailureCategory.DECODER, "decoder.unsupported", "The required decoder is unsupported."),
    DECODER_UNAVAILABLE(AndroidFailureCategory.DECODER, "decoder.unavailable", "The required decoder is unavailable."),
    RESOURCE_EXHAUSTED(AndroidFailureCategory.RESOURCE, "resource.exhausted", "Playback resources are exhausted."),
    PROTOCOL_MISMATCH(AndroidFailureCategory.PROTOCOL, "protocol.mismatch", "The player transport failed."),
    PLATFORM_FAILURE(AndroidFailureCategory.PLATFORM, "platform.failure", "The playback platform failed."),
    INTERNAL(AndroidFailureCategory.INTERNAL, "internal.failure", "An internal player failure occurred."),
}

internal class YlBoundaryException(val kind: YlFailureKind) : RuntimeException()

internal class YlFailureMapper(private val diagnostics: YlSafeDiagnostics = YlSafeDiagnostics()) {
    fun toMessage(error: Throwable, scope: AndroidFailureScope = AndroidFailureScope.COMMAND): AndroidFailureMessage {
        val causes = error.boundedCauses().toList()
        val kind = when {
            error is YlBoundaryException -> error.kind
            error is CancellationException -> YlFailureKind.LOAD_CANCELLED
            error is FileNotFoundException -> YlFailureKind.SOURCE_MISSING
            causes.firstOrNull { it is YlBoundaryException } != null ->
                (causes.first { it is YlBoundaryException } as YlBoundaryException).kind
            causes.any { it is CancellationException } -> YlFailureKind.LOAD_CANCELLED
            causes.any { it is UnknownHostException } -> YlFailureKind.NETWORK_DNS_FAILED
            causes.any { it is HttpDataSource.InvalidResponseCodeException && it.responseCode == 403 } -> YlFailureKind.NETWORK_HTTP_FORBIDDEN
            error is IOException -> YlFailureKind.NETWORK_FAILED
            error is OutOfMemoryError -> YlFailureKind.RESOURCE_EXHAUSTED
            else -> YlFailureKind.INTERNAL
        }
        return AndroidFailureMessage(kind.category, kind.code, kind.publicMessage, kind.retryable, scope, diagnostics.record(error))
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
