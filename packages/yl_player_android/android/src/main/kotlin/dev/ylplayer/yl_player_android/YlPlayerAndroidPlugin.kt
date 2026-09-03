package dev.ylplayer.yl_player_android

import android.content.Context
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Surface
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import kotlin.math.max

@OptIn(UnstableApi::class)
class YlPlayerAndroidPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private lateinit var applicationContext: Context
    private lateinit var textures: TextureRegistry
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private val players = mutableMapOf<Long, Media3Player>()
    private var nextPlayerId = 1L
    private var eventSink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
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
        players.values.toList().forEach(Media3Player::dispose)
        players.clear()
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
        try {
            val arguments = call.arguments.asStringMap()
            val configuration = PlayerConfiguration.from(arguments["configuration"].asStringMap())
            val playerId = nextPlayerId++
            val texture = textures.createSurfaceTexture()
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
            player.command(root["name"] as? String ?: "", root["arguments"].asStringMap())
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
}

@OptIn(UnstableApi::class)
private class Media3Player(
    private val context: Context,
    private val playerId: Long,
    private val texture: TextureRegistry.SurfaceTextureEntry,
    private val configuration: PlayerConfiguration,
    private val emit: (Map<String, Any?>) -> Unit,
) : Player.Listener {
    private val handler = Handler(Looper.getMainLooper())
    private val surface = Surface(texture.surfaceTexture())
    private val trackSelector = DefaultTrackSelector(context)
    private val exoPlayer: ExoPlayer
    private val audioSelections = mutableMapOf<String, AudioSelection>()
    private var sourceIsLive = false
    private var disposed = false
    private var status = "idle"
    private var openStartedAtMs: Long? = null
    private var openDurationMs: Long? = null
    private var firstFrameDurationMs: Long? = null
    private var hasBeenReady = false
    private var rebufferCount = 0
    private var bufferingStartedAtMs: Long? = null
    private var rebufferDurationMs = 0L
    private var lastVideoSize = VideoSize.UNKNOWN
    private var audioTracks: List<Map<String, Any?>> = emptyList()
    private var videoTracks: List<Map<String, Any?>> = emptyList()
    private val positionTicker = object : Runnable {
        override fun run() {
            if (!disposed) {
                emitState()
                handler.postDelayed(this, configuration.positionEventIntervalMs)
            }
        }
    }

    init {
        val renderersFactory = DefaultRenderersFactory(context)
            .setEnableDecoderFallback(configuration.decoderPolicy != "hardwareOnly")
        if (configuration.decoderPolicy == "hardwareOnly") {
            renderersFactory.setMediaCodecSelector(hardwareOnlyCodecSelector())
        }
        exoPlayer = ExoPlayer.Builder(context, renderersFactory)
            .setTrackSelector(trackSelector)
            .setLoadControl(configuration.createLoadControl())
            .build()
        trackSelector.parameters = trackSelector.buildUponParameters()
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
            .build()
        exoPlayer.setVideoSurface(surface)
        exoPlayer.addListener(this)
        handler.post(positionTicker)
    }

    fun command(name: String, arguments: Map<String, Any?>) {
        check(!disposed) { "Player is disposed." }
        when (name) {
            "open" -> open(arguments["source"].asStringMap())
            "play" -> exoPlayer.play()
            "pause" -> exoPlayer.pause()
            "seekTo" -> exoPlayer.seekTo((arguments["positionMs"] as? Number)?.toLong() ?: 0L)
            "seekToLiveEdge" -> {
                if (!exoPlayer.isCurrentMediaItemLive) {
                    throw PlayerCommandException(
                        "source.not_live",
                        "The current source is not live.",
                        errorMap("source", "source.not_live", "The current source is not live."),
                    )
                }
                exoPlayer.seekToDefaultPosition()
            }
            "setPlaybackSpeed" -> {
                val speed = (arguments["speed"] as? Number)?.toFloat() ?: 1f
                require(speed in 0.25f..4f) { "Playback speed must be between 0.25 and 4.0." }
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

    private fun open(source: Map<String, Any?>) {
        val uriString = source["uri"] as? String
            ?: throw PlayerCommandException(
                "source.invalid_uri",
                "A media URI is required.",
                errorMap("source", "source.invalid_uri", "A media URI is required."),
            )
        sourceIsLive = source["isLive"] == true
        val headers = source["headers"].asStringMap().mapValues { it.value.toString() }
        val network = configuration.network
        val httpFactory = DefaultHttpDataSource.Factory()
            .setConnectTimeoutMs(network.connectTimeoutMs)
            .setReadTimeoutMs(network.readTimeoutMs)
            .setAllowCrossProtocolRedirects(true)
            .setDefaultRequestProperties(headers)
        val dataSourceFactory = DefaultDataSource.Factory(context, httpFactory)
        val mediaSourceFactory = DefaultMediaSourceFactory(dataSourceFactory)
            .setLoadErrorHandlingPolicy(DefaultLoadErrorHandlingPolicy(network.maxRetries))
        val mediaItem = MediaItem.Builder()
            .setUri(Uri.parse(uriString))
            .setMimeType(mimeType(source["formatHint"] as? String))
            .build()

        openStartedAtMs = SystemClock.elapsedRealtime()
        openDurationMs = null
        firstFrameDurationMs = null
        hasBeenReady = false
        rebufferCount = 0
        rebufferDurationMs = 0L
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
        val width = (constraint["maxWidth"] as? Number)?.toInt() ?: Int.MAX_VALUE
        val height = (constraint["maxHeight"] as? Number)?.toInt() ?: Int.MAX_VALUE
        val bitrate = (constraint["maxBitrate"] as? Number)?.toInt() ?: Int.MAX_VALUE
        trackSelector.parameters = trackSelector.buildUponParameters()
            .setMaxVideoSize(width, height)
            .setMaxVideoBitrate(bitrate)
            .build()
    }

    override fun onPlaybackStateChanged(playbackState: Int) {
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
        if (exoPlayer.playbackState == Player.STATE_READY) {
            status = if (isPlaying) "playing" else "paused"
            emitState()
        }
    }

    override fun onVideoSizeChanged(videoSize: VideoSize) {
        lastVideoSize = videoSize
        if (videoSize.width > 0 && videoSize.height > 0) {
            texture.surfaceTexture().setDefaultBufferSize(videoSize.width, videoSize.height)
        }
        emitState()
    }

    override fun onRenderedFirstFrame() {
        firstFrameDurationMs = openStartedAtMs?.let { SystemClock.elapsedRealtime() - it }
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

    override fun onPlayerError(error: PlaybackException) {
        status = "error"
        val details = playbackErrorMap(error)
        emit(mapOf("playerId" to playerId, "type" to "error", "error" to details))
        emitState(details)
    }

    fun emitState(error: Map<String, Any?>? = null) {
        if (disposed) return
        val duration = exoPlayer.duration.takeUnless { it == C.TIME_UNSET || it < 0 }
        val liveOffset = exoPlayer.currentLiveOffset.takeUnless { it == C.TIME_UNSET || it < 0 }
        val bufferedDuration = max(0L, exoPlayer.bufferedPosition - exoPlayer.currentPosition)
        emit(
            mapOf(
                "playerId" to playerId,
                "type" to "state",
                "state" to mapOf(
                    "status" to status,
                    "positionMs" to max(0L, exoPlayer.currentPosition),
                    "durationMs" to duration,
                    "bufferedPositionMs" to max(0L, exoPlayer.bufferedPosition),
                    "isLive" to (sourceIsLive || exoPlayer.isCurrentMediaItemLive),
                    "isSeekable" to exoPlayer.isCurrentMediaItemSeekable,
                    "isAtLiveEdge" to (liveOffset != null && liveOffset <= 2_000L),
                    "liveOffsetMs" to liveOffset,
                    "dvrStartMs" to if (exoPlayer.isCurrentMediaItemSeekable) 0L else null,
                    "dvrEndMs" to if (exoPlayer.isCurrentMediaItemSeekable) duration else null,
                    "videoWidth" to lastVideoSize.width.takeIf { it > 0 },
                    "videoHeight" to lastVideoSize.height.takeIf { it > 0 },
                    "engine" to "media3",
                    "isHardwareDecoding" to false,
                    "decoderName" to null,
                    "audioTracks" to audioTracks,
                    "videoTracks" to videoTracks,
                    "capabilities" to capabilities(),
                    "metrics" to mapOf(
                        "openDurationMs" to openDurationMs,
                        "firstFrameDurationMs" to firstFrameDurationMs,
                        "rebufferCount" to rebufferCount,
                        "rebufferDurationMs" to rebufferDurationMs,
                        "bufferedDurationMs" to bufferedDuration,
                        "liveOffsetMs" to liveOffset,
                    ),
                    "error" to error,
                ),
            ),
        )
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        handler.removeCallbacksAndMessages(null)
        exoPlayer.removeListener(this)
        exoPlayer.clearVideoSurface(surface)
        exoPlayer.release()
        surface.release()
        texture.release()
    }

    private fun capabilities(): Map<String, Any?> = mapOf(
        "hardwareVideoCodecs" to hardwareVideoCodecs(),
        "supportedFormats" to listOf(
            "automatic", "hls", "httpFlv", "mp4", "matroska", "webm", "mpegTs", "mpegPs", "flv",
        ),
        "maxConcurrentVideoDecoders" to 1,
    )
}

private data class AudioSelection(val group: Tracks.Group, val trackIndex: Int)

private data class NetworkConfiguration(
    val connectTimeoutMs: Int,
    val readTimeoutMs: Int,
    val maxRetries: Int,
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
    @OptIn(UnstableApi::class)
    fun createLoadControl(): DefaultLoadControl {
        val defaults = when (bufferMode) {
            "lowLatency" -> intArrayOf(1_000, 5_000, 300, 800)
            "stable" -> intArrayOf(15_000, 50_000, 2_500, 5_000)
            else -> intArrayOf(5_000, 20_000, 1_000, 2_000)
        }
        val minBuffer = minBufferMs ?: defaults[0]
        val maxBuffer = max(maxBufferMs ?: defaults[1], minBuffer)
        val targetBufferBytes = maxBufferBytes ?: when (bufferMode) {
            "lowLatency" -> 24 * 1024 * 1024
            "stable" -> 96 * 1024 * 1024
            else -> 48 * 1024 * 1024
        }
        return DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                minBuffer,
                maxBuffer,
                defaults[2].coerceAtMost(minBuffer),
                defaults[3].coerceAtMost(minBuffer),
            )
            .setTargetBufferBytes(targetBufferBytes)
            .setPrioritizeTimeOverSizeThresholds(true)
            .build()
    }

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

private fun playbackErrorMap(error: PlaybackException): Map<String, Any?> {
    val category = when (error.errorCode) {
        PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
        PlaybackException.ERROR_CODE_IO_CLEARTEXT_NOT_PERMITTED,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
        PlaybackException.ERROR_CODE_IO_UNSPECIFIED,
        -> "network"
        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
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
        error.stackTraceToString(),
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
        .filter(::isHardwareCodec)
        .flatMap { it.supportedTypes.asSequence() }
        .filter { it.startsWith("video/") }
        .distinct()
        .sorted()
        .toList()
}.getOrDefault(emptyList())

private fun isHardwareCodec(info: MediaCodecInfo): Boolean {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return info.isHardwareAccelerated
    val name = info.name.lowercase()
    return !name.startsWith("omx.google.") &&
        !name.startsWith("c2.android.") &&
        !name.contains("software") &&
        !name.contains("sw.")
}

@OptIn(UnstableApi::class)
private fun hardwareOnlyCodecSelector(): MediaCodecSelector = MediaCodecSelector {
        mimeType,
        requiresSecureDecoder,
        requiresTunnelingDecoder,
    ->
    val decoders = MediaCodecSelector.DEFAULT.getDecoderInfos(
        mimeType,
        requiresSecureDecoder,
        requiresTunnelingDecoder,
    )
    if (MimeTypes.isVideo(mimeType)) decoders.filter { it.hardwareAccelerated } else decoders
}
