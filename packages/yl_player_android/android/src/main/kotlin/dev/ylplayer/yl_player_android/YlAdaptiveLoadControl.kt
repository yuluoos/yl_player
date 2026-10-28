package dev.ylplayer.yl_player_android

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Timeline
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
    playbackSpeed: Float = 1f,
): Boolean {
    val bytesReached = allocatedBytes >= profile.targetBufferBytes
    // Duration is a playout goal; the independent byte target still wins.
    // Cap extra read-ahead at 2x even when the user requests a higher speed.
    val speed = if (playbackSpeed.isFinite()) playbackSpeed.coerceIn(1f, 2f) else 1f
    return when {
        bufferedMs >= profile.maxBufferMs.toDouble() * speed -> false
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
    allocatedBytes: Int = 0,
): Boolean {
    val speed = max(1f, playbackSpeed)
    val playoutMs = (bufferedMs / speed).toLong()
    val thresholdMs = min(if (rebuffering) 2_000 else 1_000, profile.minBufferMs)
    // A small heap may fill its byte budget before the time target. Permit
    // buffered playback to drain it rather than waiting for loading we disabled.
    return playoutMs >= thresholdMs || (bufferedMs > 0 && profile.targetBufferBytes > 0 &&
        allocatedBytes >= profile.targetBufferBytes)
}

@OptIn(UnstableApi::class)
/** Buffer targets are scheduling goals, never an enforced hard allocation ceiling. */
internal class YlAdaptiveLoadControl(initialProfile: YlBufferProfile) : LoadControl {
    private val allocator = DefaultAllocator(true, C.DEFAULT_BUFFER_SEGMENT_SIZE)
    // LoadControl callbacks own these scratch objects on the playback thread.
    private val period = Timeline.Period()
    private val window = Timeline.Window()
    private var normalProfile = initialProfile
    private var pressureReduced = false

    @Volatile
    var currentProfile: YlBufferProfile = initialProfile
        private set

    val targetBufferBytes: Int
        get() = currentProfile.targetBufferBytes

    val allocatedBytes: Int
        get() = allocator.totalBytesAllocated

    init {
        allocator.setTargetBufferSize(initialProfile.targetBufferBytes)
    }

    @Synchronized
    fun updateProfile(profile: YlBufferProfile) {
        normalProfile = profile
        pressureReduced = false
        applyProfile(profile)
    }

    /** Same-session policy changes cannot revoke an outstanding pressure reduction. */
    @Synchronized
    fun updateRuntimeProfile(profile: YlBufferProfile) {
        normalProfile = profile
        applyProfile(if (pressureReduced) YlPlaybackPolicy.shrinkForMemoryPressure(profile) else profile)
        allocator.trim()
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

    // Each engine owns this allocator; preparation does not reset the selected
    // adaptive profile. Media3 1.11 defaults throw unless these callbacks exist.
    override fun onPrepared(playerId: PlayerId) = Unit

    override fun onTracksSelected(
        parameters: LoadControl.Parameters,
        trackGroups: androidx.media3.exoplayer.source.TrackGroupArray,
        trackSelections: Array<out androidx.media3.exoplayer.trackselection.ExoTrackSelection?>,
    ) = Unit

    override fun getAllocator(playerId: PlayerId): Allocator = allocator

    override fun shouldContinueLoading(parameters: LoadControl.Parameters): Boolean {
        val bufferedMs = parameters.bufferedDurationUs / 1_000
        val speed = if (isOnDemandPeriod(parameters)) parameters.playbackSpeed else 1f
        return shouldContinueLoading(bufferedMs, allocator.totalBytesAllocated, currentProfile, speed)
    }

    private fun isOnDemandPeriod(parameters: LoadControl.Parameters): Boolean {
        if (parameters.mediaPeriodId.isAd || parameters.timeline.isEmpty) return false
        val index = parameters.timeline.getIndexOfPeriod(parameters.mediaPeriodId.periodUid)
        if (index == C.INDEX_UNSET) return false
        parameters.timeline.getPeriod(index, period, false)
        parameters.timeline.getWindow(period.windowIndex, window, 0L)
        return !window.isLive && !window.isDynamic
    }

    override fun shouldStartPlayback(parameters: LoadControl.Parameters): Boolean =
        shouldStartPlayback(
            bufferedMs = parameters.bufferedDurationUs / 1_000,
            playbackSpeed = parameters.playbackSpeed,
            rebuffering = parameters.rebuffering,
            profile = currentProfile,
            allocatedBytes = allocator.totalBytesAllocated,
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
