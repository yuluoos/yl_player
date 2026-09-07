package dev.ylplayer.yl_player_android

/** A new empty session; native player and texture ownership stay with the caller. */
internal object YlStopPolicy {
    data class Reset(val generation: Long, val state: Map<String, Any?>)

    fun reset(generation: Long) = Reset(
        generation = generation + 1,
        state = mapOf(
            "status" to "idle",
            "positionMs" to 0L,
            "durationMs" to null,
            "bufferedPositionMs" to 0L,
            "isLive" to false,
            "isSeekable" to false,
            "isAtLiveEdge" to false,
            "liveOffsetMs" to null,
            "dvrStartMs" to null,
            "dvrEndMs" to null,
            "videoWidth" to null,
            "videoHeight" to null,
            "engine" to "media3",
            "isHardwareDecoding" to false,
            "decoderName" to null,
            "audioTracks" to emptyList<Any>(),
            "videoTracks" to emptyList<Any>(),
            "error" to null,
            "metrics" to mapOf<String, Any?>(
                "openDurationMs" to null,
                "firstFrameDurationMs" to null,
                "rebufferCount" to 0,
                "rebufferDurationMs" to 0L,
                "droppedVideoFrames" to 0,
                "audioUnderruns" to 0,
                "estimatedBitrate" to null,
                "bufferedDurationMs" to 0L,
                "bufferedBytes" to 0,
                "liveOffsetMs" to null,
                "reconnectCount" to 0,
                "adaptiveDowngradeCount" to 0,
                "surfaceRebuildCount" to 0,
                "selectedVideoBitrate" to null,
            ),
        ),
    )
}
