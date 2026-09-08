package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*

/** Native counterpart of the shared v2 request validators. Validate before ownership or intent
 * changes; policy integers are signed32, while positions retain the signed64 transport range. */
internal object YlBoundaryValidation {
    private fun requireValid(valid: Boolean) {
        if (!valid) throw YlBoundaryException(YlFailureKind.SOURCE_INVALID)
    }
    private fun policy(value: Long?, positive: Boolean) {
        requireValid(value != null && value in (if (positive) 1L else 0L)..Int.MAX_VALUE.toLong())
    }
    fun player(options: AndroidPlayerOptionsMessage) = policy(options.positionUpdateIntervalMs, true)
    fun identity(value: String) = requireValid(value.isNotEmpty())
    fun position(value: Long) = requireValid(value >= 0)
    fun volume(value: Double) = requireValid(value.isFinite() && value in 0.0..1.0)
    fun speed(value: Double) {
        if (!value.isFinite() || value !in 0.25..4.0) throw YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED)
    }
    fun constraints(value: AndroidVideoConstraintsMessage) {
        listOf(value.maxWidth, value.maxHeight, value.maxBitrate).filterNotNull().forEach { policy(it, true) }
    }
    fun load(source: AndroidSourceMessage, options: AndroidLoadOptionsMessage) {
        options.startPositionMs?.let(::position)
        constraints(options.videoConstraints)
        // Bounded allocation is unsupported, including malformed requests; never allocate or
        // narrow any bounded field under a falsely advertised hard byte guarantee.
        if (options.bufferStrategy.kind == AndroidBufferKind.BOUNDED) throw YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED)
        requireValid(listOf(options.bufferStrategy.minDurationMs, options.bufferStrategy.maxDurationMs,
            options.bufferStrategy.maxManagedBytes).all { it == null })
        source.networkPolicy?.let { network ->
            val fields = listOf(network.connectTimeoutMs, network.readTimeoutMs, network.maxRetries,
                network.baseRetryDelayMs, network.maxRetryDelayMs, network.maxRedirects)
            if (network.kind == AndroidNetworkPolicyKind.PLATFORM_DEFAULT) requireValid(fields.all { it == null })
            else {
                if (source.kind != AndroidSourceKind.NETWORK) throw YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED)
                policy(network.connectTimeoutMs, true); policy(network.readTimeoutMs, true)
                policy(network.maxRetries, false); policy(network.maxRedirects, false)
                policy(network.baseRetryDelayMs, false); policy(network.maxRetryDelayMs, false)
                requireValid(network.baseRetryDelayMs!! <= network.maxRetryDelayMs!!)
            }
        }
    }
}
