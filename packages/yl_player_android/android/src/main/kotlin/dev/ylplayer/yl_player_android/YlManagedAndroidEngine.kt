package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.AndroidLivePlaybackMode

import android.os.SystemClock
import dev.ylplayer.yl_player_android.pigeon.AndroidEngine
import dev.ylplayer.yl_player_android.pigeon.AndroidVideoConstraintsMessage
import dev.ylplayer.yl_player_android.pigeon.AndroidVideoSelectionMessage
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
    private val allowFallback: Boolean = true,
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
    private var videoSelection = AndroidVideoSelectionMessage(reason = "initial")
    private val fixedVideo get() = videoSelection.fixedTrackId != null
    override val presentationIdentity get() = current.presentationIdentity
    override val supportsVideoTrackSelection get() = current.supportsVideoTrackSelection
    private var constraints: AndroidVideoConstraintsMessage? = null
    override val needsExclusiveLease: Boolean get() = current.needsExclusiveLease

    init { bind(primary) }

    private fun bind(engine: YlPlaybackEngineAdapter) {
        engine.registerCallback { eventIdentity, event ->
            if (closed || eventIdentity != identity || engine !== current) return@registerCallback
            val forwarded = if (event is YlEngineEvent.Snapshot) {
                positionMs = event.value.timeline.positionMs
                val incoming = event.value.videoSelection
                // Backend replacement stays in this session. A fallback that cannot select video
                // reports only its default initial state, not a new accepted selection intent.
                if (!fallbackAttempted || incoming.fixedTrackId != null || incoming.reason != "initial") {
                    videoSelection = incoming
                }
                event.copy(value = event.value.copy(videoSelection = videoSelection))
            } else event
            if (event is YlEngineEvent.Failed && !fixedVideo && current.presentationIdentity == null && allowFallback && YlFallbackRoutingPolicy.shouldFallback(event.kind, fallbackAttempted)) {
                val activeOutput = output
                if (activeOutput != null) scope.launch {
                    runCatching { switchToFallback(activeOutput) }
                        .onFailure { callback?.invoke(identity, YlEngineEvent.Failed(failureKind(it))) }
                }
                return@registerCallback
            }
            callback?.invoke(identity, forwarded)
        }
    }

    override fun registerCallback(callback: (YlSessionIdentity, YlEngineEvent) -> Unit) { this.callback = callback }
    override fun markCommitted() { current.markCommitted() }
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
        !fixedVideo && current.presentationIdentity == null && allowFallback && (error as? YlBoundaryException)?.kind?.let { YlFallbackRoutingPolicy.shouldFallback(it, fallbackAttempted) } == true

    private suspend fun switchToFallback(output: YlSessionVideoOutput) = switchLock.withLock {
        if (current.presentationIdentity != null) throw YlBoundaryException(YlFailureKind.DRM_PROTECTION_INSUFFICIENT)
        if (fixedVideo) throw YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED)
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
    override suspend fun quiesce(): YlEngineRestorePoint = current.quiesce().let { point ->
        if (fallbackAttempted && point.videoSelection == YlFixedVideoState()) {
            point.copy(videoSelection = YlFixedVideoState(reason = videoSelection.reason))
        } else point
    }.also { remember(it) }
    override suspend fun restore(point: YlEngineRestorePoint, output: YlSessionVideoOutput) {
        this.output = output; remember(point); current.restore(point, output)
    }
    private fun remember(point: YlEngineRestorePoint) {
        videoSelection = point.videoSelection.message()
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
    override suspend fun selectVideoTrack(trackId: String?) = switchLock.withLock {
        current.selectVideoTrack(trackId)
        videoSelection = AndroidVideoSelectionMessage(trackId, "user")
    }
    override suspend fun setVideoConstraints(constraints: AndroidVideoConstraintsMessage) {
        current.setVideoConstraints(constraints)
        this.constraints = constraints
    }
    override suspend fun setLivePlaybackMode(mode: AndroidLivePlaybackMode, requestId: Long) =
        current.setLivePlaybackMode(mode, requestId)
    override suspend fun setVolume(volume: Double) { this.volume = volume; current.setVolume(volume) }
    override suspend fun stop() {
        playing = false
        videoSelection = AndroidVideoSelectionMessage(reason = "initial")
        current.stop()
    }
    override suspend fun onForeground() = current.onForeground()
    override suspend fun onBackground() = current.onBackground()
    override suspend fun onTrimMemory(level: Int) = current.onTrimMemory(level)
    override suspend fun onConfigurationChanged() = current.onConfigurationChanged()
    override fun dispose(): Deferred<Unit> {
        closeResult?.let { return it }
        closed = true; callback = null
        return scope.async {
            // Start every borrower release, then await all acknowledgements even when
            // one fails. A safe exceptional close must not abandon another borrower.
            val releases = owned.map { runCatching { it.dispose() } }
            val failures = releases.map { release ->
                runCatching { release.getOrThrow().await() }.exceptionOrNull()
            }
            failures.firstOrNull { it != null }?.let { throw it }
            Unit
        }.also { result ->
            closeResult = result
            // Cancelling our parent inside async cancels this very acknowledgement,
            // turning successful Stop into load.cancelled. Retire after it settles.
            result.invokeOnCompletion { scope.cancel() }
        }
    }
}
