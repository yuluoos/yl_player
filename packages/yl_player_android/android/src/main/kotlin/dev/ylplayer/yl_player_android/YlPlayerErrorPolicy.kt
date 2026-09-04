package dev.ylplayer.yl_player_android

internal data class YlStableError(
    val category: String,
    val code: String,
    val message: String,
)

internal enum class YlPlaybackFailure {
    NO_HARDWARE_DECODER,
    CAPABILITY_EXCEEDED,
    DECODER_INITIALIZATION,
    DECODER_BUSY,
    MEMORY_PRESSURE,
    LIVE_RETRY_EXHAUSTED,
}

internal enum class YlDecoderRecovery { DOWNGRADE_ONCE, FAIL }

internal fun decoderRecovery(isAdaptive: Boolean, previousRetries: Int): YlDecoderRecovery =
    if (isAdaptive && previousRetries == 0) {
        YlDecoderRecovery.DOWNGRADE_ONCE
    } else {
        YlDecoderRecovery.FAIL
    }

internal fun stableError(failure: YlPlaybackFailure): YlStableError = when (failure) {
    YlPlaybackFailure.NO_HARDWARE_DECODER -> YlStableError(
        "decoderUnsupported",
        "decoder.hardware_required",
        "A compatible hardware video decoder is required.",
    )
    YlPlaybackFailure.CAPABILITY_EXCEEDED -> YlStableError(
        "decoderUnsupported",
        "decoder.capability_exceeded",
        "The video format exceeds the safe hardware decode envelope.",
    )
    YlPlaybackFailure.DECODER_INITIALIZATION -> YlStableError(
        "decoderFailure",
        "decoder.initialization_failed",
        "Hardware video decoder initialization failed.",
    )
    YlPlaybackFailure.DECODER_BUSY -> YlStableError(
        "resource",
        "resource.video_decoder_busy",
        "The hardware video decoder is still owned by another player.",
    )
    YlPlaybackFailure.MEMORY_PRESSURE -> YlStableError(
        "resource",
        "resource.memory_pressure",
        "Playback could not be rebuilt safely after memory pressure.",
    )
    YlPlaybackFailure.LIVE_RETRY_EXHAUSTED -> YlStableError(
        "network",
        "network.live_retry_exhausted",
        "Live playback reconnect attempts were exhausted.",
    )
}

internal fun codecDiagnostic(
    codecName: String?,
    width: Int?,
    height: Int?,
    frameRate: Double?,
    apiLevel: Int,
): String = buildList {
    codecName?.let { add("codec=$it") }
    if (width != null && height != null) add("size=${width}x$height")
    frameRate?.let { add("fps=$it") }
    add("api=$apiLevel")
}.joinToString(",")
