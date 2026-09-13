package dev.ylplayer.yl_player_android

/** Decides whether changing the playback backend can resolve a failure. */
internal object YlFallbackRoutingPolicy {
    private val backendRecoverableFailures = setOf(
        YlFailureKind.CONTAINER_UNSUPPORTED,
        YlFailureKind.DECODER_UNSUPPORTED,
        YlFailureKind.DECODER_UNAVAILABLE,
    )

    fun shouldFallback(failure: YlFailureKind, fallbackAttempted: Boolean): Boolean =
        !fallbackAttempted && failure in backendRecoverableFailures

    fun shouldFallbackFirstFrameTimeout(
        fallbackAttempted: Boolean,
        inputProgressing: Boolean,
        videoPacketsObserved: Boolean,
    ): Boolean = !fallbackAttempted && inputProgressing && videoPacketsObserved
}
