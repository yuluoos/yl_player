package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import android.os.SystemClock

/** Main-owned sole author of revisions and the overall callback sequence. */
internal class YlStateReducer(
    private var events: YlPlayerEventSink? = null,
    private val clockMs: () -> Long = SystemClock::elapsedRealtime,
) {
    private var revision = 0L
    private var sequence = 0L
    private var reachedReady = false
    private var sentFrame = false
    private var terminal = false
    private var output: YlOutputIdentity? = null
    private val failures = YlFailureMapper()
    var state = idleState()
        private set
    fun attach(events: YlPlayerEventSink) { this.events = events }
    private fun idleState() = AndroidStateMessage(revision = revision, sequence = sequence,
        status = AndroidPlaybackStatus.IDLE, timeline = emptyTimeline(), audioTracks = emptyList(),
        videoTracks = emptyList(), engine = AndroidEngine.UNKNOWN, decoderMode = AndroidDecoderMode.UNKNOWN,
        metrics = AndroidMetricsMessage())
    fun commit(identity: YlSessionIdentity, output: YlOutputIdentity) {
        reachedReady = false; sentFrame = false; terminal = false; this.output = output
        publish(idleState().copy(sessionId = identity.sessionId, loadRequestId = identity.loadRequestId,
            status = AndroidPlaybackStatus.LOADING, engine = AndroidEngine.MEDIA3))
    }
    fun idle() { output = null; terminal = false; publish(idleState()) }
    fun snapshot(snapshot: YlEngineSnapshot) {
        if (state.sessionId == null || terminal) return
        if (snapshot.reachedReady || snapshot.status in listOf(AndroidPlaybackStatus.READY, AndroidPlaybackStatus.PLAYING)) reachedReady = true
        val status = if (snapshot.status == AndroidPlaybackStatus.BUFFERING && !reachedReady) AndroidPlaybackStatus.LOADING else snapshot.status
        val next = state.copy(status = status, timeline = snapshot.timeline, geometry = snapshot.geometry,
            audioTracks = snapshot.audioTracks.toList(), videoTracks = snapshot.videoTracks.toList(),
            decoderMode = snapshot.decoderMode, decoderIdentity = snapshot.decoderIdentity, metrics = snapshot.metrics)
        if (next != state) {
            if (next.copy(timeline = state.timeline, metrics = state.metrics) != state ||
                timelineMetadataChanged(next.timeline)) publish(next)
            else tick(next.timeline, next.metrics)
        }
    }
    fun tick(timeline: AndroidTimelineMessage, metrics: AndroidMetricsMessage) {
        val id = state.sessionId ?: return
        if (terminal) return
        if (timelineMetadataChanged(timeline)) {
            publish(state.copy(timeline = timeline, metrics = metrics))
            return
        }
        val previous = revision
        revision++; sequence++
        state = state.copy(revision = revision, sequence = sequence, timeline = timeline, metrics = metrics)
        events?.onStateDelta(AndroidStateDeltaMessage(id, previous, revision, sequence,
            positionMs = timeline.positionMs, bufferedPositionMs = timeline.bufferedPositionMs,
            hasIsAtLiveEdge = true, isAtLiveEdge = timeline.isAtLiveEdge,
            hasLiveOffsetMs = true, liveOffsetMs = timeline.liveOffsetMs,
            metrics = metrics.asDelta()))
    }
    private fun timelineMetadataChanged(timeline: AndroidTimelineMessage): Boolean =
        timeline.copy(positionMs = state.timeline.positionMs,
            bufferedPositionMs = state.timeline.bufferedPositionMs,
            isAtLiveEdge = state.timeline.isAtLiveEdge, liveOffsetMs = state.timeline.liveOffsetMs) != state.timeline
    fun pauseForLifecycle() {
        if (state.sessionId != null && !terminal && state.status !in listOf(AndroidPlaybackStatus.PAUSED, AndroidPlaybackStatus.COMPLETED)) {
            publish(state.copy(status = AndroidPlaybackStatus.PAUSED))
        }
    }
    fun updateOutput(output: YlOutputIdentity) { this.output = output }
    fun firstFrame(output: YlOutputIdentity, occurredAtMs: Long) {
        val id = state.sessionId ?: return
        if (terminal || sentFrame || !output.isPublic || output != this.output) return
        sentFrame = true
        events?.onFirstFrame(AndroidFirstFrameMessage(id, revision, ++sequence, occurredAtMs))
    }
    fun fail(kind: YlFailureKind) {
        val id = state.sessionId ?: return
        if (terminal) return
        terminal = true
        val failure = failures.toMessage(YlBoundaryException(kind), AndroidFailureScope.SESSION)
        publish(state.copy(status = AndroidPlaybackStatus.FAILED, failure = failure))
        events?.onPlaybackFailed(AndroidPlaybackFailedMessage(id, revision, ++sequence, clockMs(), failure))
    }
    fun retry(event: YlEngineEvent.Retry) {
        val id = state.sessionId ?: return
        if (terminal) return
        val failure = failures.toMessage(YlBoundaryException(YlFailureKind.NETWORK_FAILED), AndroidFailureScope.SESSION)
        events?.onRetryScheduled(AndroidRetryScheduledMessage(id, revision, ++sequence, event.occurredAtMs, event.index, event.delayMs, failure))
    }
    private fun publish(next: AndroidStateMessage) {
        state = next.copy(revision = ++revision, sequence = ++sequence)
        events?.onState(state)
    }
}
private fun AndroidMetricsMessage.asDelta() = AndroidMetricsDeltaMessage(
    true, loadToReadyMs, true, loadToFirstFrameMs, true, rebufferCount, true, rebufferDurationMs,
    true, droppedVideoFrames, true, audioUnderruns, true, estimatedBitrate,
    true, managedBufferedDurationMs, true, managedBufferedBytes, true, liveOffsetMs, true, reconnectCount)
