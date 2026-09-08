package dev.ylplayer.yl_player_android

import androidx.media3.common.Tracks

internal data class AudioSelection(val group: Tracks.Group, val trackIndex: Int)

internal data class AndroidQualityConstraint(
    val maxWidth: Int? = null,
    val maxHeight: Int? = null,
    val maxBitrate: Int? = null,
)

internal data class PlayerConfiguration(
    val bufferMode: String,
    val decoderPolicy: String,
    val minBufferMs: Int?,
    val maxBufferMs: Int?,
    val maxBufferBytes: Int?,
    val positionEventIntervalMs: Long,
    val network: NetworkConfiguration,
    val managesAudioSession: Boolean = true,
) {
    fun bufferRequest() = YlBufferRequest(
        mode = bufferMode,
        minBufferMs = minBufferMs,
        maxBufferMs = maxBufferMs,
        maxBufferBytes = maxBufferBytes,
    )

}
