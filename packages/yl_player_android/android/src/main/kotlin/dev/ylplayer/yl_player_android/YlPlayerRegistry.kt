package dev.ylplayer.yl_player_android

import android.os.Looper
import dev.ylplayer.yl_player_android.pigeon.*
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.view.TextureRegistry
import java.util.UUID
import kotlinx.coroutines.*

/** Engine-local identity and resource owner. Every entry and lifecycle call runs on the main looper. */
internal class YlPlayerRegistry(
    private val messenger: BinaryMessenger,
    private val textures: TextureRegistry,
    private val sessionFactory: YlPlayerSessionFactory,
    private val failures: YlFailureMapper = YlFailureMapper(),
    private val dispatcher: CoroutineDispatcher = Dispatchers.Main,
    private val checkMainThread: () -> Unit = {
        check(Looper.myLooper() == Looper.getMainLooper()) { "Main looper required" }
    },
) : AndroidPlayerFactoryHostApi {
    private val players = LinkedHashMap<String, YlPigeonPlayerHost>()
    // Cleanup is deliberately independent from host command/callback cancellation.
    private val cleanupScope = CoroutineScope(SupervisorJob() + dispatcher)
    private val closing = mutableMapOf<String, Deferred<Throwable?>>()
    private var nextId = 1L
    private var detached = false
    private var backgrounded = false
    private val leases = YlDecoderLeaseCoordinator(dispatcher)

    override fun create(request: AndroidCreateRequest): AndroidCreateReply {
        var texture: TextureRegistry.SurfaceTextureEntry? = null
        var session: YlPlayerSession? = null
        var host: YlPigeonPlayerHost? = null
        try {
            checkMainThread()
            if (detached) throw YlBoundaryException(YlFailureKind.PLAYER_DISPOSED)
            if (request.schemaMajor != 2L) throw YlBoundaryException(YlFailureKind.PLATFORM_INCOMPATIBLE)
            YlBoundaryValidation.player(request.options)
            val createSession = sessionFactory.prepare(request.options)
            val suffix = "p${nextId++}-${UUID.randomUUID()}"
            texture = textures.createSurfaceTexture()
            session = createSession(texture)
            session.bindLeases(leases)
            if (backgrounded) session.onBackground()
            host = YlPigeonPlayerHost(
                suffix, texture, messenger, session, failures, dispatcher, checkMainThread,
                remove = { beginDispose(suffix)?.await()?.let { throw it } },
                terminate = { beginDispose(suffix, reportFailure = true) },
                transportFailed = { error ->
                    failures.record(error)
                    beginDispose(suffix, reportFailure = true)
                },
            )
            val reply = AndroidCreateReply(
                schemaMajor = 2, spiMajor = 2, channelSuffix = suffix, textureId = texture.id(),
                implementationName = "yl_player_android", implementationVersion = "0.2.0",
                capabilities = session.capabilities, initialState = session.initialState,
            )
            host.install()
            players[suffix] = host
            return reply
        } catch (error: Throwable) {
            val cleanupErrors = host?.invalidate().orEmpty()
            // Constructor/setup rollback keeps the same asynchronous output ownership contract.
            texture?.let { startCleanup(it, session, cleanupErrors, reportFailure = true).start() }
            throw failures.toFlutterError(error, AndroidFailureScope.PLAYER)
        }
    }

    /** Invalidate transport now; release output only after the session acknowledges safe cleanup. */
    private fun beginDispose(suffix: String, reportFailure: Boolean = false): Deferred<Throwable?>? {
        closing[suffix]?.let { return it }
        val host = players.remove(suffix) ?: return null
        val result = startCleanup(host.texture, host.session, host.invalidate(), reportFailure)
        closing[suffix] = result
        result.invokeOnCompletion { closing.remove(suffix) }
        result.start()
        return result
    }

    private fun startCleanup(
        texture: TextureRegistry.SurfaceTextureEntry,
        session: YlPlayerSession?,
        priorErrors: List<Throwable>,
        reportFailure: Boolean,
    ): Deferred<Throwable?> = cleanupScope.async(start = CoroutineStart.LAZY) {
        val errors = priorErrors.toMutableList()
        // The close contract requires an unknown/unacknowledged release to remain pending.
        // No timeout or detach cancellation may free a texture still borrowed by the engine.
        try { session?.close()?.await() } catch (error: Throwable) { errors += error }
        try { texture.release() } catch (error: Throwable) { errors += error }
        errors.drop(if (reportFailure) 0 else 1).forEach(failures::record)
        errors.firstOrNull()
    }

    fun detach() {
        if (detached) return
        detached = true
        leases.detach()
        // Dispatchers.Main posts cleanup: every handler is invalidated before any await resumes.
        players.keys.toList().forEach { beginDispose(it, reportFailure = true) }
    }

    fun onForeground() { backgrounded = false; forEachSession { onForeground() } }
    fun onBackground() { backgrounded = true; forEachSession { onBackground() } }
    fun onTrimMemory(level: Int) {
        if (level >= android.content.ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN) backgrounded = true
        forEachSession { onTrimMemory(level) }
    }
    fun onConfigurationChanged() = forEachSession { onConfigurationChanged() }

    private fun forEachSession(action: YlPlayerSession.() -> Unit) {
        players.values.toList().forEach { host ->
            try { checkMainThread(); host.session.action() }
            catch (error: Throwable) {
                failures.record(error)
                beginDispose(host.suffix, reportFailure = true)
            }
        }
    }
}
