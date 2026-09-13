package dev.ylplayer.yl_player_android

import android.content.Context
import android.os.SystemClock
import android.view.Surface
import dev.ylplayer.yl_player_android.pigeon.*
import java.util.concurrent.Executors
import kotlinx.coroutines.*
import kotlinx.coroutines.asCoroutineDispatcher

/** FFmpeg demux + MediaCodec hardware video, with bounded FFmpeg software video/audio fallback. */
internal class YlNativeFallbackEngine(
    private val context: Context,
    private val identity: YlSessionIdentity,
    private val source: AndroidSourceMessage,
    private val options: AndroidLoadOptionsMessage,
    private val playerOptions: AndroidPlayerOptionsMessage,
    dispatcher: CoroutineDispatcher = Dispatchers.Main,
) : YlPlaybackEngineAdapter {
    private val events = CoroutineScope(SupervisorJob() + dispatcher)
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "yl-ffmpeg-${identity.sessionId}").apply { isDaemon = true }
    }.asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + worker)
    private var callback: ((YlSessionIdentity, YlEngineEvent) -> Unit)? = null
    private var session: YlFfmpegSession? = null
    private var video: YlNativeStreamInfo? = null
    private var audio: YlNativeStreamInfo? = null
    private var videoPath = YlNativeVideoPath.UNSUPPORTED
    private var hardwareName: String? = null
    private var hardwareVideo: YlHardwareVideoDecoder? = null
    private var audioOutput: YlPcmAudioOutput? = null
    private var output: YlVideoOutput? = null
    private var outputIdentity: YlOutputIdentity? = null
    private var playbackJob: Job? = null
    @Volatile private var playing = false
    @Volatile private var closed = false
    private var positionUs = options.startPositionMs?.times(1000) ?: 0
    private var monotonicAnchorNs = 0L
    private var positionAnchorUs = positionUs
    private var speed = 1.0
    private var volume = 1.0
    private var firstFrame = false
    private var firstFrameAtMs = 0L
    private var preparedAtMs = 0L
    private var readyAtMs = 0L
    private var selectedAudioIndex = -1
    private var playbackGeneration = 0L
    override val needsExclusiveLease: Boolean get() = video != null

    override fun registerCallback(callback: (YlSessionIdentity, YlEngineEvent) -> Unit) { this.callback = callback }

    override suspend fun prepare() = withContext(worker) {
        preparedAtMs = SystemClock.elapsedRealtime()
        val byteSource = YlNativeByteSourceFactory.create(context, source, options) { index, delay ->
            emit(YlEngineEvent.Retry(index.toLong(), delay, SystemClock.elapsedRealtime()))
        }
        val opened = YlFfmpegSession.open(byteSource)
        session = opened
        val media = opened.mediaInfo
        video = selectVideo(media.streams)
        audio = media.streams.firstOrNull { it.kind == YlNativeStreamKind.AUDIO && it.codec in supportedAudio }
        selectedAudioIndex = audio?.index ?: -1
        video?.let { stream ->
            hardwareName = YlHardwareCodecProbe.findVideoDecoder(stream)
            videoPath = YlNativePlaybackPlanner { hardwareName != null }.chooseVideoPath(stream)
            if (options.decoderPolicyOverride == AndroidDecoderPolicy.HARDWARE_REQUIRED ||
                playerOptions.decoderPolicy == AndroidDecoderPolicy.HARDWARE_REQUIRED) {
                if (videoPath != YlNativeVideoPath.HARDWARE) throw YlBoundaryException(YlFailureKind.DECODER_UNAVAILABLE)
            }
            if (videoPath == YlNativeVideoPath.UNSUPPORTED) throw YlBoundaryException(YlFailureKind.DECODER_UNSUPPORTED)
        }
        if (video == null && audio == null) throw YlBoundaryException(YlFailureKind.DECODER_UNSUPPORTED)
        audio?.let { audioOutput = YlPcmAudioOutput(opened, it) }
        emitSnapshot(AndroidPlaybackStatus.LOADING, reachedReady = false)
    }

    private fun selectVideo(streams: List<YlNativeStreamInfo>): YlNativeStreamInfo? {
        val constraints = options.videoConstraints
        return streams.filter { it.kind == YlNativeStreamKind.VIDEO }
            .filter { constraints.maxWidth == null || it.width <= constraints.maxWidth }
            .filter { constraints.maxHeight == null || it.height <= constraints.maxHeight }
            .filter { constraints.maxBitrate == null || it.bitrate <= 0 || it.bitrate <= constraints.maxBitrate }
            .maxByOrNull { it.width.toLong() * it.height }
            ?: streams.firstOrNull { it.kind == YlNativeStreamKind.VIDEO }
    }

    override suspend fun activate(output: YlSessionVideoOutput) = withContext(worker) {
        val public = output as YlVideoOutput
        val surface = public.borrowSurface()
        this@YlNativeFallbackEngine.output = public
        outputIdentity = public.identity
        configureVideo(surface)
        video?.let { public.updateGeometry(geometry(it)) }
        readyAtMs = SystemClock.elapsedRealtime()
        emitSnapshot(AndroidPlaybackStatus.READY, reachedReady = true)
        ensureLoop()
    }

    private fun configureVideo(surface: Surface) {
        val stream = video ?: return
        val native = requireSession()
        if (videoPath == YlNativeVideoPath.HARDWARE) {
            val configured = native.configureHardwareVideo(stream.index)
            if (configured) {
                hardwareVideo = runCatching {
                    YlHardwareVideoDecoder(stream, surface, checkNotNull(hardwareName), native.hardwareCodecConfig())
                }.getOrNull()
            }
            if (hardwareVideo == null) {
                val allowSoftware = options.decoderPolicyOverride != AndroidDecoderPolicy.HARDWARE_REQUIRED &&
                    playerOptions.decoderPolicy != AndroidDecoderPolicy.HARDWARE_REQUIRED &&
                    YlNativePlaybackPlanner { false }.chooseVideoPath(stream) == YlNativeVideoPath.SOFTWARE
                if (!allowSoftware) throw YlBoundaryException(YlFailureKind.DECODER_UNAVAILABLE)
                videoPath = YlNativeVideoPath.SOFTWARE
            }
        }
        if (videoPath == YlNativeVideoPath.SOFTWARE && !native.configureSoftwareVideo(stream.index, surface)) {
            throw YlBoundaryException(YlFailureKind.DECODER_UNSUPPORTED)
        }
    }

    private fun ensureLoop() {
        if (playbackJob?.isActive == true) return
        playbackJob = scope.launch {
            try {
                val pendingHardwareVideo = ArrayDeque<YlNativePacket>()
                val softwareVideoFrames = if (videoPath == YlNativeVideoPath.SOFTWARE) {
                    YlSoftwareVideoFrames(
                        decodeFrameTimestamps = { requireSession().decodeSoftwareVideo(it) },
                        renderNextFrame = { requireSession().renderSoftwareVideoFrame() },
                        finishDecoding = { requireSession().finishSoftwareVideo() },
                    )
                } else {
                    null
                }
                var generation = playbackGeneration
                while (isActive && !closed) {
                    if (!playing) { delay(10); continue }
                    if (generation != playbackGeneration) {
                        pendingHardwareVideo.clear()
                        softwareVideoFrames?.clear()
                        generation = playbackGeneration
                    }
                    if (audioOutput?.hasPendingData == true) {
                        val written = audioOutput?.drainPending() ?: 0
                        drainDueVideo(pendingHardwareVideo)
                        softwareVideoFrames?.let { markFirstFrame(it.renderDue(currentPositionUs())) }
                        positionUs = currentPositionUs()
                        if (written == 0) delay(AUDIO_DRAIN_RETRY_MS) else yield()
                        continue
                    }
                    val packet = requireSession().readPacket()
                    if (packet == null) {
                        while (pendingHardwareVideo.isNotEmpty() && playing) {
                            renderWhenDue(pendingHardwareVideo.removeFirst())
                        }
                        softwareVideoFrames?.let { frames ->
                            frames.finish()
                            while (frames.bufferedCount > 0 && playing) renderSoftwareWhenDue(frames)
                        }
                        playing = false; audioOutput?.pause(); emitSnapshot(AndroidPlaybackStatus.COMPLETED, true); break
                    }
                    when (packet.streamIndex) {
                        selectedAudioIndex -> {
                            audioOutput?.consume(packet)
                            drainDueVideo(pendingHardwareVideo)
                            softwareVideoFrames?.let { markFirstFrame(it.renderDue(currentPositionUs())) }
                        }
                        video?.index -> {
                            if (softwareVideoFrames != null) {
                                while (softwareVideoFrames.bufferedCount >= MAX_SOFTWARE_VIDEO_FRAMES && playing) {
                                    renderSoftwareWhenDue(softwareVideoFrames)
                                }
                                softwareVideoFrames.decode(packet)
                                markFirstFrame(softwareVideoFrames.renderDue(currentPositionUs()))
                            } else {
                                pendingHardwareVideo.addLast(packet)
                                drainDueVideo(pendingHardwareVideo)
                                if (pendingHardwareVideo.size > 30) {
                                    renderWhenDue(pendingHardwareVideo.removeFirst())
                                }
                            }
                        }
                    }
                    positionUs = currentPositionUs()
                    emit(YlEngineEvent.Tick(timeline(), metrics()))
                    yield()
                }
            } catch (_: CancellationException) {
                Unit
            } catch (error: Throwable) {
                if (!closed) emit(YlEngineEvent.Failed((error as? YlBoundaryException)?.kind ?: YlFailureKind.PLATFORM_FAILURE))
            }
        }
    }

    private fun drainDueVideo(pending: ArrayDeque<YlNativePacket>) {
        while (pending.isNotEmpty()) {
            val pts = pending.first().presentationTimeUs
            if (YlVideoPacingPolicy.action(pts, currentPositionUs()) == YlVideoPacingAction.WAIT) return
            renderVideo(pending.removeFirst())
        }
    }

    private suspend fun renderWhenDue(packet: YlNativePacket) {
        val pts = packet.presentationTimeUs
        if (pts != Long.MIN_VALUE) {
            while (playing) {
                val aheadUs = pts - currentPositionUs()
                if (YlVideoPacingPolicy.action(pts, currentPositionUs()) == YlVideoPacingAction.PRESENT) break
                delay((aheadUs / 1000).coerceIn(1, 20))
            }
        }
        renderVideo(packet)
    }

    private suspend fun renderSoftwareWhenDue(frames: YlSoftwareVideoFrames) {
        val pts = frames.nextPresentationTimeUs ?: return
        if (pts != Long.MIN_VALUE) {
            while (playing) {
                val clockUs = currentPositionUs()
                val aheadUs = pts - clockUs
                if (YlVideoPacingPolicy.action(pts, clockUs) == YlVideoPacingAction.PRESENT) break
                delay((aheadUs / 1000).coerceIn(1, 20))
            }
        }
        if (playing) {
            frames.renderNext()
            markFirstFrame(1)
        }
    }

    private fun renderVideo(packet: YlNativePacket) {
        if (hardwareVideo?.consume(packet) == true) markFirstFrame(1)
    }

    private fun markFirstFrame(renderedCount: Int) {
        if (renderedCount > 0 && !firstFrame) {
            firstFrame = true
            firstFrameAtMs = SystemClock.elapsedRealtime()
            outputIdentity?.let { emit(YlEngineEvent.FirstFrame(it, firstFrameAtMs)) }
        }
    }

    override suspend fun play() = withContext(worker) {
        positionAnchorUs = currentPositionUs()
        monotonicAnchorNs = System.nanoTime()
        playing = true
        audioOutput?.play()
        emitSnapshot(AndroidPlaybackStatus.PLAYING, true)
        ensureLoop()
    }
    override suspend fun pause() = withContext(worker) {
        positionUs = currentPositionUs()
        playing = false
        audioOutput?.pause()
        emitSnapshot(AndroidPlaybackStatus.PAUSED, true)
    }
    override suspend fun seekTo(positionMs: Long) = withContext(worker) {
        val targetUs = positionMs.coerceAtLeast(0) * 1000
        if (!requireSession().seekTo(targetUs)) throw YlBoundaryException(YlFailureKind.SOURCE_INVALID)
        hardwareVideo?.flush(); audioOutput?.flush(); requireSession().flush()
        playbackGeneration++
        positionUs = targetUs; positionAnchorUs = targetUs; monotonicAnchorNs = System.nanoTime(); firstFrame = false
        firstFrameAtMs = 0L
        emitSnapshot(if (playing) AndroidPlaybackStatus.PLAYING else AndroidPlaybackStatus.PAUSED, true)
    }
    override suspend fun seekToLiveEdge() {
        if (source.intent != AndroidStreamIntent.LIVE) throw YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED)
        withContext(worker) {
            if (!requireSession().seekTo(Long.MAX_VALUE)) throw YlBoundaryException(YlFailureKind.SOURCE_INVALID)
            hardwareVideo?.flush(); audioOutput?.flush(); requireSession().flush(); firstFrame = false
            firstFrameAtMs = 0L
            playbackGeneration++
        }
    }
    override suspend fun setPlaybackSpeed(speed: Double) = withContext(worker) {
        positionUs = currentPositionUs(); positionAnchorUs = positionUs; monotonicAnchorNs = System.nanoTime()
        this@YlNativeFallbackEngine.speed = speed; audioOutput?.setSpeed(speed)
        Unit
    }
    override suspend fun selectAudioTrack(trackId: String) = withContext(worker) {
        val index = trackId.removePrefix("ffmpeg-audio-").toIntOrNull()
            ?: throw YlBoundaryException(YlFailureKind.SOURCE_MISSING)
        val stream = requireSession().mediaInfo.streams.firstOrNull { it.index == index && it.kind == YlNativeStreamKind.AUDIO }
            ?: throw YlBoundaryException(YlFailureKind.SOURCE_MISSING)
        audioOutput?.close(); selectedAudioIndex = index; audio = stream
        audioOutput = YlPcmAudioOutput(requireSession(), stream).also { it.setVolume(volume); it.setSpeed(speed); if (playing) it.play() }
        requireSession().seekTo(positionUs); requireSession().flush()
        playbackGeneration++
        Unit
    }
    override suspend fun setVideoConstraints(constraints: AndroidVideoConstraintsMessage) {
        val stream = video ?: return
        if ((constraints.maxWidth != null && stream.width > constraints.maxWidth) ||
            (constraints.maxHeight != null && stream.height > constraints.maxHeight) ||
            (constraints.maxBitrate != null && stream.bitrate > constraints.maxBitrate)) {
            throw YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED)
        }
    }
    override suspend fun setVolume(volume: Double) = withContext(worker) {
        this@YlNativeFallbackEngine.volume = volume; audioOutput?.setVolume(volume)
        Unit
    }
    override suspend fun stop() { session?.cancel(); closePlayback() }
    override suspend fun quiesce(): YlEngineRestorePoint = withContext(worker) {
        val point = YlEngineRestorePoint(currentPositionUs() / 1000, source.intent == AndroidStreamIntent.LIVE,
            playing, audio?.let { "ffmpeg-audio-${it.index}" }, video?.let { listOf("ffmpeg-video-${it.index}") }.orEmpty(),
            speed, volume, options.videoConstraints.maxWidth, options.videoConstraints.maxHeight, options.videoConstraints.maxBitrate)
        playing = false; audioOutput?.pause(); point
    }
    override suspend fun restore(point: YlEngineRestorePoint, output: YlSessionVideoOutput) {
        activate(output); seekTo(point.positionMs); setPlaybackSpeed(point.speed); setVolume(point.volume)
        if (point.playbackIntended) play() else pause()
    }
    override suspend fun onForeground() = Unit
    override suspend fun onBackground() = pause()
    override suspend fun onTrimMemory(level: Int) = Unit
    override suspend fun onConfigurationChanged() = withContext(worker) {
        val public = output ?: return@withContext
        val surface = public.recreateBorrowedSurface()
        hardwareVideo?.replaceSurface(surface) ?: video?.let { stream ->
            if (!requireSession().configureSoftwareVideo(stream.index, surface)) {
                throw YlBoundaryException(YlFailureKind.PLATFORM_FAILURE)
            }
            playbackGeneration++
        }
        public.acknowledgeReplacement(surface)
        outputIdentity = public.identity
    }

    private suspend fun closePlayback() = withContext(worker) {
        playing = false; playbackJob?.cancel(); playbackJob = null
        hardwareVideo?.close(); hardwareVideo = null
        audioOutput?.close(); audioOutput = null
        session?.close(); session = null
    }
    override fun dispose(): Deferred<Unit> {
        closed = true
        session?.cancel()
        val result = CompletableDeferred<Unit>()
        scope.launch {
            runCatching { closePlayback() }.onSuccess { result.complete(Unit) }.onFailure(result::completeExceptionally)
            events.cancel(); scope.cancel(); worker.close()
        }
        return result
    }

    private fun currentPositionUs(): Long = audioOutput?.positionUs() ?: if (playing && monotonicAnchorNs != 0L) {
        positionAnchorUs + ((System.nanoTime() - monotonicAnchorNs) / 1000 * speed).toLong()
    } else positionUs
    private fun timeline() = AndroidTimelineMessage(currentPositionUs().coerceAtLeast(0) / 1000,
        requireSession().mediaInfo.durationUs.takeIf { it >= 0 }?.div(1000), currentPositionUs().coerceAtLeast(0) / 1000,
        requireSession().mediaInfo.seekable, source.intent == AndroidStreamIntent.LIVE,
        isAtLiveEdge = source.intent == AndroidStreamIntent.LIVE)
    private fun metrics() = AndroidMetricsMessage(
        loadToReadyMs = readyAtMs.takeIf { it > 0 }?.minus(preparedAtMs),
        loadToFirstFrameMs = firstFrameAtMs.takeIf { it > 0 }?.minus(preparedAtMs),
    )
    private fun geometry(stream: YlNativeStreamInfo) = AndroidVideoGeometryMessage(
        AndroidSizeMessage(stream.width.toDouble(), stream.height.toDouble()),
        AndroidSizeMessage(stream.width.toDouble(), stream.height.toDouble()), 1.0, 0)
    private fun emitSnapshot(status: AndroidPlaybackStatus, reachedReady: Boolean) = emit(YlEngineEvent.Snapshot(YlEngineSnapshot(
        status, timeline(), video?.let(::geometry), audioTracks(), videoTracks(),
        if (videoPath == YlNativeVideoPath.HARDWARE) AndroidDecoderMode.HARDWARE else AndroidDecoderMode.SOFTWARE,
        hardwareName ?: video?.let { "ffmpeg-${it.codec.name.lowercase()}" }, metrics(), reachedReady)))
    private fun audioTracks() = requireSession().mediaInfo.streams.filter { it.kind == YlNativeStreamKind.AUDIO }.map {
        AndroidTrackMessage("ffmpeg-audio-${it.index}", AndroidTrackKind.AUDIO, language = it.language,
            codec = it.codec.name.lowercase(), bitrate = it.bitrate.takeIf { value -> value > 0 }, isSelected = it.index == selectedAudioIndex)
    }
    private fun videoTracks() = video?.let {
        listOf(AndroidTrackMessage("ffmpeg-video-${it.index}", AndroidTrackKind.VIDEO, codec = it.codec.name.lowercase(),
            bitrate = it.bitrate.takeIf { value -> value > 0 }, width = it.width.toLong(), height = it.height.toLong(), isSelected = true))
    }.orEmpty()
    private fun emit(event: YlEngineEvent) { events.launch { if (!closed) callback?.invoke(identity, event) } }
    private fun requireSession() = checkNotNull(session)

    companion object {
        private const val AUDIO_DRAIN_RETRY_MS = 2L
        private const val MAX_SOFTWARE_VIDEO_FRAMES = 30
        private val supportedAudio = setOf(YlNativeCodec.AAC, YlNativeCodec.MP3, YlNativeCodec.AC3,
            YlNativeCodec.EAC3, YlNativeCodec.DTS, YlNativeCodec.FLAC, YlNativeCodec.OPUS, YlNativeCodec.VORBIS)
    }
}
