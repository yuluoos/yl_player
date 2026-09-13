package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import kotlinx.coroutines.Deferred

internal data class YlSessionIdentity(val sessionId: String, val loadRequestId: String)
internal data class YlOutputIdentity(val generation: Long, val isPublic: Boolean)
/** Main-owned public output. Engines borrow it until safe dispose acknowledgement. */
internal interface YlSessionVideoOutput {
    val identity: YlOutputIdentity
    fun release()
}
internal data class YlEngineRestorePoint(val positionMs: Long, val liveEdge: Boolean, val playbackIntended: Boolean,
    val selectedAudioTrack: String? = null, val selectedVideoTracks: List<String> = emptyList(),
    val speed: Double = 1.0, val volume: Double = 1.0,
    val maxWidth: Long? = null, val maxHeight: Long? = null, val maxBitrate: Long? = null)
internal enum class YlDecoderRequirement { DEFAULT, PREFERRED, HARDWARE_REQUIRED }
internal data class YlPreparedSession(
    val identity: YlSessionIdentity,
    val source: AndroidSourceMessage,
    val options: AndroidLoadOptionsMessage,
    val engine: YlPlaybackEngineAdapter,
    val decoderRequirement: YlDecoderRequirement,
) { val sessionId get() = identity.sessionId }

/** All suspend operations acknowledge actual worker completion. No synchronous player access. */
internal interface YlPlaybackEngineAdapter {
    /** Unknown media is conservatively exclusive until READY proves audio-only. */
    val needsExclusiveLease: Boolean get() = true
    fun registerCallback(callback: (YlSessionIdentity, YlEngineEvent) -> Unit)
    suspend fun prepare()
    suspend fun activate(output: YlSessionVideoOutput)
    suspend fun quiesce(): YlEngineRestorePoint
    suspend fun restore(point: YlEngineRestorePoint, output: YlSessionVideoOutput)
    suspend fun play()
    suspend fun pause()
    suspend fun pauseForAudioFocus() = pause()
    suspend fun seekTo(positionMs: Long)
    suspend fun seekToLiveEdge()
    suspend fun setPlaybackSpeed(speed: Double)
    suspend fun selectAudioTrack(trackId: String)
    suspend fun setVideoConstraints(constraints: AndroidVideoConstraintsMessage)
    suspend fun setVolume(volume: Double)
    suspend fun stop()
    /** Pending means native resources may still reference the borrowed output. Never cancel it. */
    fun dispose(): Deferred<Unit>
    suspend fun onForeground()
    suspend fun onBackground()
    suspend fun onTrimMemory(level: Int)
    suspend fun onConfigurationChanged()
}
internal fun interface YlPlaybackEngineFactory {
    fun create(identity: YlSessionIdentity, source: AndroidSourceMessage, options: AndroidLoadOptionsMessage): YlPlaybackEngineAdapter
}
internal data class YlEngineSnapshot(
    val status: AndroidPlaybackStatus = AndroidPlaybackStatus.LOADING,
    val timeline: AndroidTimelineMessage = emptyTimeline(),
    val geometry: AndroidVideoGeometryMessage? = null,
    val audioTracks: List<AndroidTrackMessage> = emptyList(),
    val videoTracks: List<AndroidTrackMessage> = emptyList(),
    val decoderMode: AndroidDecoderMode = AndroidDecoderMode.UNKNOWN,
    val decoderIdentity: String? = null,
    val metrics: AndroidMetricsMessage = AndroidMetricsMessage(),
    val reachedReady: Boolean = false,
)
internal sealed interface YlEngineEvent {
    data class Snapshot(val value: YlEngineSnapshot) : YlEngineEvent
    data class Tick(val timeline: AndroidTimelineMessage, val metrics: AndroidMetricsMessage) : YlEngineEvent
    data class FirstFrame(val output: YlOutputIdentity, val occurredAtMs: Long) : YlEngineEvent
    data class Failed(val kind: YlFailureKind) : YlEngineEvent
    data class Retry(val index: Long, val delayMs: Long, val occurredAtMs: Long) : YlEngineEvent
    data class BackendChanged(val previous: AndroidEngine, val current: AndroidEngine, val occurredAtMs: Long) : YlEngineEvent
}
internal fun emptyTimeline() = AndroidTimelineMessage(0, bufferedPositionMs = 0, isSeekable = false, isLive = false)
