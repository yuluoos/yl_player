package dev.ylplayer.yl_player_android

import android.content.Context
import android.content.ComponentCallbacks2
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import dev.ylplayer.yl_player_android.pigeon.*
import io.flutter.view.TextureRegistry
import kotlinx.coroutines.*
import kotlinx.coroutines.android.asCoroutineDispatcher

/** The application Looper for every Media3 call is an explicitly owned worker. Its startup,
 * surface replacement, foreground-mode release and player release execute off main.
 * SurfaceHolder destruction is the one synchronous main-to-worker lifetime barrier.
 * Coordinator, Flutter texture access and the callback ingress remain on main.
 */
@OptIn(UnstableApi::class)
internal class YlMedia3Engine(
    private val context: Context,
    private val identity: YlSessionIdentity,
    private val source: AndroidSourceMessage,
    private val options: AndroidLoadOptionsMessage,
    private val playerOptions: AndroidPlayerOptionsMessage,
    dispatcher: CoroutineDispatcher = Dispatchers.Main,
    private val protectedPlayback: YlProtectedPlayback? = null,
    // Internal clear-content observation seams; the factory still receives Core's codec policy.
    private val renderersFactory: ((Context, YlVideoOutputObserver) -> YlOutputRenderersFactory)? = null,
    private val surfaceForOutput: ((YlVideoOutput) -> android.view.Surface)? = null,
) : YlPlaybackEngineAdapter {
    init {
        require(protectedPlayback == null || (renderersFactory == null && surfaceForOutput == null)) {
            "Clear-output observation is unavailable for protected playback"
        }
    }
    private val main = CoroutineScope(SupervisorJob() + dispatcher)
    private val cleanup = CoroutineScope(SupervisorJob() + dispatcher)
    private var callback: ((YlSessionIdentity, YlEngineEvent) -> Unit)? = null
    private var publicOutput: YlVideoOutput? = null
    private var closed = false
    private val protectedOutput = protectedPlayback?.let { route ->
        if (route.identity.sessionId != identity.sessionId || source.format != AndroidMediaFormat.DASH) throw YlBoundaryException(YlFailureKind.DRM_CONFIG_INVALID)
        route.registry.register(route.identity, object : YlProtectedOutputPort {
            override suspend fun attach(surface: android.view.Surface, identity: YlOutputIdentity, isCurrent: () -> Boolean) {
                if (closed) throw YlBoundaryException(YlFailureKind.SESSION_STALE)
                onWorker { if (isCurrent()) requireCore().switchProtectedOutput(surface, identity) }
            }
            override suspend fun park() { if (!closed) onWorker { core?.parkProtectedOutput() } }
            override fun detachBeforeDestroy() {
                // Native rendering cannot outlive a borrowed holder. No worker action waits on
                // main. The regular background/transaction paths remain suspendable.
                runBlocking { onWorker { requireCore().detachProtectedHolder() } }
            }
        }) { kind -> if (!closed) callback?.invoke(identity, YlEngineEvent.Failed(kind)) }
    }
    override val protectedSurface get() = protectedPlayback?.identity
    override val presentationIdentity get() = protectedOutput?.outputIdentity
    private var protectedDrm: YlMedia3DrmSessionManager? = null
    private var closeResult: CompletableDeferred<Unit>? = null
    private val worker = cleanup.async(Dispatchers.Default) {
        val thread = HandlerThread("yl-media3-${identity.sessionId}")
        thread.start()
        // HandlerThread.getLooper can wait during startup; never call it on main.
        val handler = Handler(thread.looper)
        Worker(thread, handler, handler.asCoroutineDispatcher())
    }
    // These fields are exclusively accessed on the owned worker.
    private var core: YlMedia3Core? = null
    private var privateOutput: YlCandidateVideoOutput? = null
    private val decoderGate = YlInitializedDecoderGate(if (protectedPlayback != null) AndroidDecoderPolicy.HARDWARE_REQUIRED else options.decoderPolicyOverride ?: playerOptions.decoderPolicy)
    private val rtmpRecovery = YlRtmpRecovery()
    override fun markCommitted() { rtmpRecovery.committed = true; protectedOutput?.commit() }
    private var exclusive = true // Main-owned; unknown is conservative until READY track evidence.
    override val needsExclusiveLease get() = exclusive
    override val supportsVideoTrackSelection = true

    override fun registerCallback(callback: (YlSessionIdentity, YlEngineEvent) -> Unit) { this.callback = callback }
    private suspend fun <T> onWorker(action: () -> T): T {
        val owner = worker.await()
        return withContext(owner.dispatcher) {
            check(Looper.myLooper() == owner.handler.looper)
            action()
        }
    }
    override suspend fun prepare() {
        val owner = worker.await()
        onWorker {
            val candidate = YlCandidateVideoOutput(context, protectedPlayback != null).also { privateOutput = it }
            protectedDrm = protectedPlayback?.let { route -> YlMedia3DrmSessionManager(route.identity, route.cbcs, route.timeoutMs, route.exchange) }
            core = YlMedia3Core(context, identity, source, options, createMedia3Configuration(source, options, playerOptions),
                owner.handler, YlEngineVideoOutput(candidate), ::receive, rtmpRecovery, decoderGate::resetForEpoch, protectedDrm = protectedDrm, renderersFactoryOverride = renderersFactory)
            requireCore().initialize()
            requireCore().prepare()
        }
    }
    private fun receive(event: YlEngineEvent) {
        // Immutable value is captured on the worker; no mutable latest session ID is consulted.
        when (event) {
            is YlEngineEvent.Snapshot -> decoderGate.accept(event.value)
            is YlEngineEvent.Failed -> decoderGate.fail(event.kind)
            else -> Unit
        }
        val epoch = core?.mediaEpoch
        main.launch {
            if (!closed && (!YlRtmpSourcePolicy.isRtmp(source) || core?.mediaEpoch == epoch)) {
                if (event is YlEngineEvent.Snapshot) { publicOutput?.updateGeometry(event.value.geometry); protectedOutput?.updateGeometry(event.value.geometry) }
                if (event is YlEngineEvent.FirstFrame && protectedOutput != null) {
                    protectedOutput.frame(event.output) { if (!closed) callback?.invoke(identity, event) }
                } else callback?.invoke(identity, event)
            }
        }
    }
    override suspend fun activate(output: YlSessionVideoOutput) {
        val readiness = onWorker { decoderGate.reset(); requireCore().initializeDecoder(); decoderGate.ready }
        val prepared = readiness.await()
        protectedDrm?.awaitUsableKeys()
        requireSelectedVideo(prepared)
        if (YlRtmpSourcePolicy.isRtmp(source) && prepared.videoTracks.none { it.isSelected }) throw YlBoundaryException(YlFailureKind.DECODER_UNAVAILABLE)
        exclusive = prepared.videoTracks.isNotEmpty() || prepared.audioTracks.isEmpty()
        attachPublicOutput(output)
    }
    private suspend fun attachPublicOutput(output: YlSessionVideoOutput) {
        if (protectedOutput != null) { protectedOutput.resumePresentation(); return }
        val video = output as YlVideoOutput
        val surface = surfaceForOutput?.invoke(video) ?: video.borrowSurface() // Main-owned texture access.
        val outputIdentity = video.identity
        publicOutput = video
        onWorker { requireCore().switchOutput(surface, outputIdentity) }
    }
    override suspend fun quiesce(): YlEngineRestorePoint {
        protectedOutput?.suspendPresentation()
        return onWorker { requireCore().snapshotRestorePoint().also { requireCore().deactivate() } }
    }
    override suspend fun restore(point: YlEngineRestorePoint, output: YlSessionVideoOutput) {
        val restored = onWorker {
            decoderGate.reset()
            requireCore().restore(point)
            decoderGate.ready
        }
        restored.await()
        protectedDrm?.awaitUsableKeys()
        attachPublicOutput(output)
        // stop() can clear track groups. Reapply the captured selection only after the restored
        // source reports READY and its current groups exist, never against stale TrackGroups.
        point.selectedAudioTrack?.let { track -> onWorker { requireCore().selectAudioTrack(track) } }
    }
    override suspend fun play() = onWorker { requireCore().play() }
    override suspend fun pause() = onWorker { requireCore().pause() }
    override suspend fun pauseForAudioFocus() = onWorker { requireCore().pauseForAudioFocus() }
    override suspend fun seekTo(positionMs: Long) = onWorker { requireCore().seekTo(positionMs) }
    override suspend fun seekToLiveEdge() = onWorker { requireCore().seekToLiveEdge() }
    override suspend fun setPlaybackSpeed(speed: Double) = onWorker { requireCore().setPlaybackSpeed(speed) }
    override suspend fun selectAudioTrack(trackId: String) = onWorker { requireCore().selectAudioTrack(trackId) }
    override suspend fun selectVideoTrack(trackId: String?) = onWorker { requireCore().selectVideoTrack(trackId) }
    override suspend fun setVideoConstraints(constraints: AndroidVideoConstraintsMessage) = onWorker { requireCore().setVideoConstraints(constraints) }
    override suspend fun setVolume(volume: Double) = onWorker { requireCore().setVolume(volume) }
    override suspend fun stop() { protectedOutput?.suspendPresentation(); onWorker { requireCore().stop() } }
    override suspend fun onForeground() { onWorker { requireCore().restoreAfterForeground() }; protectedOutput?.resumePresentation() }
    override suspend fun onBackground() { protectedOutput?.suspendPresentation(); onWorker { requireCore().releaseForLifecycle() } }
    @Suppress("DEPRECATION")
    override suspend fun onTrimMemory(level: Int) = onWorker {
        if (level >= ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN) core?.releaseForLifecycle()
        else if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) core?.handleRunningLowMemory()
        Unit
    }
    override suspend fun onConfigurationChanged() {
        val output = publicOutput ?: return
        replacePublicVideoOutput(output,
            canRebuild = { onWorker { requireCore().canRebuildOutput() } },
            detach = { onWorker { requireCore().detachOutput() } },
            install = { surface, identity -> onWorker { requireCore().rebuildVideoOutput(surface, identity) } })
    }
    override fun dispose(): Deferred<Unit> {
        closeResult?.let { return it }
        closed = true
        protectedOutput?.retire()
        callback = null
        main.cancel()
        val result = CompletableDeferred<Unit>().also { closeResult = it }
        cleanup.launch {
            try {
                val safe = onWorker {
                    val engine = core
                    if (engine == null) { privateOutput?.releaseAfterAcknowledgedDetach(); true }
                    else engine.dispose()
                }
                if (safe) {
                    worker.await().thread.quitSafely()
                    publicOutput = null
                    result.complete(Unit)
                }
                // Timeout has no public later acknowledgement in pinned Media3. Keep result pending,
                // worker/private/public resources retained. Registry may still close other players.
            } catch (_: Throwable) {
                // An unexpected native teardown exception provides no output safety evidence either.
            }
        }
        return result
    }
    private fun requireCore() = checkNotNull(core)
    private data class Worker(val thread: HandlerThread, val handler: Handler, val dispatcher: CoroutineDispatcher)
}

internal fun requireSelectedVideo(snapshot: YlEngineSnapshot) {
    val videoUnavailable = snapshot.videoTracks.isNotEmpty() && snapshot.videoTracks.none { it.isSelected }
    val audioUnavailable = snapshot.audioTracks.isNotEmpty() && snapshot.audioTracks.none { it.isSelected }
    if (videoUnavailable || audioUnavailable) {
        throw YlBoundaryException(YlFailureKind.DECODER_UNSUPPORTED)
    }
}

internal fun createMedia3Configuration(
    source: AndroidSourceMessage,
    options: AndroidLoadOptionsMessage,
    playerOptions: AndroidPlayerOptionsMessage,
): PlayerConfiguration {
    YlBoundaryValidation.player(playerOptions)
    YlBoundaryValidation.load(source, options)
    val policy = source.networkPolicy
    return PlayerConfiguration(
        bufferMode = when (options.bufferStrategy.kind) {
            AndroidBufferKind.LOW_LATENCY -> "lowLatency"
            AndroidBufferKind.SMOOTH_PLAYBACK -> "stable"
            else -> "automatic"
        }, decoderPolicy = (options.decoderPolicyOverride ?: playerOptions.decoderPolicy).name,
        minBufferMs = null, maxBufferMs = null, maxBufferBytes = null,
        positionEventIntervalMs = playerOptions.positionUpdateIntervalMs,
        network = NetworkConfiguration(policy?.connectTimeoutMs?.toInt() ?: 10_000,
            policy?.readTimeoutMs?.toInt() ?: 15_000, policy?.maxRetries?.toInt() ?: 3,
            policy?.baseRetryDelayMs ?: 500, policy?.maxRetryDelayMs ?: 8_000, policy?.maxRedirects?.toInt() ?: 5),
        managesAudioSession = false)
}

/** Real create binding. Idle creation allocates no Media3 player or private decoder output. */
internal class YlMedia3SessionFactory(
    private val context: Context,
    private val dispatcher: CoroutineDispatcher = Dispatchers.Main,
    private val protectedViews: YlProtectedViewRegistry? = null,
    private val createEngine: (YlSessionIdentity, AndroidSourceMessage, AndroidLoadOptionsMessage, AndroidPlayerOptionsMessage) -> YlPlaybackEngineAdapter =
        { identity, source, load, player -> YlMedia3Engine(context, identity, source, load, player, dispatcher) },
) : YlPlayerSessionFactory {
    private var nextPlayerId = 0L
    override fun prepare(options: AndroidPlayerOptionsMessage): (TextureRegistry.SurfaceTextureEntry) -> YlPlayerSession {
        YlBoundaryValidation.player(options)
        val playerId = ++nextPlayerId
        return { texture ->
            YlSessionCoordinator(playerId, options, YlVideoOutput(texture, ownsTexture = false),
                object : YlPlaybackEngineFactory {
                  override fun createProtected(identity: YlSessionIdentity, source: AndroidSourceMessage, loadOptions: AndroidLoadOptionsMessage,
                      playback: YlProtectedPlayback): YlPlaybackEngineAdapter =
                      YlMedia3Engine(context, identity, source, loadOptions, options, dispatcher, playback)
                  override fun create(identity: YlSessionIdentity, source: AndroidSourceMessage, loadOptions: AndroidLoadOptionsMessage): YlPlaybackEngineAdapter {

                    val primary = createEngine(identity, source, loadOptions, options)
                    return YlManagedAndroidEngine(identity, primary, {
                        YlNativeFallbackEngine(context, identity, source, loadOptions, options, dispatcher)
                    }, dispatcher, allowFallback = !YlRtmpSourcePolicy.isRtmp(source) && source.format != AndroidMediaFormat.DASH &&
                        runCatching { java.net.URI(source.locator).path?.lowercase()?.endsWith(".mpd") }.getOrNull() != true)
                } }, dispatcher, audioFocus = { YlSharedAudioFocus.get(context) }, protectedViews = protectedViews)
        }
    }
}

/** Internal route supplied only after DRM bridge admission (3B3). No public wire
 * configuration is silently promoted to this path. */
internal class YlProtectedPlayback(val identity: YlDrmSessionIdentity,
    val registry: YlProtectedViewRegistry, val cbcs: Boolean, val timeoutMs: Long,
    val exchange: suspend (YlDrmKeyRequest) -> ByteArray)
