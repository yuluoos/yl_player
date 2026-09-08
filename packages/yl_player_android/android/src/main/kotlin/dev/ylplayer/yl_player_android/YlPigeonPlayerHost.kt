package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.view.TextureRegistry
import kotlinx.coroutines.*

/**
 * Main-looper session port. Task 4 supplies the real coordinator/Media3 implementation.
 * close initiates release without blocking main and returns a completion owned by the session.
 * Completion, including exceptional completion, promises safe relinquishment of the borrowed
 * output. Throwing from close also promises safe relinquishment. An unacknowledged engine
 * release must keep its completion pending; never cancel or fail it merely because detach
 * or a release deadline occurred.
 * The registry retains the texture until that completion. Session code may use a documented
 * worker looper and return immutable results asynchronously.
 * Session creation must clean up any internally allocated resources if its constructor throws.
 * The texture is borrowed: only the registry releases it.
 */
internal interface YlPlayerSession {
    val initialState: AndroidStateMessage
    val capabilities: AndroidCapabilitiesMessage
    fun attach(events: YlPlayerEventSink)
    fun assess(request: AndroidAssessRequest): AndroidAssessmentReply
    suspend fun load(request: AndroidLoadRequest): AndroidLoadReply
    suspend fun play(command: AndroidSessionCommand)
    fun pause(command: AndroidSessionCommand)
    fun seekTo(command: AndroidSeekCommand)
    fun seekToLiveEdge(command: AndroidSessionCommand)
    fun setPlaybackSpeed(command: AndroidSpeedCommand)
    fun selectAudioTrack(command: AndroidTrackCommand)
    fun setVideoConstraints(command: AndroidVideoConstraintsCommand)
    fun setVolume(volume: Double)
    suspend fun stop()
    fun close(): Deferred<Unit>
    fun onForeground()
    fun onBackground()
    fun onTrimMemory(level: Int)
    fun onConfigurationChanged()
}

/** Availability/policy preparation happens before the registry allocates a texture. */
internal fun interface YlPlayerSessionFactory {
    fun prepare(options: AndroidPlayerOptionsMessage): (TextureRegistry.SurfaceTextureEntry) -> YlPlayerSession
}

/** Explicit interim binding; Task 4 replaces this with the real Media3/session factory. */
internal object YlPendingMedia3SessionFactory : YlPlayerSessionFactory {
    override fun prepare(options: AndroidPlayerOptionsMessage): (TextureRegistry.SurfaceTextureEntry) -> YlPlayerSession =
        throw YlBoundaryException(YlFailureKind.PLATFORM_UNAVAILABLE)
}

internal class YlPigeonPlayerHost(
    val suffix: String,
    val texture: TextureRegistry.SurfaceTextureEntry,
    private val messenger: BinaryMessenger,
    internal val session: YlPlayerSession,
    private val failures: YlFailureMapper,
    dispatcher: CoroutineDispatcher,
    private val checkMainThread: () -> Unit,
    private val remove: suspend () -> Unit,
    private val terminate: () -> Unit,
    private val transportFailed: (Throwable) -> Unit,
) : AndroidPlayerHostApi {
    private val commandScope = CoroutineScope(SupervisorJob() + dispatcher)
    private val callbacks = YlCallbackDispatcher(
        YlPigeonCallbacks(AndroidPlayerFlutterApi(messenger, suffix)), dispatcher, transportFailed,
    )
    private var attached = false
    private var closed = false

    fun install() = AndroidPlayerHostApi.setUp(messenger, this, suffix)

    /** Registry invokes every cleanup step even if a preceding step fails. */
    fun invalidate(): List<Throwable> {
        if (closed) return emptyList()
        closed = true
        val errors = mutableListOf<Throwable>()
        fun attempt(action: () -> Unit) { try { action() } catch (error: Throwable) { errors += error } }
        attempt { callbacks.close() }
        attempt { commandScope.cancel() }
        // Continue generated handler removal if a messenger operation itself throws.
        val cleanupMessenger = object : BinaryMessenger by messenger {
            override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
                try { messenger.setMessageHandler(channel, handler) }
                catch (error: Throwable) {
                    errors += error
                    // Retry once for a transient messenger failure, without skipping later methods.
                    attempt { messenger.setMessageHandler(channel, handler) }
                }
            }
        }
        attempt { AndroidPlayerHostApi.setUp(cleanupMessenger, null, suffix) }
        return errors
    }

    override fun attach() = safe(requireAttached = false) {
        if (!attached) {
            try {
                session.attach(callbacks)
                attached = true
                callbacks.attach()
            } catch (error: Throwable) {
                try { terminate() } catch (cleanupError: Throwable) { failures.record(cleanupError) }
                throw error
            }
        }
    }

    override fun assess(request: AndroidAssessRequest) = safe { session.assess(request) }
    override suspend fun load(request: AndroidLoadRequest): AndroidLoadReply = command {
        // Keep immutable request identity all the way into the session; never use a mutable latest ID.
        session.load(request).also {
            if (it.loadRequestId != request.loadRequestId) throw YlBoundaryException(YlFailureKind.PROTOCOL_MISMATCH)
        }
    }
    override suspend fun play(command: AndroidSessionCommand) = command { session.play(command) }
    override fun pause(command: AndroidSessionCommand) = safe { session.pause(command) }
    override fun seekTo(command: AndroidSeekCommand) = safe { session.seekTo(command) }
    override fun seekToLiveEdge(command: AndroidSessionCommand) = safe { session.seekToLiveEdge(command) }
    override fun setPlaybackSpeed(command: AndroidSpeedCommand) = safe { session.setPlaybackSpeed(command) }
    override fun selectAudioTrack(command: AndroidTrackCommand) = safe { session.selectAudioTrack(command) }
    override fun setVideoConstraints(command: AndroidVideoConstraintsCommand) = safe { session.setVideoConstraints(command) }
    override fun setVolume(volume: Double) = safe { session.setVolume(volume) }
    override suspend fun stop() = command { session.stop() }
    override suspend fun dispose() {
        try { checkMainThread(); remove() } catch (error: Throwable) { throw failures.toFlutterError(error) }
    }

    private fun checkUsable(requireAttached: Boolean = true) {
        checkMainThread()
        if (closed) throw YlBoundaryException(YlFailureKind.PLAYER_DISPOSED)
        if (requireAttached && !attached) throw YlBoundaryException(YlFailureKind.PROTOCOL_MISMATCH)
    }

    private inline fun <T> safe(requireAttached: Boolean = true, action: () -> T): T = try {
        checkUsable(requireAttached)
        action()
    } catch (error: Throwable) { throw failures.toFlutterError(error) }

    private suspend fun <T> command(action: suspend () -> T): T = try {
        checkUsable()
        // Generated host coroutines outlive handler removal; this child scope owns their work.
        commandScope.async { action() }.await()
    } catch (error: Throwable) { throw failures.toFlutterError(error) }
}
