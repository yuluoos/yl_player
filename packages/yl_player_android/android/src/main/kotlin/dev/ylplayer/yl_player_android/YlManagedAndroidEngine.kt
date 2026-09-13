package dev.ylplayer.yl_player_android

import android.os.SystemClock
import dev.ylplayer.yl_player_android.pigeon.AndroidEngine
import dev.ylplayer.yl_player_android.pigeon.AndroidVideoConstraintsMessage
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Owns one Media3 attempt and, for backend-recoverable failures only, one native attempt. */
internal class YlManagedAndroidEngine(
    private val identity: YlSessionIdentity,
    primary: YlPlaybackEngineAdapter,
    private val createFallback: () -> YlPlaybackEngineAdapter,
    dispatcher: CoroutineDispatcher = Dispatchers.Main,
    private val clockMs: () -> Long = SystemClock::elapsedRealtime,
) : YlPlaybackEngineAdapter {
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val switchLock = Mutex()
    private val owned = linkedSetOf(primary)
    private var current = primary
    private var callback: ((YlSessionIdentity, YlEngineEvent) -> Unit)? = null
    private var output: YlSessionVideoOutput? = null
    private var fallbackAttempted = false
    private var closed = false
    private var closeResult: Deferred<Unit>? = null
    private var playing = false
    private var positionMs = 0L
    private var liveEdge = false
    private var speed = 1.0
    private var volume = 1.0
    private var audioTrack: String? = null
    private var constraints: AndroidVideoConstraintsMessage? = null
    override val needsExclusiveLease: Boolean get() = current.needsExclusiveLease

    init { bind(primary) }

    private fun bind(engine: YlPlaybackEngineAdapter) {
        engine.registerCallback { eventIdentity, event ->
            if (closed || eventIdentity != identity || engine !== current) return@registerCallback
            if (event is YlEngineEvent.Snapshot) positionMs = event.value.timeline.positionMs
            if (event is YlEngineEvent.Failed && YlFallbackRoutingPolicy.shouldFallback(event.kind, fallbackAttempted)) {
                val activeOutput = output
                if (activeOutput != null) scope.launch {
                    runCatching { switchToFallback(activeOutput) }
                        .onFailure { callback?.invoke(identity, YlEngineEvent.Failed(failureKind(it))) }
                }
                return@registerCallback
            }
            callback?.invoke(identity, event)
        }
    }

    override fun registerCallback(callback: (YlSessionIdentity, YlEngineEvent) -> Unit) { this.callback = callback }
    override suspend fun prepare() {
        try { current.prepare() }
        catch (error: Throwable) {
            if (!shouldFallback(error)) throw error
            val fallback = installFallback()
            fallback.prepare()
            notifyBackendChanged()
        }
    }
    override suspend fun activate(output: YlSessionVideoOutput) {
        this.output = output
        try { current.activate(output) }
        catch (error: Throwable) {
            if (!shouldFallback(error)) throw error
            switchToFallback(output)
        }
    }

    private fun shouldFallback(error: Throwable): Boolean =
        (error as? YlBoundaryException)?.kind?.let { YlFallbackRoutingPolicy.shouldFallback(it, fallbackAttempted) } == true

    private suspend fun switchToFallback(output: YlSessionVideoOutput) = switchLock.withLock {
        if (fallbackAttempted) return@withLock
        val previous = current
        val fallback = installFallback()
        runCatching { previous.quiesce() }
        runCatching { previous.stop() }
        fallback.prepare()
        fallback.activate(output)
        constraints?.let { fallback.setVideoConstraints(it) }
        fallback.setPlaybackSpeed(speed)
        fallback.setVolume(volume)
        if (liveEdge) runCatching { fallback.seekToLiveEdge() } else if (positionMs > 0) fallback.seekTo(positionMs)
        audioTrack?.takeIf { it.startsWith("ffmpeg-audio-") }?.let { fallback.selectAudioTrack(it) }
        if (playing) fallback.play() else fallback.pause()
        notifyBackendChanged()
        previous.dispose()
    }

    private fun notifyBackendChanged() {
        callback?.invoke(
            identity,
            YlEngineEvent.BackendChanged(
                AndroidEngine.MEDIA3,
                AndroidEngine.MANAGED_FALLBACK,
                clockMs(),
            ),
        )
    }

    private fun installFallback(): YlPlaybackEngineAdapter {
        fallbackAttempted = true
        return createFallback().also { fallback -> owned += fallback; current = fallback; bind(fallback) }
    }

    private fun failureKind(error: Throwable) = (error as? YlBoundaryException)?.kind ?: YlFailureKind.PLATFORM_FAILURE
    override suspend fun quiesce(): YlEngineRestorePoint = current.quiesce().also { remember(it) }
    override suspend fun restore(point: YlEngineRestorePoint, output: YlSessionVideoOutput) {
        this.output = output; remember(point); current.restore(point, output)
    }
    private fun remember(point: YlEngineRestorePoint) {
        positionMs = point.positionMs; liveEdge = point.liveEdge; playing = point.playbackIntended
        speed = point.speed; volume = point.volume; audioTrack = point.selectedAudioTrack
        constraints = AndroidVideoConstraintsMessage(point.maxWidth, point.maxHeight, point.maxBitrate)
    }
    override suspend fun play() { playing = true; current.play() }
    override suspend fun pause() { playing = false; current.pause() }
    override suspend fun pauseForAudioFocus() { playing = false; current.pauseForAudioFocus() }
    override suspend fun seekTo(positionMs: Long) { this.positionMs = positionMs; liveEdge = false; current.seekTo(positionMs) }
    override suspend fun seekToLiveEdge() { liveEdge = true; current.seekToLiveEdge() }
    override suspend fun setPlaybackSpeed(speed: Double) { this.speed = speed; current.setPlaybackSpeed(speed) }
    override suspend fun selectAudioTrack(trackId: String) { audioTrack = trackId; current.selectAudioTrack(trackId) }
    override suspend fun setVideoConstraints(constraints: AndroidVideoConstraintsMessage) { this.constraints = constraints; current.setVideoConstraints(constraints) }
    override suspend fun setVolume(volume: Double) { this.volume = volume; current.setVolume(volume) }
    override suspend fun stop() { playing = false; current.stop() }
    override suspend fun onForeground() = current.onForeground()
    override suspend fun onBackground() = current.onBackground()
    override suspend fun onTrimMemory(level: Int) = current.onTrimMemory(level)
    override suspend fun onConfigurationChanged() = current.onConfigurationChanged()
    override fun dispose(): Deferred<Unit> {
        closeResult?.let { return it }
        closed = true; callback = null
        return scope.async {
            owned.map { it.dispose() }.forEach { it.await() }
            scope.cancel()
        }.also { closeResult = it }
    }
}
