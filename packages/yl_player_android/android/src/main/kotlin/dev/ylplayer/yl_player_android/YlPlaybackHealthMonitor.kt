package dev.ylplayer.yl_player_android

internal data class YlHealthSample(
    val nowMs: Long,
    val elapsedMs: Long,
    val droppedFrames: Int,
    val estimatedRenderedFrames: Int,
    val rebufferCount: Int,
    val rebufferDurationMs: Long,
    val memoryPressure: Boolean,
    val canDowngrade: Boolean,
    val sourceClass: YlSourceClass,
    val liveOffsetMs: Long?,
    val bufferedDurationMs: Long,
    val targetLiveOffsetMs: Long,
    val maxBufferMs: Int,
    val reconnectCount: Int,
    val maxRetries: Int,
)

internal sealed interface YlRecoveryAction {
    data object None : YlRecoveryAction
    data object DowngradeOneStep : YlRecoveryAction
    data object SeekLiveEdge : YlRecoveryAction
    data object ReconnectLiveHead : YlRecoveryAction
    data class SetCatchUpSpeed(val speed: Float) : YlRecoveryAction
    data class Fail(val error: YlStableError) : YlRecoveryAction
}

internal class YlPlaybackHealthMonitor {
    private var consecutiveUnhealthyWindows = 0
    private var lastDowngradeMs: Long? = null
    private var lastLiveEdgeSeekMs: Long? = null

    fun reset() {
        consecutiveUnhealthyWindows = 0
        lastDowngradeMs = null
        lastLiveEdgeSeekMs = null
    }

    fun record(sample: YlHealthSample): YlRecoveryAction {
        if (sample.memoryPressure) {
            return if (sample.canDowngrade) downgradeOrFail(sample) else YlRecoveryAction.None
        }

        if (
            sample.sourceClass == YlSourceClass.HTTP_FLV_LIVE &&
            sample.bufferedDurationMs > sample.maxBufferMs + LIVE_RECOVERY_MARGIN_MS
        ) {
            return if (sample.reconnectCount >= sample.maxRetries) {
                YlRecoveryAction.Fail(stableError(YlPlaybackFailure.LIVE_RETRY_EXHAUSTED))
            } else {
                YlRecoveryAction.ReconnectLiveHead
            }
        }

        val healthAction = evaluateHealthWindow(sample)
        if (healthAction != YlRecoveryAction.None) return healthAction

        if (sample.sourceClass == YlSourceClass.HLS_LIVE && sample.liveOffsetMs != null) {
            val forceThreshold = sample.maxBufferMs + LIVE_RECOVERY_MARGIN_MS
            if (sample.liveOffsetMs > forceThreshold && canSeekLiveEdge(sample.nowMs)) {
                lastLiveEdgeSeekMs = sample.nowMs
                return YlRecoveryAction.SeekLiveEdge
            }
            return YlRecoveryAction.SetCatchUpSpeed(
                if (sample.liveOffsetMs > sample.targetLiveOffsetMs) 1.03f else 1f,
            )
        }

        return YlRecoveryAction.None
    }

    private fun evaluateHealthWindow(sample: YlHealthSample): YlRecoveryAction {
        if (sample.elapsedMs < HEALTH_WINDOW_MS) return YlRecoveryAction.None
        val totalFrames = sample.droppedFrames + sample.estimatedRenderedFrames
        val dropRatio = if (totalFrames > 0) sample.droppedFrames.toDouble() / totalFrames else 0.0
        val unhealthy = sample.droppedFrames > 60 ||
            dropRatio > 0.05 ||
            sample.rebufferCount >= 2 ||
            sample.rebufferDurationMs > 3_000
        if (!unhealthy) {
            consecutiveUnhealthyWindows = 0
            return YlRecoveryAction.None
        }
        consecutiveUnhealthyWindows += 1
        if (consecutiveUnhealthyWindows < 2 || !downgradeCooldownElapsed(sample.nowMs)) {
            return YlRecoveryAction.None
        }
        consecutiveUnhealthyWindows = 0
        return downgradeOrFail(sample)
    }

    private fun downgradeOrFail(sample: YlHealthSample): YlRecoveryAction {
        if (!sample.canDowngrade) {
            return YlRecoveryAction.Fail(stableError(YlPlaybackFailure.CAPABILITY_EXCEEDED))
        }
        if (!downgradeCooldownElapsed(sample.nowMs)) return YlRecoveryAction.None
        lastDowngradeMs = sample.nowMs
        return YlRecoveryAction.DowngradeOneStep
    }

    private fun downgradeCooldownElapsed(nowMs: Long): Boolean =
        lastDowngradeMs?.let { nowMs - it >= DOWNGRADE_COOLDOWN_MS } ?: true

    private fun canSeekLiveEdge(nowMs: Long): Boolean =
        lastLiveEdgeSeekMs?.let { nowMs - it >= LIVE_EDGE_SEEK_COOLDOWN_MS } ?: true

    private companion object {
        const val HEALTH_WINDOW_MS = 30_000L
        const val DOWNGRADE_COOLDOWN_MS = 60_000L
        const val LIVE_EDGE_SEEK_COOLDOWN_MS = 30_000L
        const val LIVE_RECOVERY_MARGIN_MS = 3_000L
    }
}
