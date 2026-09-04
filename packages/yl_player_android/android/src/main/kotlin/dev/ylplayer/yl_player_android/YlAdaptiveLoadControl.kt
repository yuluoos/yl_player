package dev.ylplayer.yl_player_android

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.upstream.Allocator
import androidx.media3.exoplayer.upstream.DefaultAllocator
import kotlin.math.max
import kotlin.math.min

internal fun shouldContinueLoading(
    bufferedMs: Long,
    allocatedBytes: Int,
    profile: YlBufferProfile,
): Boolean {
    val bytesReached = allocatedBytes >= profile.targetBufferBytes
    return when {
        bufferedMs >= profile.maxBufferMs -> false
        bytesReached -> false
        bufferedMs < profile.minBufferMs -> true
        else -> true
    }
}

internal fun shouldStartPlayback(
    bufferedMs: Long,
    playbackSpeed: Float,
    rebuffering: Boolean,
    profile: YlBufferProfile,
): Boolean {
    val speed = max(1f, playbackSpeed)
    val playoutMs = (bufferedMs / speed).toLong()
    val thresholdMs = min(if (rebuffering) 2_000 else 1_000, profile.minBufferMs)
    return playoutMs >= thresholdMs
}

@OptIn(UnstableApi::class)
internal class YlAdaptiveLoadControl(initialProfile: YlBufferProfile) : LoadControl {
    private val allocator = DefaultAllocator(true, C.DEFAULT_BUFFER_SEGMENT_SIZE)
    private var normalProfile = initialProfile
    private var pressureReduced = false

    @Volatile
    var currentProfile: YlBufferProfile = initialProfile
        private set

    val targetBufferBytes: Int
        get() = currentProfile.targetBufferBytes

    init {
        allocator.setTargetBufferSize(initialProfile.targetBufferBytes)
    }

    @Synchronized
    fun updateProfile(profile: YlBufferProfile) {
        normalProfile = profile
        pressureReduced = false
        applyProfile(profile)
    }

    @Synchronized
    fun shrinkForMemoryPressure() {
        if (pressureReduced) return
        pressureReduced = true
        applyProfile(YlPlaybackPolicy.shrinkForMemoryPressure(normalProfile))
        allocator.trim()
    }

    @Synchronized
    fun restoreProfile() {
        if (!pressureReduced && currentProfile == normalProfile) return
        pressureReduced = false
        applyProfile(normalProfile)
    }

    override fun getAllocator(playerId: PlayerId): Allocator = allocator

    override fun shouldContinueLoading(parameters: LoadControl.Parameters): Boolean {
        val bufferedMs = parameters.bufferedDurationUs / 1_000
        return shouldContinueLoading(bufferedMs, allocator.totalBytesAllocated, currentProfile)
    }

    override fun shouldStartPlayback(parameters: LoadControl.Parameters): Boolean =
        shouldStartPlayback(
            bufferedMs = parameters.bufferedDurationUs / 1_000,
            playbackSpeed = parameters.playbackSpeed,
            rebuffering = parameters.rebuffering,
            profile = currentProfile,
        )

    override fun getBackBufferDurationUs(playerId: PlayerId): Long = 0L

    override fun retainBackBufferFromKeyframe(playerId: PlayerId): Boolean = false

    override fun onStopped(playerId: PlayerId) {
        allocator.reset()
    }

    override fun onReleased(playerId: PlayerId) {
        allocator.reset()
    }

    private fun applyProfile(profile: YlBufferProfile) {
        currentProfile = profile
        allocator.setTargetBufferSize(profile.targetBufferBytes)
    }
}
