package dev.ylplayer.yl_player_android

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.Timeline
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import dev.ylplayer.yl_player_android.pigeon.*
import android.view.Surface
import kotlin.math.max
import kotlin.math.roundToInt

@OptIn(UnstableApi::class)
internal class YlMedia3Core(
    private val context: Context,
    private val identity: YlSessionIdentity,
    private val source: AndroidSourceMessage,
    private val loadOptions: AndroidLoadOptionsMessage,
    private val configuration: PlayerConfiguration,
    private val handler: Handler,
    private val videoOutput: YlEngineVideoOutput,
    private val emit: (YlEngineEvent) -> Unit,
) : Player.Listener, AnalyticsListener {
    // Entire class, including construction, lives on the owned engine application Looper.
    private val acknowledgement = YlMedia3Acknowledgement()
    private var lastFailure: YlFailureKind? = null
    private val lifecycle = YlLifecycleCoordinator()
    private val deviceProfile = YlAndroidDeviceProfile.collect(context)
    private val trackSelector = DefaultTrackSelector(context)
    private val decoderPolicy = AndroidDecoderPolicy.valueOf(configuration.decoderPolicy)
    private val decoderEvidence = YlDecoderEvidenceProvider.collect()
    private val managedNetwork = source.networkPolicy?.kind == AndroidNetworkPolicyKind.MANAGED
    private var inspectingDecoder = false
    private val sourceFactory = YlMediaSourceFactory(source, configuration.network) { attempt, delayMs ->
        val occurredAtMs = SystemClock.elapsedRealtime()
        handler.post { if (!disposed && !stopped) recordRetry(attempt, delayMs, occurredAtMs) }
    }
    private val loadControl = YlAdaptiveLoadControl(
        YlPlaybackPolicy.effectiveBufferProfile(
            deviceProfile.tier,
            YlSourceClass.NETWORK_VOD,
            configuration.bufferRequest(),
        ),
    )
    private lateinit var exoPlayer: ExoPlayer
    private val audioSelections = mutableMapOf<String, AudioSelection>()
    private var sourceIsLive = false
    private var sourceClass = YlSourceClass.NETWORK_VOD
    private var stopped = false
    private var resetting = false
    private var disposed = false
    private var status = "idle"
    private var metricsCollector = YlMetricsCollector()
    private var hasBeenReady = false
    private var rebufferCount = 0
    private var bufferingStartedAtMs: Long? = null
    private var rebufferDurationMs = 0L
    private var reconnectCount = 0
    private var droppedVideoFrames = 0
    private var audioUnderruns = 0
    private var decoderName: String? = null
    private var decoderAttemptStartedAtMs = Long.MAX_VALUE
    private var isHardwareDecoding = false
    private var hostQualityConstraint = AndroidQualityConstraint()
    private var adaptiveBitrateCeiling: Int? = null
    private var decoderRetryCount = 0
    private var adaptiveDowngradeCount = 0
    private var selectedVideoBitrate: Int? = null
    private var availableVideoBitrates: List<Int> = emptyList()
    private var selectedVideoFrameRate = 30f
    private var surfaceRebuildBaseline = 0
    private var requestedPlaybackSpeed = 1f
    private val healthMonitor = YlPlaybackHealthMonitor()
    private var healthWindowStartedAtMs: Long? = null
    private var healthWindowDroppedFrames = 0
    private var healthWindowRebufferCount = 0
    private var healthWindowRebufferDurationMs = 0L
    private var lastHealthEvaluationMs = 0L
    private val focusGraceRunnable = Runnable {
        if (lifecycle.reduce(YlLifecycleEvent.FOCUS_GRACE_EXPIRED) == YlLifecycleAction.RELEASE_AND_SAVE) {
            releasePlaybackResources()
        }
    }
    private var currentError: YlFailureKind? = null
    private var active = false
    private var savedPositionMs = 0L
    private var resumeAtLiveEdge = false
    private var sourceGeneration = 0L
    private var firstFrameRendered = false
    private val stallWatchdog = YlPlaybackStallWatchdog { delayMs, action ->
        handler.postDelayed(action, delayMs)
    }
    private var lastVideoSize = VideoSize.UNKNOWN
    private var audioTracks: List<AndroidTrackMessage> = emptyList()
    private var videoTracks: List<AndroidTrackMessage> = emptyList()
    private val positionTicker = object : Runnable {
        override fun run() {
            if (!disposed && active && !stopped) {
                maybeEvaluateHealth()
                emitPositionDelta()
                handler.postDelayed(this, configuration.positionEventIntervalMs)
            }
        }
    }

    fun initialize() {
        val renderersFactory = DefaultRenderersFactory(context)
            .setEnableDecoderFallback(true)
            .setMediaCodecSelector(YlPolicyCodecSelector(decoderPolicy, evidence = decoderEvidence))
        exoPlayer = ExoPlayer.Builder(context, renderersFactory)
            .setLooper(handler.looper)
            .setTrackSelector(trackSelector)
            .setLoadControl(loadControl)
            .build()
        exoPlayer.addListener(this)
        exoPlayer.addAnalyticsListener(this)
        exoPlayer.setForegroundMode(true)
        exoPlayer.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(),
            false,
        )
        exoPlayer.setHandleAudioBecomingNoisy(false)
        exoPlayer.setWakeMode(C.WAKE_MODE_NETWORK)
        applyTrackConstraints()
        videoOutput.attach(sourceGeneration, sourceGeneration, ::attachSurface)
    }

    fun play() {
        cancelFocusGrace(); lifecycle.reduce(YlLifecycleEvent.USER_PLAY)
        if (!active) activate()
        exoPlayer.play(); refreshStallWatchdog()
    }
    fun pause() {
        cancelFocusGrace(); lifecycle.reduce(YlLifecycleEvent.USER_PAUSE)
        stallWatchdog.cancel(); exoPlayer.pause()
    }
    fun pauseForAudioFocus() {
        if (lifecycle.reduce(YlLifecycleEvent.FOCUS_TRANSIENT_LOSS) != YlLifecycleAction.PAUSE_KEEP_RESOURCES) return
        cancelFocusGrace()
        stallWatchdog.cancel()
        exoPlayer.pause()
        handler.postDelayed(focusGraceRunnable, 3_000L)
    }
    fun seekTo(positionMs: Long) {
        resumeAtLiveEdge = false
        if (active) exoPlayer.seekTo(positionMs) else { savedPositionMs = positionMs; emitState() }
    }
    fun seekToLiveEdge() {
        if (!sourceIsLive && !exoPlayer.isCurrentMediaItemLive) throw YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED)
        if (active) { resumeAtLiveEdge = false; exoPlayer.seekToDefaultPosition() }
        else { resumeAtLiveEdge = true; emitState() }
    }
    fun setPlaybackSpeed(speed: Double) { requestedPlaybackSpeed = speed.toFloat(); exoPlayer.setPlaybackSpeed(requestedPlaybackSpeed) }
    fun setVolume(volume: Double) { exoPlayer.volume = volume.toFloat() }
    fun switchOutput(surface: Surface, output: YlOutputIdentity) { videoOutput.switchTo(surface, output, ::attachSurface); ensureHealthy() }
    fun snapshotRestorePoint() = YlEngineRestorePoint(if (active) max(0L, exoPlayer.currentPosition) else savedPositionMs,
        resumeAtLiveEdge || (normalizedLiveOffset()?.let { it <= 2_000L } == true), lifecycle.state.playbackIntended,
        audioTracks.firstOrNull { it.isSelected }?.id, videoTracks.filter { it.isSelected }.map { it.id },
        requestedPlaybackSpeed.toDouble(), exoPlayer.volume.toDouble(),
        hostQualityConstraint.maxWidth?.toLong(), hostQualityConstraint.maxHeight?.toLong(), hostQualityConstraint.maxBitrate?.toLong())
    fun restore(point: YlEngineRestorePoint) {
        savedPositionMs = point.positionMs; resumeAtLiveEdge = point.liveEdge
        setPlaybackSpeed(point.speed)
        setVolume(point.volume)
        setVideoConstraints(AndroidVideoConstraintsMessage(point.maxWidth, point.maxHeight, point.maxBitrate))
        lifecycle.reduce(if (point.playbackIntended) YlLifecycleEvent.USER_PLAY else YlLifecycleEvent.USER_PAUSE)
        activate()
    }
    fun ensureHealthy() { lastFailure?.let { throw YlBoundaryException(it) } }
    private fun attachSurface(surface: Surface) = outputOperation { exoPlayer.setVideoSurface(surface) }
    private fun clearSurface(surface: Surface) = outputOperation { exoPlayer.clearVideoSurface(surface) }
    private fun outputOperation(action: () -> Unit) {
        val safe = acknowledgement.perform {
            action()
            if (exoPlayer.playerError?.errorCode == PlaybackException.ERROR_CODE_TIMEOUT) acknowledgement.onTimeout()
        }
        if (!safe) throw YlBoundaryException(YlFailureKind.PLATFORM_FAILURE)
    }
    // Keep this observer installed through release; that timeout is a synchronous listener event.
    override fun onPlayerError(error: PlaybackException) {
        if (error.errorCode == PlaybackException.ERROR_CODE_TIMEOUT) acknowledgement.onTimeout()
    }

    fun activate() {
        if (disposed || active || stopped) return
        active = true
        exoPlayer.setForegroundMode(true)
        loadControl.restoreProfile()
        videoOutput.attach(sourceGeneration, sourceGeneration, ::attachSurface)
        if (exoPlayer.currentMediaItem != null && exoPlayer.playbackState == Player.STATE_IDLE) {
            status = "opening"
            prepareDecoder()
            if (resumeAtLiveEdge) {
                exoPlayer.seekToDefaultPosition()
                resumeAtLiveEdge = false
            } else {
                exoPlayer.seekTo(savedPositionMs)
            }
        }
        if (lifecycle.state.playbackIntended) exoPlayer.play() else exoPlayer.pause()
        handler.removeCallbacks(positionTicker)
        handler.post(positionTicker)
        emitState()
        refreshStallWatchdog()
    }

    fun deactivate() {
        if (disposed || !active || stopped) return
        releasePlaybackResources()
    }

    fun releaseForLifecycle() {
        if (disposed) return
        lifecycle.reduce(YlLifecycleEvent.UI_HIDDEN)
        releasePlaybackResources()
    }

    fun restoreAfterForeground() {
        if (disposed) return
        lifecycle.reduce(YlLifecycleEvent.FOREGROUND)
        loadControl.restoreProfile()
        activate()
    }

    fun canRebuildOutput() = !disposed && active && !stopped
    fun detachOutput() { videoOutput.detach(::clearSurface) }
    fun rebuildVideoOutput(surface: Surface, identity: YlOutputIdentity) {
        if (disposed || stopped) return
        if (videoOutput.installReplacement(surface, identity, active, ::attachSurface)) emitState()
    }

    private fun releasePlaybackResources() {
        metricsCollector.endBuffering(SystemClock.elapsedRealtime())
        cancelFocusGrace()
        if (!active) return
        stallWatchdog.cancel()
        savedPositionMs = max(0L, exoPlayer.currentPosition)
        if (normalizedLiveOffset()?.let { it <= 2_000L } == true) {
            resumeAtLiveEdge = true
        }
        bufferingStartedAtMs?.let { rebufferDurationMs += SystemClock.elapsedRealtime() - it }
        bufferingStartedAtMs = null
        active = false
        decoderAttemptStartedAtMs = Long.MAX_VALUE
        decoderName = null
        isHardwareDecoding = false
        handler.removeCallbacks(positionTicker)
        exoPlayer.pause()
        exoPlayer.stop()
        outputOperation { exoPlayer.setForegroundMode(false) }
        videoOutput.detach(::clearSurface)
        if (status != "error" && status != "completed" && status != "idle") {
            status = "paused"
        }
        emitState()
    }

    fun stop() {
        val nextGeneration = sourceGeneration + 1
        resetting = true
        stopped = true
        sourceGeneration = nextGeneration
        lifecycle.reduce(YlLifecycleEvent.USER_PAUSE)
        stallWatchdog.cancel()
        handler.removeCallbacksAndMessages(null)
        sourceFactory.cancelAll()
        firstFrameRendered = false
        sourceIsLive = false
        savedPositionMs = 0L
        resumeAtLiveEdge = false
        active = false
        exoPlayer.pause()
        exoPlayer.stop()
        exoPlayer.clearMediaItems()
        videoOutput.detach(::clearSurface)
        trackSelector.parameters = trackSelector.buildUponParameters().clearOverrides().build()
        metricsCollector = YlMetricsCollector()
        hasBeenReady = false
        rebufferCount = 0
        rebufferDurationMs = 0L
        bufferingStartedAtMs = null
        reconnectCount = 0
        droppedVideoFrames = 0
        audioUnderruns = 0
        decoderName = null
        isHardwareDecoding = false
        decoderRetryCount = 0
        adaptiveDowngradeCount = 0
        adaptiveBitrateCeiling = null
        selectedVideoBitrate = null
        availableVideoBitrates = emptyList()
        selectedVideoFrameRate = 30f
        surfaceRebuildBaseline = videoOutput.surfaceRebuildCount
        healthMonitor.reset()
        healthWindowStartedAtMs = null
        lastHealthEvaluationMs = 0L
        currentError = null
        audioSelections.clear()
        audioTracks = emptyList()
        videoTracks = emptyList()
        lastVideoSize = VideoSize.UNKNOWN
        healthWindowDroppedFrames = 0
        healthWindowRebufferCount = 0
        healthWindowRebufferDurationMs = 0L
        status = "idle"
        resetting = false
        emitState()
    }

    fun prepare() {
        val uriString = source.locator
        val generation = sourceGeneration + 1
        val mediaItem = MediaItem.Builder()
            .setMediaId(identity.sessionId)
            .setUri(Uri.parse(uriString))
            .setMimeType(mediaMimeType(source.format))
            .build()

        val mediaSource = sourceFactory.create(context, mediaItem)
        cancelFocusGrace()
        stallWatchdog.cancel()
        stopped = false
        sourceGeneration = generation
        videoOutput.attach(generation, generation, ::attachSurface)
        handler.removeCallbacks(positionTicker)
        handler.post(positionTicker)
        firstFrameRendered = false
        sourceIsLive = source.intent == AndroidStreamIntent.LIVE
        sourceClass = YlPlaybackPolicy.classifySource(
            kind = source.kind.name.lowercase(),
            isLive = sourceIsLive,
            formatHint = formatHint(source.format),
            uri = uriString,
        )

        active = true
        savedPositionMs = 0
        resumeAtLiveEdge = false

        metricsCollector.start(SystemClock.elapsedRealtime(), managedNetwork)
        hasBeenReady = false
        rebufferCount = 0
        rebufferDurationMs = 0L
        bufferingStartedAtMs = null
        reconnectCount = 0
        droppedVideoFrames = 0
        audioUnderruns = 0
        decoderName = null
        isHardwareDecoding = false
        decoderRetryCount = 0
        adaptiveDowngradeCount = 0
        adaptiveBitrateCeiling = null
        selectedVideoBitrate = null
        availableVideoBitrates = emptyList()
        selectedVideoFrameRate = 30f
        surfaceRebuildBaseline = videoOutput.surfaceRebuildCount
        healthMonitor.reset()
        healthWindowStartedAtMs = null
        lastHealthEvaluationMs = 0L
        currentError = null
        audioSelections.clear()
        audioTracks = emptyList()
        videoTracks = emptyList()
        lastVideoSize = VideoSize.UNKNOWN
        hostQualityConstraint = AndroidQualityConstraint(loadOptions.videoConstraints.maxWidth?.toInt(),
            loadOptions.videoConstraints.maxHeight?.toInt(), loadOptions.videoConstraints.maxBitrate?.toInt())
        applyTrackConstraints()
        status = "opening"
        exoPlayer.stop()
        exoPlayer.clearMediaItems()
        val startPosition = loadOptions.startPositionMs ?: 0L
        loadControl.updateProfile(
            YlPlaybackPolicy.effectiveBufferProfile(
                deviceProfile.tier,
                sourceClass,
                configuration.bufferRequest(),
            ),
        )
        exoPlayer.setMediaSource(mediaSource, startPosition)
        // Candidates initialize privately and silently. Coordinator applies autoplay after commit.
        lifecycle.reduce(YlLifecycleEvent.USER_PAUSE)
        exoPlayer.playWhenReady = false
        // No decoder is acquired during candidate preparation. Lease activation starts it.
        emitState()
    }

    private fun prepareDecoder() {
        decoderAttemptStartedAtMs = SystemClock.elapsedRealtime()
        decoderName = null
        isHardwareDecoding = false
        if (decoderPolicy == AndroidDecoderPolicy.HARDWARE_REQUIRED && !inspectingDecoder) {
            inspectingDecoder = true
            videoOutput.beginInspection(YlCandidateVideoOutput(context), ::attachSurface)
        }
        exoPlayer.prepare()
    }
    private fun finishDecoderInspection() {
        if (!inspectingDecoder) return
        videoOutput.finishInspection(::attachSurface)
        inspectingDecoder = false
    }
    fun initializeDecoder() {
        prepareDecoder()
        refreshStallWatchdog()
    }

    fun selectAudioTrack(trackId: String) {
        val selection = audioSelections[trackId]
            ?: throw YlBoundaryException(YlFailureKind.SOURCE_MISSING)
        trackSelector.parameters = trackSelector.buildUponParameters()
            .clearOverridesOfType(C.TRACK_TYPE_AUDIO)
            .addOverride(TrackSelectionOverride(selection.group.mediaTrackGroup, selection.trackIndex))
            .build()
    }

    fun setVideoConstraints(constraint: AndroidVideoConstraintsMessage) {
        YlBoundaryValidation.constraints(constraint)
        hostQualityConstraint = AndroidQualityConstraint(constraint.maxWidth?.toInt(), constraint.maxHeight?.toInt(), constraint.maxBitrate?.toInt())
        applyTrackConstraints()
    }

    private fun applyTrackConstraints() {
        val envelope = deviceProfile.videoEnvelope.intersect(
            hostQualityConstraint.maxWidth,
            hostQualityConstraint.maxHeight,
        )
        val bitrate = listOfNotNull(
            hostQualityConstraint.maxBitrate,
            adaptiveBitrateCeiling,
        ).minOrNull() ?: Int.MAX_VALUE
        trackSelector.parameters = trackSelector.buildUponParameters()
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
            // Display size guides adaptive selection, not encoded video dimensions:
            // a portrait 1080px screen can still display a 1920px landscape stream.
            .setViewportSize(
                deviceProfile.displayWidth ?: Int.MAX_VALUE,
                deviceProfile.displayHeight ?: Int.MAX_VALUE,
                true,
            )
            .setMaxVideoSize(envelope.maxWidth ?: Int.MAX_VALUE, envelope.maxHeight ?: Int.MAX_VALUE)
            .setMaxVideoFrameRate(envelope.maxFrameRate?.roundToInt() ?: Int.MAX_VALUE)
            .setMaxVideoBitrate(bitrate)
            .setExceedVideoConstraintsIfNecessary(false)
            .setExceedRendererCapabilitiesIfNecessary(false)
            .build()
    }

    override fun onPlaybackStateChanged(eventTime: AnalyticsListener.EventTime, playbackState: Int) {
        if (!isCurrentEvent(eventTime)) return
        if (!active) {
            emitState()
            return
        }
        when (playbackState) {
            Player.STATE_READY -> metricsCollector.ready(eventTime.realtimeMs)
            Player.STATE_BUFFERING -> metricsCollector.buffering(eventTime.realtimeMs)
            else -> metricsCollector.endBuffering(eventTime.realtimeMs)
        }
        status = YlMedia3StatePolicy.status(status, playbackState, exoPlayer.isPlaying, hasBeenReady)
        if (playbackState == Player.STATE_READY && videoTracks.isEmpty() && audioTracks.isNotEmpty()) finishDecoderInspection()
        if (playbackState == Player.STATE_READY && !hasBeenReady) {
            hasBeenReady = true
        }
        if (playbackState == Player.STATE_BUFFERING && bufferingStartedAtMs == null) {
            if (hasBeenReady) rebufferCount += 1
            bufferingStartedAtMs = SystemClock.elapsedRealtime()
        } else if (playbackState != Player.STATE_BUFFERING) {
            bufferingStartedAtMs?.let { rebufferDurationMs += SystemClock.elapsedRealtime() - it }
            bufferingStartedAtMs = null
        }
        emitState()
        refreshStallWatchdog()
    }

    override fun onIsPlayingChanged(eventTime: AnalyticsListener.EventTime, isPlaying: Boolean) {
        if (!isCurrentEvent(eventTime)) return
        if (!active) return
        if (isPlaying && lifecycle.state.focusPaused) {
            cancelFocusGrace()
            lifecycle.reduce(YlLifecycleEvent.FOCUS_GAIN)
        }
        if (exoPlayer.playbackState == Player.STATE_READY) {
            status = YlMedia3StatePolicy.readyStatus(status, isPlaying)
            emitState()
        }
        refreshStallWatchdog()
    }

    override fun onPlayWhenReadyChanged(eventTime: AnalyticsListener.EventTime, playWhenReady: Boolean, reason: Int) {
        if (!isCurrentEvent(eventTime)) return
        when {
            !playWhenReady && reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS -> {
                if (
                    lifecycle.reduce(YlLifecycleEvent.FOCUS_TRANSIENT_LOSS) ==
                    YlLifecycleAction.PAUSE_KEEP_RESOURCES
                ) {
                    cancelFocusGrace()
                    handler.postDelayed(focusGraceRunnable, 3_000L)
                }
            }
            !playWhenReady && reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY -> {
                cancelFocusGrace()
                lifecycle.reduce(YlLifecycleEvent.USER_PAUSE)
            }
            playWhenReady && lifecycle.state.focusPaused -> {
                cancelFocusGrace()
                if (
                    lifecycle.reduce(YlLifecycleEvent.FOCUS_GAIN) ==
                    YlLifecycleAction.REBUILD_IF_INTENDED
                ) {
                    activate()
                }
            }
        }
        refreshStallWatchdog()
    }

    override fun onVideoSizeChanged(
        eventTime: AnalyticsListener.EventTime,
        videoSize: VideoSize,
    ) {
        if (!isCurrentEvent(eventTime)) return
        lastVideoSize = videoSize
        emitState()
    }

    override fun onRenderedFirstFrame(
        eventTime: AnalyticsListener.EventTime,
        output: Any,
        renderTimeMs: Long,
    ) {
        if (!isCurrentEvent(eventTime)) return
        val frame = videoOutput.firstFrameEvent(output, renderTimeMs) ?: return
        // This flag feeds worker health metrics only; it never suppresses public observations.
        if (!firstFrameRendered) {
            firstFrameRendered = true
            metricsCollector.firstFrame(renderTimeMs)
            resetHealthWindow(SystemClock.elapsedRealtime())
        }
        emit(frame)
        emitState()
        refreshStallWatchdog()
    }

    override fun onTracksChanged(eventTime: AnalyticsListener.EventTime, tracks: Tracks) {
        if (!isCurrentEvent(eventTime)) return
        audioSelections.clear()
        val audio = mutableListOf<AndroidTrackMessage>()
        val video = mutableListOf<AndroidTrackMessage>()
        tracks.groups.forEachIndexed { groupIndex, group ->
            for (trackIndex in 0 until group.length) {
                val format = group.getTrackFormat(trackIndex)
                val type = group.type
                if (type != C.TRACK_TYPE_AUDIO && type != C.TRACK_TYPE_VIDEO) continue
                val kind = if (type == C.TRACK_TYPE_AUDIO) "audio" else "video"
                val id = format.id?.takeIf(String::isNotBlank) ?: "$kind-$groupIndex-$trackIndex"
                val mapped = AndroidTrackMessage(id,
                    if (type == C.TRACK_TYPE_AUDIO) AndroidTrackKind.AUDIO else AndroidTrackKind.VIDEO,
                    format.label, format.language, format.codecs ?: format.sampleMimeType,
                    format.bitrate.valueOrNull()?.toLong(), format.width.valueOrNull()?.toLong(),
                    format.height.valueOrNull()?.toLong(), group.isTrackSelected(trackIndex))
                if (type == C.TRACK_TYPE_AUDIO) {
                    audio += mapped
                    audioSelections[id] = AudioSelection(group, trackIndex)
                } else {
                    video += mapped
                }
            }
        }
        audioTracks = audio
        videoTracks = video
        availableVideoBitrates = tracks.groups.asSequence()
            .filter { it.type == C.TRACK_TYPE_VIDEO }
            .flatMap { group ->
                (0 until group.length).asSequence()
                    .filter(group::isTrackSupported)
                    .map(group::getTrackFormat)
            }
            .mapNotNull { it.bitrate.valueOrNull() }
            .distinct()
            .sortedDescending()
            .toList()
        selectedVideoBitrate = video.firstOrNull { it.isSelected }?.bitrate?.toInt()
        tracks.groups.asSequence()
            .filter { it.type == C.TRACK_TYPE_VIDEO }
            .flatMap { group ->
                (0 until group.length).asSequence()
                    .filter(group::isTrackSelected)
                    .map(group::getTrackFormat)
            }
            .firstOrNull()
            ?.frameRate
            ?.takeIf { it > 0f }
            ?.let { selectedVideoFrameRate = it }
        emitState()
    }

    override fun onPlayerError(
        eventTime: AnalyticsListener.EventTime,
        error: PlaybackException,
    ) {
        if (!isCurrentEvent(eventTime)) return
        stallWatchdog.cancel()
        if (tryDecoderRecovery(error)) return
        status = "error"
        lastFailure = mediaFailure(error.errorCode, decoderPolicy)
        currentError = lastFailure
        emit(YlEngineEvent.Failed(lastFailure!!))
        emitState()
    }

    private fun tryDecoderRecovery(error: PlaybackException): Boolean {
        if (!active || managedNetwork || error.errorCode != PlaybackException.ERROR_CODE_DECODER_INIT_FAILED) return false
        val selected = selectedVideoBitrate ?: return false
        val lowerBitrate = availableVideoBitrates.firstOrNull { it < selected } ?: return false
        if (
            decoderRecovery(
                isAdaptive = availableVideoBitrates.size > 1,
                previousRetries = decoderRetryCount,
            ) != YlDecoderRecovery.DOWNGRADE_ONCE
        ) {
            return false
        }
        decoderRetryCount += 1
        adaptiveDowngradeCount += 1
        adaptiveBitrateCeiling = lowerBitrate
        applyTrackConstraints()
        status = "opening"
        currentError = null
        prepareDecoder()
        emitState()
        refreshStallWatchdog()
        return true
    }

    private fun maybeEvaluateHealth(memoryPressure: Boolean = false) {
        if (!hasBeenReady || status == "error") return
        val nowMs = SystemClock.elapsedRealtime()
        val startedAtMs = healthWindowStartedAtMs ?: nowMs.also(::resetHealthWindow)
        if (!memoryPressure && nowMs - lastHealthEvaluationMs < 1_000L) return
        lastHealthEvaluationMs = nowMs
        val elapsedMs = max(0L, nowMs - startedAtMs)
        val currentRebufferDuration = rebufferDurationMs +
            (bufferingStartedAtMs?.let { nowMs - it } ?: 0L)
        val bufferedDuration = max(0L, exoPlayer.bufferedPosition - exoPlayer.currentPosition)
        val canDowngrade = nextLowerBitrate() != null
        val profile = loadControl.currentProfile
        val action = healthMonitor.record(
            YlHealthSample(
                nowMs = nowMs,
                elapsedMs = elapsedMs,
                droppedFrames = droppedVideoFrames - healthWindowDroppedFrames,
                estimatedRenderedFrames = ((elapsedMs / 1_000.0) * selectedVideoFrameRate).toInt(),
                rebufferCount = rebufferCount - healthWindowRebufferCount,
                rebufferDurationMs = currentRebufferDuration - healthWindowRebufferDurationMs,
                memoryPressure = memoryPressure,
                canDowngrade = canDowngrade,
                sourceClass = sourceClass,
                liveOffsetMs = normalizedLiveOffset(),
                bufferedDurationMs = bufferedDuration,
                targetLiveOffsetMs = (profile.minBufferMs + profile.maxBufferMs) / 2L,
                maxBufferMs = profile.maxBufferMs,
                reconnectCount = reconnectCount,
                maxRetries = configuration.network.maxRetries,
            ),
        )
        applyRecoveryAction(action)
        if (elapsedMs >= 30_000L) resetHealthWindow(nowMs)
    }

    private fun resetHealthWindow(nowMs: Long) {
        healthWindowStartedAtMs = nowMs
        healthWindowDroppedFrames = droppedVideoFrames
        healthWindowRebufferCount = rebufferCount
        healthWindowRebufferDurationMs = rebufferDurationMs
    }

    private fun nextLowerBitrate(): Int? {
        val selected = selectedVideoBitrate ?: adaptiveBitrateCeiling ?: return null
        return availableVideoBitrates.firstOrNull { it < selected }
    }

    private fun applyRecoveryAction(action: YlRecoveryAction) {
        when (action) {
            YlRecoveryAction.None -> Unit
            YlRecoveryAction.DowngradeOneStep -> {
                val lowerBitrate = nextLowerBitrate()
                if (lowerBitrate == null) {
                    failWith(stableError(YlPlaybackFailure.CAPABILITY_EXCEEDED))
                } else {
                    adaptiveBitrateCeiling = lowerBitrate
                    adaptiveDowngradeCount += 1
                    applyTrackConstraints()
                }
            }
            YlRecoveryAction.SeekLiveEdge -> {
                exoPlayer.setPlaybackSpeed(requestedPlaybackSpeed)
                exoPlayer.seekToDefaultPosition()
            }
            YlRecoveryAction.ReconnectLiveHead -> {
                // The pending resource owns its retries. Do not restart it or invent a source
                // timeout while its managed request budget still has scheduled work.
                if (managedNetwork) return
                reconnectCount += 1
                exoPlayer.stop()
                prepareDecoder()
                refreshStallWatchdog()
            }
            is YlRecoveryAction.SetCatchUpSpeed -> {
                if (requestedPlaybackSpeed == 1f) exoPlayer.setPlaybackSpeed(action.speed.coerceAtMost(1.03f))
            }
            is YlRecoveryAction.Fail -> failWith(action.error)
        }
    }

    private fun failWith(error: YlStableError, diagnostic: String? = null) {
        stallWatchdog.cancel()
        val kind = when (error.category) {
            "network" -> YlFailureKind.NETWORK_FAILED
            "decoderUnsupported" -> YlFailureKind.DECODER_UNSUPPORTED
            "decoderFailure" -> YlFailureKind.DECODER_UNAVAILABLE
            else -> YlFailureKind.PLATFORM_FAILURE
        }
        status = "error"; currentError = kind; lastFailure = kind
        exoPlayer.pause()
        emit(YlEngineEvent.Failed(kind)); emitState()
    }

    private fun refreshStallWatchdog() {
        // Managed HTTP owns hop/header/body timing; a source watchdog is not a second request timer.
        if (managedNetwork) { stallWatchdog.cancel(); return }
        val generation = sourceGeneration
        stallWatchdog.update(
            active = active,
            wantsToPlay = exoPlayer.playWhenReady,
            hasCurrentItem = exoPlayer.currentMediaItem != null,
            isBuffering = exoPlayer.playbackState == Player.STATE_BUFFERING,
            firstFrameRendered = firstFrameRendered,
            timeoutMs = configuration.network.readTimeoutMs.toLong(),
            playbackState = status,
        ) { error, diagnostic ->
            if (generation == sourceGeneration && active && status != "error") {
                failWith(error, diagnostic)
            }
        }
    }

    fun handleRunningLowMemory() {
        if (disposed || !active || stopped) return
        loadControl.shrinkForMemoryPressure()
        maybeEvaluateHealth(memoryPressure = true)
        emitState()
    }

    override fun onVideoDecoderInitialized(
        eventTime: AnalyticsListener.EventTime,
        decoderName: String,
        initializedTimestampMs: Long,
        initializationDurationMs: Long,
    ) {
        if (!isCurrentEvent(eventTime)) return
        if (initializedTimestampMs < decoderAttemptStartedAtMs) return
        this.decoderName = decoderName
        isHardwareDecoding = decoderEvidence.mode(decoderName) == AndroidDecoderMode.HARDWARE
        if (decoderPolicy == AndroidDecoderPolicy.HARDWARE_REQUIRED) {
            if (!isHardwareDecoding) {
                status = "error"; lastFailure = YlFailureKind.DECODER_UNAVAILABLE; currentError = lastFailure
                exoPlayer.pause()
                emit(YlEngineEvent.Failed(YlFailureKind.DECODER_UNAVAILABLE))
            } else finishDecoderInspection()
        }
        emitState()
    }

    override fun onDroppedVideoFrames(
        eventTime: AnalyticsListener.EventTime,
        droppedFrames: Int,
        elapsedMs: Long,
    ) {
        if (!isCurrentEvent(eventTime)) return
        droppedVideoFrames += droppedFrames
        metricsCollector.dropped(droppedFrames)
    }

    override fun onAudioUnderrun(
        eventTime: AnalyticsListener.EventTime,
        bufferSize: Int,
        bufferSizeMs: Long,
        elapsedSinceLastFeedMs: Long,
    ) {
        if (!isCurrentEvent(eventTime)) return
        audioUnderruns += 1
        metricsCollector.underrun()
    }

    private fun recordRetry(attempt: Int, delayMs: Long, occurredAtMs: Long) {
        if (disposed) return
        reconnectCount += 1
        metricsCollector.retry()
        emit(YlEngineEvent.Retry(attempt.toLong(), delayMs, occurredAtMs))
        emitState()
    }

    private fun normalizedLiveOffset(): Long? = exoPlayer.currentLiveOffset
        .takeUnless { it == C.TIME_UNSET }?.coerceAtLeast(0)

    private fun timeline(): AndroidTimelineMessage {
        val position = if (active) max(0L, exoPlayer.currentPosition) else savedPositionMs
        val duration = exoPlayer.duration.takeUnless { it == C.TIME_UNSET || it < 0 }
        val live = sourceIsLive || exoPlayer.isCurrentMediaItemLive
        val offset = normalizedLiveOffset()
        return AndroidTimelineMessage(position, duration,
            if (active) max(position, exoPlayer.bufferedPosition) else position,
            exoPlayer.isCurrentMediaItemSeekable, live,
            if (live && offset != null) offset <= 2_000L else null, offset,
            if (live && exoPlayer.isCurrentMediaItemSeekable && duration != null) AndroidDvrWindowMessage(0, duration) else null)
    }
    fun emitState() {
        if (disposed || resetting) return
        val timeline = timeline()
        val geometry = media3VideoGeometry(lastVideoSize, exoPlayer.videoFormat)
        emit(YlEngineEvent.Snapshot(YlEngineSnapshot(
            when (status) {
                "idle" -> AndroidPlaybackStatus.IDLE
                "ready" -> AndroidPlaybackStatus.READY
                "playing" -> AndroidPlaybackStatus.PLAYING
                "paused" -> AndroidPlaybackStatus.PAUSED
                "buffering" -> AndroidPlaybackStatus.BUFFERING
                "completed" -> AndroidPlaybackStatus.COMPLETED
                "error" -> AndroidPlaybackStatus.FAILED
                else -> AndroidPlaybackStatus.LOADING
            }, timeline, geometry, audioTracks.toList(), videoTracks.toList(),
            decoderEvidence.mode(decoderName), decoderName, metrics(timeline), hasBeenReady)))
    }
    private fun emitPositionDelta() {
        if (disposed || stopped || resetting) return
        val timeline = timeline()
        emit(YlEngineEvent.Tick(timeline, metrics(timeline)))
    }
    private fun metrics(timeline: AndroidTimelineMessage) = metricsCollector.snapshot(SystemClock.elapsedRealtime(),
        if (active && hasBeenReady) (timeline.bufferedPositionMs - timeline.positionMs).coerceAtLeast(0) else null,
        timeline.liveOffsetMs)

    override fun onVideoEnabled(eventTime: AnalyticsListener.EventTime, decoderCounters: androidx.media3.exoplayer.DecoderCounters) {
        if (isCurrentEvent(eventTime)) metricsCollector.videoEnabled()
    }
    override fun onAudioEnabled(eventTime: AnalyticsListener.EventTime, decoderCounters: androidx.media3.exoplayer.DecoderCounters) {
        if (isCurrentEvent(eventTime)) metricsCollector.audioEnabled()
    }
    override fun onBandwidthEstimate(eventTime: AnalyticsListener.EventTime, totalLoadTimeMs: Int, totalBytesLoaded: Long, bitrateEstimate: Long) {
        if (isCurrentEvent(eventTime)) metricsCollector.bandwidth(bitrateEstimate)
    }

    /** false quarantines the worker and outputs: release timeout does not prove relinquishment. */
    fun dispose(): Boolean {
        if (disposed) return acknowledgement.isSafe
        lifecycle.reduce(YlLifecycleEvent.DISPOSE)
        stallWatchdog.cancel()
        disposed = true
        sourceGeneration += 1
        cancelFocusGrace()
        handler.removeCallbacksAndMessages(null)
        // Keep the Player.Listener installed until release returns: timeout is a listener event.
        if (::exoPlayer.isInitialized) {
            acknowledgement.perform { videoOutput.detach(::clearSurface) }
            acknowledgement.perform { exoPlayer.release() }
        }
        sourceFactory.close()
        if (!acknowledgement.isSafe) return false
        videoOutput.dispose { }
        return true
    }

    private fun cancelFocusGrace() {
        handler.removeCallbacks(focusGraceRunnable)
    }

    private fun acceptsCurrentCallbacks(): Boolean =
        !disposed && !resetting && !stopped &&
            exoPlayer.currentMediaItem?.mediaId == identity.sessionId

    private fun isCurrentEvent(eventTime: AnalyticsListener.EventTime): Boolean {
        if (!acceptsCurrentCallbacks()) return false
        if (eventTime.timeline.isEmpty || eventTime.windowIndex == C.INDEX_UNSET) {
            return exoPlayer.currentMediaItem?.mediaId == identity.sessionId
        }
        return runCatching {
            val item = eventTime.timeline
                .getWindow(eventTime.windowIndex, Timeline.Window())
                .mediaItem
            item.mediaId == identity.sessionId
        }.getOrDefault(false)
    }
}

private fun Int.valueOrNull(): Int? = takeUnless { it == C.LENGTH_UNSET }
internal fun mediaFailure(errorCode: Int, decoderPolicy: AndroidDecoderPolicy): YlFailureKind = when (errorCode) {
    PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED -> if (decoderPolicy == AndroidDecoderPolicy.HARDWARE_REQUIRED) YlFailureKind.DECODER_UNAVAILABLE else YlFailureKind.DECODER_UNSUPPORTED
    PlaybackException.ERROR_CODE_DECODER_INIT_FAILED, PlaybackException.ERROR_CODE_DECODING_FAILED -> YlFailureKind.DECODER_UNAVAILABLE
    PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND -> YlFailureKind.SOURCE_MISSING
    in 2000..2999 -> YlFailureKind.NETWORK_FAILED
    in 3000..3999 -> YlFailureKind.CONTAINER_UNSUPPORTED
    else -> YlFailureKind.PLATFORM_FAILURE
}
private fun formatHint(format: AndroidMediaFormat): String = when (format) {
    AndroidMediaFormat.MPEG_TS -> "mpegTs"
    AndroidMediaFormat.MPEG_PS -> "mpegPs"
    else -> format.name.lowercase()
}
private fun mediaMimeType(format: AndroidMediaFormat): String? = when (format) {
    AndroidMediaFormat.HLS -> "application/x-mpegURL"
    AndroidMediaFormat.MP4 -> "video/mp4"
    AndroidMediaFormat.MOV -> "video/quicktime"
    AndroidMediaFormat.MATROSKA -> "video/x-matroska"
    AndroidMediaFormat.WEBM -> "video/webm"
    AndroidMediaFormat.MPEG_TS -> "video/mp2t"
    AndroidMediaFormat.MPEG_PS -> "video/mp2p"
    AndroidMediaFormat.FLV -> "video/x-flv"
    AndroidMediaFormat.AVI -> "video/x-msvideo"
    else -> null
}

/** Media3 1.11 applies rotation itself. Format is coded geometry; VideoSize is renderer output.
 * Preserve VideoSize's unapplied rotation (always zero in this pinned version), never Format rotation. */
@Suppress("DEPRECATION")
internal fun media3VideoGeometry(size: VideoSize, format: androidx.media3.common.Format?): AndroidVideoGeometryMessage? {
    if (size.width <= 0 || size.height <= 0) return null
    val rendered = AndroidSizeMessage(size.width.toDouble(), size.height.toDouble())
    val coded = format?.takeIf { it.width > 0 && it.height > 0 }?.let { AndroidSizeMessage(it.width.toDouble(), it.height.toDouble()) } ?: rendered
    return AndroidVideoGeometryMessage(coded, rendered,
        size.pixelWidthHeightRatio.toDouble().takeIf { it.isFinite() && it > 0 } ?: 1.0,
        size.unappliedRotationDegrees.toLong())
}
