package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import java.net.URI
import java.io.ByteArrayOutputStream

internal data class YlRtmpAddress(val host: String, val port: Int, val app: String, val playpath: String, val tcUrl: String)

/** Raw path/query are protocol identifiers, never decoded or included in diagnostics. */
internal object YlRtmpSourcePolicy {
    fun isRtmp(source: AndroidSourceMessage) = source.kind == AndroidSourceKind.NETWORK &&
        source.locator.substringBefore(':').lowercase() in setOf("rtmp", "rtmps")
    fun parse(locator: String): YlRtmpAddress {
        fun invalid(): Nothing = throw YlBoundaryException(YlFailureKind.SOURCE_INVALID)
        if (locator.length > 8192 || locator.toByteArray(Charsets.UTF_8).size > 8192 || hasControl(locator)) invalid()
        val uri = try { URI(locator) } catch (_: Exception) { invalid() }
        if (uri.scheme?.lowercase() !in setOf("rtmp", "rtmps") || uri.host.isNullOrBlank() || uri.rawUserInfo != null || uri.rawFragment != null) invalid()
        val authority = uri.rawAuthority ?: invalid()
        if (authority.endsWith(':') || (uri.port != -1 && uri.port !in 1..65535)) invalid()
        val raw = uri.rawPath ?: invalid()
        if (!raw.startsWith('/')) invalid()
        val split = raw.indexOf('/', 1)
        if (split <= 1 || split == raw.lastIndex) invalid()
        if (uri.scheme.equals("rtmps", true)) throw YlBoundaryException(YlFailureKind.NETWORK_PROTOCOL_UNSUPPORTED)
        return YlRtmpAddress(uri.host.removePrefix("[").removeSuffix("]"), if (uri.port == -1) 1935 else uri.port,
            raw.substring(1, split), raw.substring(split + 1) + (uri.rawQuery?.let { "?$it" } ?: ""),
            "rtmp://$authority/${raw.substring(1, split)}")
    }
    private fun hasControl(raw: String): Boolean {
        // Decode octets solely for rejecting ASCII and valid UTF-8 Unicode controls. Invalid
        // UTF-8 is opaque and is preserved verbatim in the app/playpath handed to RTMP.
        val bytes = ByteArrayOutputStream()
        var i = 0
        while (i < raw.length) {
            if (raw[i] == '%') {
                if (i + 2 >= raw.length) return true
                val value = raw.substring(i + 1, i + 3).toIntOrNull(16) ?: return true
                bytes.write(value); i += 3
            } else {
                val cp = Character.codePointAt(raw, i)
                bytes.write(String(Character.toChars(cp)).toByteArray(Charsets.UTF_8)); i += Character.charCount(cp)
            }
        }
        return bytes.toByteArray().toString(Charsets.UTF_8).any { Character.isISOControl(it) }
    }
    fun validate(source: AndroidSourceMessage, options: AndroidLoadOptionsMessage) {
        parse(source.locator)
        if (source.format !in setOf(AndroidMediaFormat.AUTOMATIC, AndroidMediaFormat.FLV)) throw YlBoundaryException(YlFailureKind.CONTAINER_UNSUPPORTED)
        if (source.intent == AndroidStreamIntent.ON_DEMAND || (options.startPositionMs ?: 0) != 0L ||
            source.request?.headers.orEmpty().isNotEmpty() || source.request?.credentials.orEmpty().isNotEmpty() ||
            source.networkPolicy?.kind == AndroidNetworkPolicyKind.MANAGED || options.bufferStrategy.kind == AndroidBufferKind.BOUNDED)
            throw YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED)
    }
}
