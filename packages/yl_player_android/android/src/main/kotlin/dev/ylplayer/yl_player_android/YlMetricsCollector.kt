package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.AndroidMetricsMessage

/** Worker-owned measured signals. Each snapshot is immutable; absent observations stay unknown. */
internal class YlMetricsCollector {
    private var values = AndroidMetricsMessage()
    private var loadStarted: Long? = null
    private var bufferingStarted: Long? = null
    fun start(atMs: Long, managedRetries: Boolean) {
        values = AndroidMetricsMessage(reconnectCount = if (managedRetries) 0 else null)
        loadStarted = atMs
        bufferingStarted = null
    }
    fun ready(atMs: Long) {
        endBuffering(atMs)
        if (values.loadToReadyMs == null) values = values.copy(
            loadToReadyMs = loadStarted?.let { (atMs - it).coerceAtLeast(0) },
            rebufferCount = 0, rebufferDurationMs = 0)
    }
    fun buffering(atMs: Long) {
        if (values.loadToReadyMs == null || bufferingStarted != null) return
        bufferingStarted = atMs
        values = values.copy(rebufferCount = (values.rebufferCount ?: 0) + 1)
    }
    fun endBuffering(atMs: Long) {
        bufferingStarted?.let { values = values.copy(rebufferDurationMs = (values.rebufferDurationMs ?: 0) + (atMs - it).coerceAtLeast(0)) }
        bufferingStarted = null
    }
    fun firstFrame(atMs: Long) {
        if (values.loadToFirstFrameMs == null) values = values.copy(loadToFirstFrameMs = loadStarted?.let { (atMs - it).coerceAtLeast(0) })
    }
    fun videoEnabled() { if (values.droppedVideoFrames == null) values = values.copy(droppedVideoFrames = 0) }
    fun audioEnabled() { if (values.audioUnderruns == null) values = values.copy(audioUnderruns = 0) }
    fun dropped(count: Int) { if (count >= 0) values = values.copy(droppedVideoFrames = (values.droppedVideoFrames ?: 0) + count) }
    fun underrun() { values = values.copy(audioUnderruns = (values.audioUnderruns ?: 0) + 1) }
    fun bandwidth(bitrate: Long) { if (bitrate >= 0) values = values.copy(estimatedBitrate = bitrate) }
    fun retry() { values = values.copy(reconnectCount = (values.reconnectCount ?: 0) + 1) }
    fun snapshot(atMs: Long, bufferedDurationMs: Long? = null, liveOffsetMs: Long? = null) = values.copy(
        rebufferDurationMs = bufferingStarted?.let { (values.rebufferDurationMs ?: 0) + (atMs - it).coerceAtLeast(0) } ?: values.rebufferDurationMs,
        managedBufferedDurationMs = bufferedDurationMs?.coerceAtLeast(0),
        // Media3 allocator bytes do not measure a managed byte budget.
        managedBufferedBytes = null, liveOffsetMs = liveOffsetMs)
}
