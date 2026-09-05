package dev.ylplayer.yl_player_android

internal class YlPlaybackStallWatchdog(
    private val schedule: (Long, () -> Unit) -> Unit,
) {
    private enum class Phase(val wireName: String) {
        FIRST_FRAME("firstFrame"),
        REBUFFER("rebuffer"),
    }

    private var generation = 0L
    private var armedPhase: Phase? = null

    fun update(
        active: Boolean,
        wantsToPlay: Boolean,
        hasCurrentItem: Boolean,
        isBuffering: Boolean,
        firstFrameRendered: Boolean,
        timeoutMs: Long,
        playbackState: String,
        onTimeout: (YlStableError, String) -> Unit,
    ) {
        if (!active || !wantsToPlay || !hasCurrentItem) {
            cancel()
            return
        }

        val phase: Phase
        val error: YlStableError
        if (!firstFrameRendered) {
            phase = Phase.FIRST_FRAME
            error = YlStableError(
                category = "network",
                code = "media3.first_frame_timeout",
                message = "Media3 did not render the first frame before the read timeout.",
            )
        } else if (isBuffering) {
            phase = Phase.REBUFFER
            error = YlStableError(
                category = "network",
                code = "media3.stall_timeout",
                message = "Media3 remained stalled beyond the read timeout.",
            )
        } else {
            cancel()
            return
        }
        if (armedPhase == phase) return

        generation += 1
        val scheduledGeneration = generation
        armedPhase = phase

        val timeout = timeoutMs.coerceAtLeast(0L)
        val diagnostic =
            "Media3(phase=${phase.wireName}, timeoutMs=$timeout, state=$playbackState)"
        schedule(timeout) {
            if (generation == scheduledGeneration) {
                armedPhase = null
                onTimeout(error, diagnostic)
            }
        }
    }

    fun cancel() {
        generation += 1
        armedPhase = null
    }
}
