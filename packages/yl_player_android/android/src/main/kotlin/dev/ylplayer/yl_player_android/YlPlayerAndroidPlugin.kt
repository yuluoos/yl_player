package dev.ylplayer.yl_player_android

import android.app.Activity
import android.app.Application
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.Timeline
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import kotlin.math.max
import kotlin.math.roundToInt

@OptIn(UnstableApi::class)
class YlPlayerAndroidPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ComponentCallbacks2,
    Application.ActivityLifecycleCallbacks {
    private lateinit var application: Application
    private lateinit var applicationContext: Context
    private lateinit var textures: TextureRegistry
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private val players = mutableMapOf<Long, Media3Player>()
    private var nextPlayerId = 1L
    private var eventSink: EventChannel.EventSink? = null
    private var startedActivities = 0
    private var activePlayerId: Long? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        application = applicationContext as Application
        application.registerComponentCallbacks(this)
        application.registerActivityLifecycleCallbacks(this)
        textures = binding.textureRegistry
        methodChannel = MethodChannel(
            binding.binaryMessenger,
            "dev.ylplayer.yl_player_android/methods",
        )
        eventChannel = EventChannel(
            binding.binaryMessenger,
            "dev.ylplayer.yl_player_android/events",
        )
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink = null
        application.unregisterComponentCallbacks(this)
        application.unregisterActivityLifecycleCallbacks(this)
        players.values.toList().forEach(Media3Player::dispose)
        players.clear()
        activePlayerId = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
        players.values.forEach(Media3Player::emitState)
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> createPlayer(call, result)
            "command" -> runCommand(call, result)
            "dispose" -> disposePlayer(call, result)
            else -> result.notImplemented()
        }
    }

    private fun createPlayer(call: MethodCall, result: MethodChannel.Result) {
        var texture: TextureRegistry.SurfaceTextureEntry? = null
        try {
            val arguments = call.arguments.asStringMap()
            val configuration = PlayerConfiguration.from(arguments["configuration"].asStringMap())
            val playerId = nextPlayerId++
            texture = textures.createSurfaceTexture()
            val player = Media3Player(
                context = applicationContext,
                playerId = playerId,
                texture = texture,
                configuration = configuration,
                emit = ::emit,
            )
            players[playerId] = player
            result.success(mapOf("playerId" to playerId, "textureId" to texture.id()))
        } catch (error: Throwable) {
            texture?.release()
            result.playerError("android.create_failed", "Could not create Media3 player.", error)
        }
    }

    private fun runCommand(call: MethodCall, result: MethodChannel.Result) {
        val root = call.arguments.asStringMap()
        val playerId = (root["playerId"] as? Number)?.toLong()
        val player = playerId?.let(players::get)
        if (player == null) {
            result.error(
                "android.player_missing",
                "The requested Android player does not exist.",
                errorMap("resource", "android.player_missing", "Player was already released."),
            )
            return
        }
        try {
            val commandName = root["name"] as? String ?: ""
            if (commandName == "open") {
                player.validateOpen(root["arguments"].asStringMap()["source"].asStringMap())
            }
            if (commandName == "open" || commandName == "play") {
                players.values.filter { it !== player }.forEach(Media3Player::deactivate)
                activePlayerId = playerId
                player.activate()
            }
            player.command(commandName, root["arguments"].asStringMap())
            result.success(null)
        } catch (error: PlayerCommandException) {
            result.error(error.code, error.message, error.details)
        } catch (error: Throwable) {
            result.playerError("android.command_failed", "Media3 command failed.", error)
        }
    }

    private fun disposePlayer(call: MethodCall, result: MethodChannel.Result) {
        val playerId = (call.arguments.asStringMap()["playerId"] as? Number)?.toLong()
        if (playerId != null) {
            players.remove(playerId)?.dispose()
            if (activePlayerId == playerId) activePlayerId = null
        }
        result.success(null)
    }

    private fun emit(event: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            eventSink?.success(event)
        } else {
            Handler(Looper.getMainLooper()).post { eventSink?.success(event) }
        }
    }

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onTrimMemory(level: Int) {
        val activePlayer = activePlayerId?.let(players::get)
        when {
            level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL ->
                activePlayer?.releaseForLifecycle()
            level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE ->
                activePlayer?.handleRunningLowMemory()
        }
    }

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onLowMemory() {
        activePlayerId?.let(players::get)?.releaseForLifecycle()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        activePlayerId?.let(players::get)?.rebuildVideoOutput()
    }

    override fun onActivityStarted(activity: Activity) {
        val wasInBackground = startedActivities == 0
        startedActivities += 1
        if (wasInBackground) activePlayerId?.let(players::get)?.restoreAfterForeground()
    }

    override fun onActivityStopped(activity: Activity) {
        startedActivities = (startedActivities - 1).coerceAtLeast(0)
        if (startedActivities == 0 && !activity.isChangingConfigurations) {
            activePlayerId?.let(players::get)?.releaseForLifecycle()
        }
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
    override fun onActivityResumed(activity: Activity) = Unit
    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit
}

@OptIn(UnstableApi::class)
private class Media3Player(
    private val context: Context,
    private val playerId: Long,
    private val texture: TextureRegistry.SurfaceTextureEntry,
    private val configuration: PlayerConfiguration,
    private val emit: (Map<String, Any?>) -> Unit,
) : Player.Listener, AnalyticsListener {
    private val handler = Handler(Looper.getMainLooper())
    private val videoOutput = YlVideoOutput(texture)
    private val lifecycle = YlLifecycleCoordinator()
    private val deviceProfile = YlAndroidDeviceProfile.collect(context)
    private val trackSelector = DefaultTrackSelector(context)
    private val httpClient = configuration.network.createHttpClient()
    private val loadControl = YlAdaptiveLoadControl(
        YlPlaybackPolicy.effectiveBufferProfile(
            deviceProfile.tier,
            YlSourceClass.NETWORK_VOD,
            configuration.bufferRequest(),
        ),
    )
    private val exoPlayer: ExoPlayer
    private val audioSelections = mutableMapOf<String, AudioSelection>()
    private var sourceIsLive = false
    private var sourceClass = YlSourceClass.NETWORK_VOD
    private var disposed = false
    private var status = "idle"
    private var openStartedAtMs: Long? = null
    private var openDurationMs: Long? = null
    private var firstFrameDurationMs: Long? = null
    private var hasBeenReady = false
    private var rebufferCount = 0
    private var bufferingStartedAtMs: Long? = null
    private var rebufferDurationMs = 0L
    private var reconnectCount = 0
    private var droppedVideoFrames = 0
    private var audioUnderruns = 0
    private var decoderName: String? = null
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
    private var currentError: Map<String, Any?>? = null
    private var active = false
    private var savedPositionMs = 0L
    private var resumeAtLiveEdge = false
    private var sourceGeneration = 0L
    private val firstFrameGate = YlFirstFrameGate()
    private var lastVideoSize = VideoSize.UNKNOWN
    private var audioTracks: List<Map<String, Any?>> = emptyList()
    private var videoTracks: List<Map<String, Any?>> = emptyList()
    private val capabilitySnapshot by lazy {
        mapOf(
            "hardwareVideoCodecs" to hardwareVideoCodecs(),
            "supportedFormats" to listOf(
                "automatic", "hls", "httpFlv", "mp4", "matroska", "webm", "mpegTs", "mpegPs", "flv",
            ),
            "maxConcurrentVideoDecoders" to 1,
            "maxWidth" to deviceProfile.videoEnvelope.maxWidth,
            "maxHeight" to deviceProfile.videoEnvelope.maxHeight,
        )
    }
    private val positionTicker = object : Runnable {
        override fun run() {
            if (!disposed && active) {
                maybeEvaluateHealth()
                emitState()
                handler.postDelayed(this, configuration.positionEventIntervalMs)
            }
        }
    }

    init {
        val renderersFactory = DefaultRenderersFactory(context)
            .setEnableDecoderFallback(true)
            .setMediaCodecSelector(YlHardwareCodecSelector())
        exoPlayer = ExoPlayer.Builder(context, renderersFactory)
            .setTrackSelector(trackSelector)
            .setLoadControl(loadControl)
            .build()
        exoPlayer.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(),
            true,
        )
        exoPlayer.setHandleAudioBecomingNoisy(true)
        exoPlayer.setWakeMode(C.WAKE_MODE_NETWORK)
        applyTrackConstraints()
        exoPlayer.addListener(this)
        exoPlayer.addAnalyticsListener(this)
        videoOutput.attach(sourceGeneration, sourceGeneration, exoPlayer::setVideoSurface)
    }

    fun command(name: String, arguments: Map<String, Any?>) {
        check(!disposed) { "Player is disposed." }
        when (name) {
            "open" -> open(arguments["source"].asStringMap())
            "play" -> {
                cancelFocusGrace()
                lifecycle.reduce(YlLifecycleEvent.USER_PLAY)
                exoPlayer.play()
            }
            "pause" -> {
                cancelFocusGrace()
                lifecycle.reduce(YlLifecycleEvent.USER_PAUSE)
                exoPlayer.pause()
            }
            "seekTo" -> {
                val positionMs = max(0L, (arguments["positionMs"] as? Number)?.toLong() ?: 0L)
                resumeAtLiveEdge = false
                if (active) {
                    exoPlayer.seekTo(positionMs)
                } else {
                    savedPositionMs = positionMs
                    emitState()
                }
            }
            "seekToLiveEdge" -> {
                if (!sourceIsLive && !exoPlayer.isCurrentMediaItemLive) {
                    throw PlayerCommandException(
                        "source.not_live",
                        "The current source is not live.",
                        errorMap("source", "source.not_live", "The current source is not live."),
                    )
                }
                if (active) {
                    resumeAtLiveEdge = false
                    exoPlayer.seekToDefaultPosition()
                } else {
                    resumeAtLiveEdge = true
                    emitState()
                }
            }
            "setPlaybackSpeed" -> {
                val speed = (arguments["speed"] as? Number)?.toFloat() ?: 1f
                require(speed in 0.25f..4f) { "Playback speed must be between 0.25 and 4.0." }
                requestedPlaybackSpeed = speed
                exoPlayer.setPlaybackSpeed(speed)
            }
            "setVolume" -> {
                val volume = (arguments["volume"] as? Number)?.toFloat() ?: 1f
                exoPlayer.volume = volume.coerceIn(0f, 1f)
            }
            "selectAudioTrack" -> selectAudioTrack(arguments["trackId"] as? String ?: "")
            "setQualityConstraint" -> setQualityConstraint(arguments["constraint"].asStringMap())
            else -> throw PlayerCommandException(
                "android.command_unknown",
                "Unknown player command: $name",
                errorMap("internal", "android.command_unknown", "Unknown player command: $name"),
            )
        }
    }

    fun validateOpen(source: Map<String, Any?>) {
        val uri = source["uri"] as? String
        if (uri.isNullOrBlank()) {
            throw PlayerCommandException(
                "source.invalid_uri",
                "A media URI is required.",
                errorMap("source", "source.invalid_uri", "A media URI is required."),
            )
        }
    }

    fun activate() {
        if (disposed || active) return
        active = true
        loadControl.restoreProfile()
        videoOutput.attach(sourceGeneration, sourceGeneration, exoPlayer::setVideoSurface)
        if (exoPlayer.currentMediaItem != null && exoPlayer.playbackState == Player.STATE_IDLE) {
            status = "opening"
            exoPlayer.prepare()
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
    }

    fun deactivate() {
        if (disposed || !active) return
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

    fun rebuildVideoOutput() {
        if (disposed || !active) return
        videoOutput.rebuild(
            expectedSourceGeneration = sourceGeneration,
            currentSourceGeneration = sourceGeneration,
            clear = exoPlayer::clearVideoSurface,
            consumer = exoPlayer::setVideoSurface,
        )
        if (lastVideoSize.width > 0 && lastVideoSize.height > 0) {
            videoOutput.resize(lastVideoSize.width, lastVideoSize.height)
        }
        emitState()
    }

    private fun releasePlaybackResources() {
        cancelFocusGrace()
        if (!active) return
        savedPositionMs = max(0L, exoPlayer.currentPosition)
        if (exoPlayer.currentLiveOffset in 0..2_000L) {
            resumeAtLiveEdge = true
        }
        bufferingStartedAtMs?.let { rebufferDurationMs += SystemClock.elapsedRealtime() - it }
        bufferingStartedAtMs = null
        active = false
        handler.removeCallbacks(positionTicker)
        exoPlayer.pause()
        exoPlayer.stop()
        videoOutput.detach(exoPlayer::clearVideoSurface)
        if (status != "error" && status != "completed" && status != "idle") {
            status = "paused"
        }
        emitState()
    }

    private fun open(source: Map<String, Any?>) {
        cancelFocusGrace()
        validateOpen(source)
        val uriString = source["uri"] as String
        sourceIsLive = source["isLive"] == true
        sourceClass = YlPlaybackPolicy.classifySource(
            kind = source["kind"] as? String ?: "network",
            isLive = sourceIsLive,
            formatHint = source["formatHint"] as? String ?: "automatic",
            uri = uriString,
        )
        loadControl.updateProfile(
            YlPlaybackPolicy.effectiveBufferProfile(
                deviceProfile.tier,
                sourceClass,
                configuration.bufferRequest(),
            ),
        )
        active = true
        savedPositionMs = 0
        resumeAtLiveEdge = false
        val headers = source["headers"].asStringMap().mapValues { it.value.toString() }
        val network = configuration.network
        sourceGeneration += 1
        val generation = sourceGeneration
        firstFrameGate.reset(generation)
        val httpFactory = OkHttpDataSource.Factory(httpClient)
            .setDefaultRequestProperties(headers)
        val dataSourceFactory = DefaultDataSource.Factory(context, httpFactory)
        val mediaSourceFactory = DefaultMediaSourceFactory(dataSourceFactory)
            .setLoadErrorHandlingPolicy(
                YlLoadErrorHandlingPolicy(network) { attempt, delayMs, exception ->
                    handler.post {
                        if (generation == sourceGeneration) {
                            recordRetry(attempt, delayMs, exception)
                        }
                    }
                },
            )
        val mediaItem = MediaItem.Builder()
            .setMediaId(generation.toString())
            .setUri(Uri.parse(uriString))
            .setMimeType(mimeType(source["formatHint"] as? String))
            .build()

        openStartedAtMs = SystemClock.elapsedRealtime()
        openDurationMs = null
        firstFrameDurationMs = null
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
        applyTrackConstraints()
        status = "opening"
        exoPlayer.stop()
        exoPlayer.clearMediaItems()
        exoPlayer.setMediaSource(mediaSourceFactory.createMediaSource(mediaItem))
        exoPlayer.prepare()
        emitState()
    }

    private fun selectAudioTrack(trackId: String) {
        val selection = audioSelections[trackId]
            ?: throw PlayerCommandException(
                "track.not_found",
                "The requested audio track is unavailable.",
                errorMap("source", "track.not_found", "The requested audio track is unavailable."),
            )
        trackSelector.parameters = trackSelector.buildUponParameters()
            .clearOverridesOfType(C.TRACK_TYPE_AUDIO)
            .addOverride(TrackSelectionOverride(selection.group.mediaTrackGroup, selection.trackIndex))
            .build()
    }

    private fun setQualityConstraint(constraint: Map<String, Any?>) {
        hostQualityConstraint = AndroidQualityConstraint(
            maxWidth = (constraint["maxWidth"] as? Number)?.toInt(),
            maxHeight = (constraint["maxHeight"] as? Number)?.toInt(),
            maxBitrate = (constraint["maxBitrate"] as? Number)?.toInt(),
        )
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
            .setMaxVideoSize(envelope.maxWidth ?: Int.MAX_VALUE, envelope.maxHeight ?: Int.MAX_VALUE)
            .setMaxVideoFrameRate(envelope.maxFrameRate?.roundToInt() ?: Int.MAX_VALUE)
            .setMaxVideoBitrate(bitrate)
            .setExceedVideoConstraintsIfNecessary(false)
            .setExceedRendererCapabilitiesIfNecessary(false)
            .build()
    }

    override fun onPlaybackStateChanged(playbackState: Int) {
        if (!active) {
            emitState()
            return
        }
        status = when (playbackState) {
            Player.STATE_BUFFERING -> "buffering"
            Player.STATE_READY -> if (exoPlayer.isPlaying) "playing" else "ready"
            Player.STATE_ENDED -> "completed"
            else -> if (status == "opening") "opening" else "idle"
        }
        if (playbackState == Player.STATE_READY && !hasBeenReady) {
            hasBeenReady = true
            openDurationMs = openStartedAtMs?.let { SystemClock.elapsedRealtime() - it }
        }
        if (playbackState == Player.STATE_BUFFERING && bufferingStartedAtMs == null) {
            if (hasBeenReady) rebufferCount += 1
            bufferingStartedAtMs = SystemClock.elapsedRealtime()
        } else if (playbackState != Player.STATE_BUFFERING) {
            bufferingStartedAtMs?.let { rebufferDurationMs += SystemClock.elapsedRealtime() - it }
            bufferingStartedAtMs = null
        }
        emitState()
    }

    override fun onIsPlayingChanged(isPlaying: Boolean) {
        if (!active) return
        if (isPlaying && lifecycle.state.focusPaused) {
            cancelFocusGrace()
            lifecycle.reduce(YlLifecycleEvent.FOCUS_GAIN)
        }
        if (exoPlayer.playbackState == Player.STATE_READY) {
            status = if (isPlaying) "playing" else "paused"
            emitState()
        }
    }

    override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
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
    }

    override fun onVideoSizeChanged(
        eventTime: AnalyticsListener.EventTime,
        videoSize: VideoSize,
    ) {
        if (!isCurrentEvent(eventTime)) return
        lastVideoSize = videoSize
        if (videoSize.width > 0 && videoSize.height > 0) {
            videoOutput.resize(videoSize.width, videoSize.height)
        }
        emitState()
    }

    override fun onRenderedFirstFrame(
        eventTime: AnalyticsListener.EventTime,
        output: Any,
        renderTimeMs: Long,
    ) {
        val generation = sourceGeneration
        if (!isCurrentEvent(eventTime)) return
        if (!firstFrameGate.markRendered(generation)) return
        firstFrameDurationMs = openStartedAtMs?.let { SystemClock.elapsedRealtime() - it }
        resetHealthWindow(SystemClock.elapsedRealtime())
        emit(
            mapOf(
                "playerId" to playerId,
                "type" to "firstFrame",
                "width" to lastVideoSize.width.takeIf { it > 0 },
                "height" to lastVideoSize.height.takeIf { it > 0 },
            ),
        )
        emitState()
    }

    override fun onTracksChanged(tracks: Tracks) {
        audioSelections.clear()
        val audio = mutableListOf<Map<String, Any?>>()
        val video = mutableListOf<Map<String, Any?>>()
        tracks.groups.forEachIndexed { groupIndex, group ->
            for (trackIndex in 0 until group.length) {
                val format = group.getTrackFormat(trackIndex)
                val type = group.type
                if (type != C.TRACK_TYPE_AUDIO && type != C.TRACK_TYPE_VIDEO) continue
                val kind = if (type == C.TRACK_TYPE_AUDIO) "audio" else "video"
                val id = format.id?.takeIf(String::isNotBlank) ?: "$kind-$groupIndex-$trackIndex"
                val mapped = mapOf(
                    "id" to id,
                    "kind" to kind,
                    "label" to format.label,
                    "language" to format.language,
                    "codec" to (format.codecs ?: format.sampleMimeType),
                    "bitrate" to format.bitrate.valueOrNull(),
                    "width" to format.width.valueOrNull(),
                    "height" to format.height.valueOrNull(),
                    "isSelected" to group.isTrackSelected(trackIndex),
                )
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
        selectedVideoBitrate = video.firstOrNull { it["isSelected"] == true }
            ?.get("bitrate") as? Int
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
        emit(
            mapOf(
                "playerId" to playerId,
                "type" to "tracksChanged",
                "audioTracks" to audioTracks,
                "videoTracks" to videoTracks,
            ),
        )
        emitState()
    }

    override fun onPlayerError(
        eventTime: AnalyticsListener.EventTime,
        error: PlaybackException,
    ) {
        if (!isCurrentEvent(eventTime)) return
        if (tryDecoderRecovery(error)) return
        status = "error"
        val details = playbackErrorMap(
            error,
            codecDiagnostic(
                decoderName,
                lastVideoSize.width.takeIf { it > 0 },
                lastVideoSize.height.takeIf { it > 0 },
                null,
                deviceProfile.signals.apiLevel,
            ),
        )
        currentError = details
        emit(mapOf("playerId" to playerId, "type" to "error", "error" to details))
        emitState(details)
    }

    private fun tryDecoderRecovery(error: PlaybackException): Boolean {
        if (error.errorCode != PlaybackException.ERROR_CODE_DECODER_INIT_FAILED) return false
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
        exoPlayer.prepare()
        emitState()
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
                liveOffsetMs = exoPlayer.currentLiveOffset.takeUnless { it == C.TIME_UNSET || it < 0 },
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
                reconnectCount += 1
                exoPlayer.stop()
                exoPlayer.prepare()
            }
            is YlRecoveryAction.SetCatchUpSpeed -> {
                if (requestedPlaybackSpeed == 1f) exoPlayer.setPlaybackSpeed(action.speed.coerceAtMost(1.03f))
            }
            is YlRecoveryAction.Fail -> failWith(action.error)
        }
    }

    private fun failWith(error: YlStableError) {
        val details = errorMap(error.category, error.code, error.message)
        status = "error"
        currentError = details
        exoPlayer.pause()
        emit(mapOf("playerId" to playerId, "type" to "error", "error" to details))
        emitState(details)
    }

    fun handleRunningLowMemory() {
        if (disposed || !active) return
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
        this.decoderName = decoderName
        isHardwareDecoding = isHardwareCodecName(decoderName)
        emitState()
    }

    override fun onDroppedVideoFrames(
        eventTime: AnalyticsListener.EventTime,
        droppedFrames: Int,
        elapsedMs: Long,
    ) {
        if (!isCurrentEvent(eventTime)) return
        droppedVideoFrames += droppedFrames
    }

    override fun onAudioUnderrun(
        eventTime: AnalyticsListener.EventTime,
        bufferSize: Int,
        bufferSizeMs: Long,
        elapsedSinceLastFeedMs: Long,
    ) {
        if (!isCurrentEvent(eventTime)) return
        audioUnderruns += 1
    }

    private fun recordRetry(attempt: Int, delayMs: Long, exception: Exception) {
        if (disposed) return
        reconnectCount += 1
        emit(
            mapOf(
                "playerId" to playerId,
                "type" to "retry",
                "attempt" to attempt,
                "delayMs" to delayMs,
                "error" to errorMap(
                    "network",
                    "network.retry",
                    "Retrying media request.",
                    exception.toString(),
                ),
            ),
        )
        emitState()
    }

    fun emitState(error: Map<String, Any?>? = null) {
        if (disposed) return
        val position = if (active) max(0L, exoPlayer.currentPosition) else savedPositionMs
        val duration = exoPlayer.duration.takeUnless { it == C.TIME_UNSET || it < 0 }
        val liveOffset = exoPlayer.currentLiveOffset.takeUnless { it == C.TIME_UNSET || it < 0 }
        val bufferedPosition = if (active) max(0L, exoPlayer.bufferedPosition) else position
        val bufferedDuration = max(0L, bufferedPosition - position)
        emit(
            mapOf(
                "playerId" to playerId,
                "type" to "state",
                "state" to mapOf(
                    "status" to status,
                    "positionMs" to position,
                    "durationMs" to duration,
                    "bufferedPositionMs" to bufferedPosition,
                    "isLive" to (sourceIsLive || exoPlayer.isCurrentMediaItemLive),
                    "isSeekable" to exoPlayer.isCurrentMediaItemSeekable,
                    "isAtLiveEdge" to (liveOffset != null && liveOffset <= 2_000L),
                    "liveOffsetMs" to liveOffset,
                    "dvrStartMs" to if (exoPlayer.isCurrentMediaItemSeekable) 0L else null,
                    "dvrEndMs" to if (exoPlayer.isCurrentMediaItemSeekable) duration else null,
                    "videoWidth" to lastVideoSize.width.takeIf { it > 0 },
                    "videoHeight" to lastVideoSize.height.takeIf { it > 0 },
                    "engine" to "media3",
                    "isHardwareDecoding" to isHardwareDecoding,
                    "decoderName" to decoderName,
                    "audioTracks" to audioTracks,
                    "videoTracks" to videoTracks,
                    "capabilities" to capabilitySnapshot,
                    "metrics" to mapOf(
                        "openDurationMs" to openDurationMs,
                        "firstFrameDurationMs" to firstFrameDurationMs,
                        "rebufferCount" to rebufferCount,
                        "rebufferDurationMs" to rebufferDurationMs,
                        "droppedVideoFrames" to droppedVideoFrames,
                        "audioUnderruns" to audioUnderruns,
                        "estimatedBitrate" to selectedVideoBitrate,
                        "bufferedDurationMs" to bufferedDuration,
                        "bufferedBytes" to loadControl.allocatedBytes,
                        "liveOffsetMs" to liveOffset,
                        "reconnectCount" to reconnectCount,
                        "androidDeviceTier" to deviceProfile.tier.wireName,
                        "targetBufferBytes" to loadControl.targetBufferBytes,
                        "adaptiveDowngradeCount" to adaptiveDowngradeCount,
                        "surfaceRebuildCount" to
                            (videoOutput.surfaceRebuildCount - surfaceRebuildBaseline).coerceAtLeast(0),
                        "selectedVideoBitrate" to selectedVideoBitrate,
                    ),
                    "error" to (error ?: currentError),
                ),
            ),
        )
    }

    fun dispose() {
        if (disposed) return
        lifecycle.reduce(YlLifecycleEvent.DISPOSE)
        disposed = true
        sourceGeneration += 1
        cancelFocusGrace()
        handler.removeCallbacksAndMessages(null)
        exoPlayer.removeListener(this)
        exoPlayer.removeAnalyticsListener(this)
        videoOutput.dispose(exoPlayer::clearVideoSurface)
        exoPlayer.release()
        httpClient.dispatcher.cancelAll()
        httpClient.connectionPool.evictAll()
        httpClient.dispatcher.executorService.shutdown()
    }

    private fun cancelFocusGrace() {
        handler.removeCallbacks(focusGraceRunnable)
    }

    private fun isCurrentEvent(eventTime: AnalyticsListener.EventTime): Boolean {
        if (eventTime.timeline.isEmpty || eventTime.windowIndex == C.INDEX_UNSET) {
            return exoPlayer.currentMediaItem?.mediaId == sourceGeneration.toString()
        }
        return runCatching {
            val item = eventTime.timeline
                .getWindow(eventTime.windowIndex, Timeline.Window())
                .mediaItem
            item.mediaId == sourceGeneration.toString()
        }.getOrDefault(false)
    }
}

private data class AudioSelection(val group: Tracks.Group, val trackIndex: Int)

private data class AndroidQualityConstraint(
    val maxWidth: Int? = null,
    val maxHeight: Int? = null,
    val maxBitrate: Int? = null,
)

private data class PlayerConfiguration(
    val bufferMode: String,
    val decoderPolicy: String,
    val minBufferMs: Int?,
    val maxBufferMs: Int?,
    val maxBufferBytes: Int?,
    val positionEventIntervalMs: Long,
    val network: NetworkConfiguration,
) {
    fun bufferRequest() = YlBufferRequest(
        mode = bufferMode,
        minBufferMs = minBufferMs,
        maxBufferMs = maxBufferMs,
        maxBufferBytes = maxBufferBytes,
    )

    companion object {
        fun from(map: Map<String, Any?>): PlayerConfiguration {
            val network = map["network"].asStringMap()
            return PlayerConfiguration(
                bufferMode = map["bufferMode"] as? String ?: "automatic",
                decoderPolicy = map["decoderPolicy"] as? String ?: "preferHardware",
                minBufferMs = (map["minBufferMs"] as? Number)?.toInt(),
                maxBufferMs = (map["maxBufferMs"] as? Number)?.toInt(),
                maxBufferBytes = (map["maxBufferBytes"] as? Number)?.toInt(),
                positionEventIntervalMs = ((map["positionEventIntervalMs"] as? Number)?.toLong() ?: 250L)
                    .coerceIn(100L, 2_000L),
                network = NetworkConfiguration(
                    connectTimeoutMs = (network["connectTimeoutMs"] as? Number)?.toInt() ?: 10_000,
                    readTimeoutMs = (network["readTimeoutMs"] as? Number)?.toInt() ?: 15_000,
                    maxRetries = (network["maxRetries"] as? Number)?.toInt() ?: 3,
                    baseRetryDelayMs = (network["baseRetryDelayMs"] as? Number)?.toLong() ?: 500L,
                    maxRetryDelayMs = (network["maxRetryDelayMs"] as? Number)?.toLong() ?: 8_000L,
                    maxRedirects = (network["maxRedirects"] as? Number)?.toInt() ?: 5,
                ),
            )
        }
    }
}

private class PlayerCommandException(
    val code: String,
    override val message: String,
    val details: Map<String, Any?>,
) : RuntimeException(message)

private fun MethodChannel.Result.playerError(code: String, message: String, error: Throwable) {
    error(
        code,
        message,
        errorMap("internal", code, message, error.stackTraceToString()),
    )
}

private fun playbackErrorMap(error: PlaybackException, diagnostic: String?): Map<String, Any?> {
    val stableFailure = when (error.errorCode) {
        PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED ->
            YlPlaybackFailure.NO_HARDWARE_DECODER
        PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES ->
            YlPlaybackFailure.CAPABILITY_EXCEEDED
        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED ->
            YlPlaybackFailure.DECODER_INITIALIZATION
        else -> null
    }
    if (stableFailure != null) {
        val stable = stableError(stableFailure)
        return errorMap(stable.category, stable.code, stable.message, diagnostic)
    }
    val category = when (error.errorCode) {
        PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
        PlaybackException.ERROR_CODE_IO_CLEARTEXT_NOT_PERMITTED,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
        PlaybackException.ERROR_CODE_IO_UNSPECIFIED,
        -> "network"
        PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
        PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
        -> "decoderUnsupported"
        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FAILED,
        -> "decoderFailure"
        PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED,
        PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
        -> "container"
        else -> "internal"
    }
    return errorMap(
        category,
        "media3.${error.errorCodeName.lowercase()}",
        error.message ?: "Media3 playback failed.",
        diagnostic,
    )
}

private fun errorMap(
    category: String,
    code: String,
    message: String,
    diagnostic: String? = null,
): Map<String, Any?> = mapOf(
    "category" to category,
    "code" to code,
    "message" to message,
    "platformDiagnostic" to diagnostic,
)

private fun Any?.asStringMap(): Map<String, Any?> {
    val source = this as? Map<*, *> ?: return emptyMap()
    return source.entries.associate { it.key.toString() to it.value }
}

private fun Int.valueOrNull(): Int? = takeUnless { it == C.LENGTH_UNSET }

private fun mimeType(formatHint: String?): String? = when (formatHint) {
    "hls" -> MimeTypes.APPLICATION_M3U8
    "httpFlv", "flv" -> MimeTypes.VIDEO_FLV
    "mp4" -> MimeTypes.VIDEO_MP4
    "mov" -> "video/quicktime"
    "matroska" -> MimeTypes.VIDEO_MATROSKA
    "webm" -> MimeTypes.VIDEO_WEBM
    "mpegTs" -> MimeTypes.VIDEO_MP2T
    "mpegPs" -> MimeTypes.VIDEO_MPEG2
    "avi" -> "video/x-msvideo"
    else -> null
}

private fun hardwareVideoCodecs(): List<String> = runCatching {
    MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
        .asSequence()
        .filter { !it.isEncoder }
        .filter(::isPlatformHardwareCodec)
        .flatMap { it.supportedTypes.asSequence() }
        .filter { it.startsWith("video/") }
        .distinct()
        .sorted()
        .toList()
}.getOrDefault(emptyList())

private fun isPlatformHardwareCodec(info: MediaCodecInfo): Boolean {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return info.isHardwareAccelerated
    val name = info.name.lowercase()
    return !name.startsWith("omx.google.") &&
        !name.startsWith("c2.android.") &&
        !name.contains("software") &&
        !name.contains("sw.")
}
