package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import kotlinx.coroutines.*

/** Reducer ingress. Called on the main looper with the identity of the original event. */
internal interface YlPlayerEventSink {
    fun onState(state: AndroidStateMessage)
    fun onStateDelta(delta: AndroidStateDeltaMessage)
    fun onFirstFrame(event: AndroidFirstFrameMessage)
    fun onRetryScheduled(event: AndroidRetryScheduledMessage)
    fun onEngineChanged(event: AndroidEngineChangedMessage)
    fun onPlaybackFailed(event: AndroidPlaybackFailedMessage)
}

/** Each method completes only when Flutter acknowledges that exact invocation. */
internal interface YlPlayerCallbacks {
    suspend fun onState(state: AndroidStateMessage)
    suspend fun onStateDelta(delta: AndroidStateDeltaMessage)
    suspend fun onFirstFrame(event: AndroidFirstFrameMessage)
    suspend fun onRetryScheduled(event: AndroidRetryScheduledMessage)
    suspend fun onEngineChanged(event: AndroidEngineChangedMessage)
    suspend fun onPlaybackFailed(event: AndroidPlaybackFailedMessage)
}

internal class YlPigeonCallbacks(private val api: AndroidPlayerFlutterApi) : YlPlayerCallbacks {
    override suspend fun onState(state: AndroidStateMessage) = api.onState(state)
    override suspend fun onStateDelta(delta: AndroidStateDeltaMessage) = api.onStateDelta(delta)
    override suspend fun onFirstFrame(event: AndroidFirstFrameMessage) = api.onFirstFrame(event)
    override suspend fun onRetryScheduled(event: AndroidRetryScheduledMessage) = api.onRetryScheduled(event)
    override suspend fun onEngineChanged(event: AndroidEngineChangedMessage) = api.onEngineChanged(event)
    override suspend fun onPlaybackFailed(event: AndroidPlaybackFailedMessage) = api.onPlaybackFailed(event)
}

/** One main-looper FIFO across every method. No state coalescing or skipped milestones. */
internal class YlCallbackDispatcher(
    private val callbacks: YlPlayerCallbacks,
    dispatcher: CoroutineDispatcher = Dispatchers.Main,
    private val onFailure: (Throwable) -> Unit,
) : YlPlayerEventSink {
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val queue = ArrayDeque<suspend () -> Unit>()
    private var attached = false
    private var closed = false
    private var draining = false
    private var generation = 0L

    fun attach() {
        if (closed || attached) return
        attached = true
        drain()
    }

    fun close() {
        if (closed) return
        closed = true
        generation++
        queue.clear()
        scope.cancel()
    }

    override fun onState(state: AndroidStateMessage) {
        // Generated DTO fields are vals, but List can be backed by a mutable caller list.
        val snapshot = state.copy(audioTracks = state.audioTracks.toList(), videoTracks = state.videoTracks.toList())
        enqueue { callbacks.onState(snapshot) }
    }
    override fun onStateDelta(delta: AndroidStateDeltaMessage) = enqueue { callbacks.onStateDelta(delta) }
    override fun onFirstFrame(event: AndroidFirstFrameMessage) = enqueue { callbacks.onFirstFrame(event) }
    override fun onRetryScheduled(event: AndroidRetryScheduledMessage) = enqueue { callbacks.onRetryScheduled(event) }
    override fun onEngineChanged(event: AndroidEngineChangedMessage) = enqueue { callbacks.onEngineChanged(event) }
    override fun onPlaybackFailed(event: AndroidPlaybackFailedMessage) = enqueue { callbacks.onPlaybackFailed(event) }

    private fun enqueue(deliver: suspend () -> Unit) {
        if (closed) return
        queue.addLast(deliver)
        drain()
    }

    private fun drain() {
        if (!attached || closed || draining || queue.isEmpty()) return
        draining = true
        val token = generation
        scope.launch {
            try {
                while (!closed && token == generation && queue.isNotEmpty()) {
                    val next = queue.removeFirst()
                    withTimeout(5_000) { next() }
                    // Even an inline acknowledgement cannot reenter the next callback.
                    // Dispatchers.Main (not Main.immediate) posts this continuation to the looper.
                    yield()
                }
            } catch (error: Throwable) {
                if (!closed && token == generation) {
                    close()
                    onFailure(error)
                }
            } finally {
                draining = false
            }
        }
    }
}
