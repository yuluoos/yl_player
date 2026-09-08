package dev.ylplayer.yl_player_android

import android.app.Application
import android.os.Looper
import dev.ylplayer.yl_player_android.pigeon.*
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.view.TextureRegistry
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.mockito.Mockito.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class YlPlayerRegistryTest {
    @Test fun `real factories across registries retain one application focus owner until final registry detaches`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val app = mock(Application::class.java)
        val manager = mock(android.media.AudioManager::class.java)
        `when`(app.applicationContext).thenReturn(app)
        `when`(app.getSystemService(android.content.Context.AUDIO_SERVICE)).thenReturn(manager)
        `when`(manager.requestAudioFocus(any(), eq(android.media.AudioManager.STREAM_MUSIC), eq(android.media.AudioManager.AUDIOFOCUS_GAIN)))
            .thenReturn(android.media.AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
        Dispatchers.setMain(dispatcher)
        try { mockStatic(android.os.SystemClock::class.java).use {
        mockStatic(Looper::class.java).use {
            mockConstruction(android.os.Handler::class.java).use {
                mockConstruction(android.content.IntentFilter::class.java).use {
                    val engines = mutableListOf<FakeSessionEngine>()
                    fun factory() = YlMedia3SessionFactory(app, dispatcher) { identity, _, _, _ ->
                        FakeSessionEngine().also { it.identity = identity; engines += it }
                    }
                    val first = RegistryFixture(dispatcher, factory())
                    val second = RegistryFixture(dispatcher, factory())
                    val options = createRequest().copy(options = sessionOptions.copy(audioPolicy = AndroidAudioPolicy.PLUGIN_MANAGED_MEDIA_PLAYBACK))
                    val a = first.registry.create(options); val b = second.registry.create(options)
                    first.call(a.channelSuffix, "attach"); second.call(b.channelSuffix, "attach")
                    verify(manager, never()).requestAudioFocus(any(), anyInt(), anyInt())
                    val loadA = first.load(a.channelSuffix, request("a").withAutoplay(true))
                    val loadB = second.load(b.channelSuffix, request("b").withAutoplay(true))
                    loadA.first(); loadB.first(); runCurrent()
                    assertIs<AndroidLoadReply>(loadA.second().single())
                    assertIs<AndroidLoadReply>(loadB.second().single())
                    assertTrue(engines.all { it.playing })
                    verify(manager).requestAudioFocus(any(), eq(android.media.AudioManager.STREAM_MUSIC), eq(android.media.AudioManager.AUDIOFOCUS_GAIN))
                    verify(app).registerReceiver(any(), any(android.content.IntentFilter::class.java), isNull(), any(android.os.Handler::class.java))
                    first.registry.detach(); runCurrent()
                    verify(manager, never()).abandonAudioFocus(any())
                    assertTrue(engines.last().playing)
                    second.registry.detach(); runCurrent()
                    verify(manager).abandonAudioFocus(any())
                    verify(app).unregisterReceiver(any())
                }
            }
        }
            } } finally { Dispatchers.resetMain() }
    }

    @Test fun `new player inherits registry background state`() = runTest {
        val fixture = RegistryFixture(StandardTestDispatcher(testScheduler))
        fixture.registry.onBackground()
        fixture.registry.create(createRequest())
        assertEquals(listOf("background"), fixture.sessions.single().lifecycleCalls)
        fixture.registry.detach()
        runCurrent()
    }

    @Test
    fun `plugin registers only the generated factory and removes its lifecycle registrations`() = runTest {
        val fixture = RegistryFixture(StandardTestDispatcher(testScheduler))
        val app = mock(Application::class.java)
        val binding = mock(FlutterPlugin.FlutterPluginBinding::class.java)
        `when`(binding.applicationContext).thenReturn(app)
        `when`(binding.binaryMessenger).thenReturn(fixture.messenger)
        `when`(binding.textureRegistry).thenReturn(fixture.textures)
        val plugin = YlPlayerAndroidPlugin()
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        mockStatic(Looper::class.java).use {
            plugin.onAttachedToEngine(binding)
            assertEquals(setOf("dev.flutter.pigeon.yl_player_android.AndroidPlayerFactoryHostApi.create"), fixture.handlers.keys)
            val managed = createRequest().let { it.copy(options = it.options.copy(audioPolicy = AndroidAudioPolicy.PLUGIN_MANAGED_MEDIA_PLAYBACK)) }
            val managedResponse = fixture.invoke(fixture.handlers.values.single(), listOf(managed))()
            assertIs<AndroidCreateReply>(managedResponse.single())
            val response = fixture.invoke(fixture.handlers.getValue("dev.flutter.pigeon.yl_player_android.AndroidPlayerFactoryHostApi.create"), listOf(createRequest()))()
            assertIs<AndroidCreateReply>(response.single())
            verify(fixture.textures, times(2)).createSurfaceTexture()
            plugin.onDetachedFromEngine(binding)
            plugin.onDetachedFromEngine(binding)
            assertTrue(fixture.handlers.isEmpty())
            verify(app).registerComponentCallbacks(plugin)
            verify(app).registerActivityLifecycleCallbacks(plugin)
            verify(app).unregisterComponentCallbacks(plugin)
            verify(app).unregisterActivityLifecycleCallbacks(plugin)
            runCurrent()
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `real factory accepts explicit managed audio without idle ownership or allocation`() {
        val context = mock(Application::class.java)
        val factory = YlMedia3SessionFactory(context)
        val options = createRequest().options.copy(audioPolicy = AndroidAudioPolicy.PLUGIN_MANAGED_MEDIA_PLAYBACK)
        factory.prepare(options)
        verifyNoInteractions(context)
    }

    @Test
    fun `texture allocation failure is typed and creates no session`() = runTest {
        val fixture = RegistryFixture(StandardTestDispatcher(testScheduler))
        `when`(fixture.textures.createSurfaceTexture()).thenThrow(IllegalStateException("https://private"))
        val failure = assertFailsWith<FlutterError> { fixture.registry.create(createRequest()) }
        assertEquals("internal.failure", failure.code)
        assertIs<AndroidFailureMessage>(failure.details)
        assertTrue(fixture.sessions.isEmpty())
        verify(fixture.texture, never()).release()
    }

    @Test
    fun `create registers one unique monotonic suffix per texture and attach is once only`() = runTest {
        val fixture = RegistryFixture(StandardTestDispatcher(testScheduler))
        val first = fixture.registry.create(createRequest())
        val second = fixture.registry.create(createRequest())
        assertEquals(2L, first.schemaMajor)
        assertEquals(2L, first.spiMajor)
        assertEquals(41L, first.textureId)
        assertTrue(first.channelSuffix.matches(Regex("p1-[a-zA-Z0-9-]+")))
        assertTrue(second.channelSuffix.startsWith("p2-"))
        assertNotEquals(first.channelSuffix, second.channelSuffix)
        assertEquals(26, fixture.handlers.size)
        assertTrue(fixture.handlers.keys.all { it.endsWith(first.channelSuffix) || it.endsWith(second.channelSuffix) })
        assertEquals(0, fixture.sessions[0].attachments)
        fixture.call(first.channelSuffix, "attach")
        fixture.call(first.channelSuffix, "attach")
        assertEquals(1, fixture.sessions[0].attachments)
        fixture.registry.detach()
        runCurrent()
        assertTrue(fixture.handlers.isEmpty())
        verify(fixture.textures, times(2)).createSurfaceTexture()
        fixture.allocatedTextures.forEach { verify(it, times(1)).release() }
    }

    @Test
    fun `dispose unregisters and releases once even when called twice`() = runTest {
        val fixture = RegistryFixture(StandardTestDispatcher(testScheduler))
        val player = fixture.registry.create(createRequest())
        val handler = fixture.handlers.getValue(fixture.channel(player.channelSuffix, "dispose"))
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            fixture.invoke(handler)
            runCurrent()
            fixture.invoke(handler)
            runCurrent()
            assertTrue(fixture.handlers.isEmpty())
            assertEquals(1, fixture.sessions.single().closes)
            verify(fixture.texture, times(1)).release()
        } finally { Dispatchers.resetMain(); fixture.registry.detach() }
    }

    @Test
    fun `engine detach releases all hosts when a session teardown throws`() = runTest {
        val fixture = RegistryFixture(StandardTestDispatcher(testScheduler))
        repeat(2) { fixture.registry.create(createRequest()) }
        fixture.sessions.first().closeError = IOException("https://private Cookie: secret")
        fixture.registry.detach()
        runCurrent()
        fixture.registry.detach()
        runCurrent()
        assertTrue(fixture.handlers.isEmpty())
        assertEquals(listOf(1, 1), fixture.sessions.map { it.closes })
        fixture.allocatedTextures.forEach { verify(it, times(1)).release() }
        assertEquals("player.disposed", assertFailsWith<FlutterError> { fixture.registry.create(createRequest()) }.code)
    }

    @Test
    fun `factory or handler setup failure rolls back allocated resources`() = runTest {
        val fixture = RegistryFixture(StandardTestDispatcher(testScheduler))
        fixture.createError = IOException("https://secret")
        assertEquals("network.failed", assertFailsWith<FlutterError> { fixture.registry.create(createRequest()) }.code)
        runCurrent()
        verify(fixture.texture).release()
        fixture.createError = null
        fixture.failRegistrationAt = 4
        val failure = assertFailsWith<FlutterError> { fixture.registry.create(createRequest()) }
        assertIs<AndroidFailureMessage>(failure.details)
        runCurrent()
        assertTrue(fixture.handlers.isEmpty())
        assertEquals(1, fixture.sessions.single().closes)
        fixture.allocatedTextures.forEach { verify(it, times(1)).release() }
    }

    @Test
    fun `real production binding creates idle session and incompatible schema allocates nothing`() = runTest {
        val fixture = RegistryFixture(StandardTestDispatcher(testScheduler), YlMedia3SessionFactory(mock(Application::class.java), StandardTestDispatcher(testScheduler)))
        val reply = fixture.registry.create(createRequest())
        assertEquals(AndroidPlaybackStatus.IDLE, reply.initialState.status)
        assertEquals(0L, reply.initialState.revision)
        assertEquals("platform.incompatible", assertFailsWith<FlutterError> { fixture.registry.create(createRequest().copy(schemaMajor = 1)) }.code)
        verify(fixture.textures).createSurfaceTexture()
        fixture.registry.detach()
        runCurrent()
        assertTrue(fixture.handlers.isEmpty())
    }

    @Test
    fun `host catches session exception before generated fallback and attach failure closes instance`() = runTest {
        val fixture = RegistryFixture(StandardTestDispatcher(testScheduler))
        val player = fixture.registry.create(createRequest())
        fixture.sessions.single().attachError = IllegalStateException("https://private Authorization: secret")
        val reply = fixture.call(player.channelSuffix, "attach")
        assertEquals("internal.failure", reply[0])
        val details = assertIs<AndroidFailureMessage>(reply[2])
        assertFalse(details.message.contains("secret"))
        runCurrent()
        assertTrue(fixture.handlers.isEmpty())
        verify(fixture.texture).release()
    }

    @Test
    fun `dispose waits asynchronously for safe session release before releasing texture`() = runTest {
        val fixture = RegistryFixture(StandardTestDispatcher(testScheduler))
        val player = fixture.registry.create(createRequest())
        val barrier = CompletableDeferred<Unit>()
        fixture.sessions.single().closeCompletion = barrier
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            var completed = false
            val handler = fixture.handlers.getValue(fixture.channel(player.channelSuffix, "dispose"))
            handler.onMessage(AndroidPlayerHostApi.codec.encodeMessage(emptyList<Any?>())!!.apply { flip() }) { completed = true }
            runCurrent()
            assertFalse(completed)
            assertTrue(fixture.handlers.isEmpty())
            verify(fixture.texture, never()).release()
            var mainResponsive = false
            launch(Dispatchers.Main) { mainResponsive = true }
            runCurrent()
            assertTrue(mainResponsive)
            barrier.complete(Unit)
            runCurrent()
            assertTrue(completed)
            verify(fixture.texture).release()
        } finally { Dispatchers.resetMain(); fixture.registry.detach() }
    }

    @Test
    fun `detach invalidates every host immediately and owns independent cleanup until acknowledged`() = runTest {
        val fixture = RegistryFixture(StandardTestDispatcher(testScheduler))
        repeat(2) { fixture.registry.create(createRequest()) }
        val barrier = CompletableDeferred<Unit>()
        fixture.sessions.first().closeCompletion = barrier
        fixture.sessions.last().closeError = IOException("private")
        fixture.registry.detach()
        assertTrue(fixture.handlers.isEmpty())
        runCurrent()
        assertFalse(barrier.isCompleted)
        verify(fixture.texture, never()).release()
        verify(fixture.allocatedTextures.last(), times(1)).release()
        assertEquals(listOf(1, 1), fixture.sessions.map { it.closes })
        barrier.complete(Unit)
        runCurrent()
        fixture.allocatedTextures.forEach { verify(it, times(1)).release() }
    }

    @Test
    fun `all generated command handlers sanitize thrown session errors`() = runTest {
        val fixture = RegistryFixture(StandardTestDispatcher(testScheduler))
        val player = fixture.registry.create(createRequest())
        fixture.call(player.channelSuffix, "attach")
        val session = fixture.sessions.single()
        session.commandError = IllegalStateException("https://private Authorization: secret\n at Hidden.frame")
        val source = testLoadRequest("request-1")
        val calls = listOf(
            "assess" to AndroidAssessRequest(source.source, source.options),
            "load" to source,
            "play" to AndroidSessionCommand("s"),
            "pause" to AndroidSessionCommand("s"),
            "seekTo" to AndroidSeekCommand("s", 100),
            "seekToLiveEdge" to AndroidSessionCommand("s"),
            "setPlaybackSpeed" to AndroidSpeedCommand("s", 1.5),
            "selectAudioTrack" to AndroidTrackCommand("s", "audio"),
            "setVideoConstraints" to AndroidVideoConstraintsCommand("s", AndroidVideoConstraintsMessage()),
            "setVolume" to 0.5,
            "stop" to null,
        )
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            for ((method, argument) in calls) {
                val result = fixture.invoke(fixture.handlers.getValue(fixture.channel(player.channelSuffix, method)), if (argument == null) emptyList() else listOf(argument))
                runCurrent()
                val reply = result()
                assertEquals("internal.failure", reply[0], method)
                assertIs<AndroidFailureMessage>(reply[2], method)
                assertFalse(reply.toString().contains("private"), method)
                assertFalse(reply.toString().contains("Hidden.frame"), method)
            }
            session.closeError = IOException("Cookie: secret")
            val result = fixture.invoke(fixture.handlers.getValue(fixture.channel(player.channelSuffix, "dispose")))
            runCurrent()
            assertEquals("network.failed", result()[0])
            assertIs<AndroidFailureMessage>(result()[2])
            verify(fixture.texture).release()
        } finally { Dispatchers.resetMain(); fixture.registry.detach() }
    }

    @Test
    fun `timeout and engine detach settle pending load and ignore late acknowledgement`() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            for (timeout in listOf(false, true)) {
                val fixture = RegistryFixture(StandardTestDispatcher(testScheduler))
                val player = fixture.registry.create(createRequest())
                fixture.call(player.channelSuffix, "attach")
                val load = fixture.load(player.channelSuffix, testLoadRequest("request-1"))
                load.first()
                runCurrent()
                val sink = fixture.sessions.single().events!!
                sink.onState(idleState())
                sink.onFirstFrame(AndroidFirstFrameMessage("s", 1, 2, 0))
                runCurrent()
                if (timeout) { advanceTimeBy(5_000); runCurrent() } else fixture.registry.detach()
                runCurrent()
                assertEquals("load.cancelled", load.second()[0])
                assertTrue(fixture.handlers.isEmpty())
                verify(fixture.texture).release()
                val acknowledgement = AndroidPlayerFlutterApi.codec.encodeMessage(listOf(null))!!.apply { flip() }
                fixture.outgoing.single().reply(acknowledgement)
                sink.onState(idleState())
                advanceUntilIdle()
                assertEquals(1, fixture.outgoing.size)
                fixture.registry.detach()
            }
        } finally { Dispatchers.resetMain() }
    }

    @Test
    fun `load reply preserves request identity and mismatches fail safely`() = runTest {
        val fixture = RegistryFixture(StandardTestDispatcher(testScheduler))
        val player = fixture.registry.create(createRequest())
        fixture.call(player.channelSuffix, "attach")
        val session = fixture.sessions.single()
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            session.loadReply = AndroidLoadReply("request-7", "session-1")
            val first = fixture.load(player.channelSuffix, testLoadRequest("request-7"))
            first.first(); runCurrent()
            assertEquals(AndroidLoadReply("request-7", "session-1"), first.second().single())
            val second = fixture.load(player.channelSuffix, testLoadRequest("request-8"))
            second.first(); runCurrent()
            assertEquals("protocol.mismatch", second.second()[0])
            assertEquals("request-8", session.loadRequest?.loadRequestId)
        } finally { Dispatchers.resetMain(); fixture.registry.detach() }
    }

    @Test
    fun `lifecycle forwarding isolates a failed host and keeps other sessions alive`() = runTest {
        val fixture = RegistryFixture(StandardTestDispatcher(testScheduler))
        repeat(2) { fixture.registry.create(createRequest()) }
        fixture.sessions.first().lifecycleError = IOException("private")
        fixture.registry.onForeground()
        fixture.registry.onBackground()
        fixture.registry.onTrimMemory(80)
        fixture.registry.onConfigurationChanged()
        runCurrent()
        assertEquals(1, fixture.sessions.first().closes)
        assertEquals(listOf("foreground", "background", "trim:80", "configuration"), fixture.sessions.last().lifecycleCalls)
        assertEquals(13, fixture.handlers.size)
        fixture.registry.detach()
    }

    @Test
    fun `failed texture id read releases every allocated resource`() = runTest {
        val fixture = RegistryFixture(StandardTestDispatcher(testScheduler))
        `when`(fixture.texture.id()).thenThrow(IllegalStateException("private"))
        assertIs<AndroidFailureMessage>(assertFailsWith<FlutterError> { fixture.registry.create(createRequest()) }.details)
        runCurrent()
        assertEquals(1, fixture.sessions.single().closes)
        assertTrue(fixture.handlers.isEmpty())
        verify(fixture.texture).release()
    }

    @Test
    fun `a transient handler removal failure is retried while all other handlers are removed`() = runTest {
        val fixture = RegistryFixture(StandardTestDispatcher(testScheduler))
        fixture.registry.create(createRequest())
        fixture.failRemovalOnce = true
        fixture.registry.detach()
        runCurrent()
        assertTrue(fixture.handlers.isEmpty())
        verify(fixture.texture).release()
    }

    @Test
    fun `delivery failure cancels pending load and releases the instance`() = runTest {
        val fixture = RegistryFixture(StandardTestDispatcher(testScheduler))
        val player = fixture.registry.create(createRequest())
        fixture.call(player.channelSuffix, "attach")
        val session = fixture.sessions.single()
        val load = fixture.load(player.channelSuffix, testLoadRequest("request-7"))
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            load.first()
            runCurrent()
            assertEquals("request-7", session.loadRequest?.loadRequestId)
            session.events!!.onState(idleState())
            runCurrent()
            assertEquals(1, fixture.outgoing.size)
            fixture.outgoing.single().reply(null)
            runCurrent()
            assertEquals("load.cancelled", load.second().first())
            assertTrue(session.loadCancelled)
            assertTrue(fixture.handlers.isEmpty())
            assertEquals(1, session.closes)
            verify(fixture.texture).release()
        } finally { Dispatchers.resetMain(); fixture.registry.detach() }
    }
}

internal fun createRequest() = AndroidCreateRequest(2, AndroidPlayerOptionsMessage(AndroidDecoderPolicy.SYSTEM_DEFAULT, AndroidAudioPolicy.APP_MANAGED, 250))

internal class RegistryFixture(dispatcher: CoroutineDispatcher, factory: YlPlayerSessionFactory? = null) {
    val messenger = mock(BinaryMessenger::class.java)
    val textures = mock(TextureRegistry::class.java)
    val texture = mock(TextureRegistry.SurfaceTextureEntry::class.java)
    val allocatedTextures = mutableListOf<TextureRegistry.SurfaceTextureEntry>()
    val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler>()
    val outgoing = mutableListOf<BinaryMessenger.BinaryReply>()
    val outgoingChannels = mutableListOf<String>()
    val sessions = mutableListOf<FakeSession>()
    var createError: Throwable? = null
    var failRegistrationAt: Int? = null
    var failRemovalOnce = false
    private var registrations = 0
    val registry: YlPlayerRegistry
    init {
        doAnswer {
            val entry = if (allocatedTextures.isEmpty()) texture else mock(TextureRegistry.SurfaceTextureEntry::class.java).also {
                `when`(it.id()).thenReturn(41L + allocatedTextures.size)
            }
            allocatedTextures += entry
            entry
        }.`when`(textures).createSurfaceTexture()
        `when`(texture.id()).thenReturn(41)
        doAnswer { invocation ->
            val name = invocation.getArgument<String>(0)
            val handler = invocation.getArgument<BinaryMessenger.BinaryMessageHandler?>(1)
            if (handler == null) {
                if (failRemovalOnce) { failRemovalOnce = false; throw IOException("private") }
                handlers.remove(name)
            } else {
                registrations++
                if (registrations == failRegistrationAt) throw IOException("secret registration")
                handlers[name] = handler
            }
            null
        }.`when`(messenger).setMessageHandler(anyString(), nullable(BinaryMessenger.BinaryMessageHandler::class.java))
        doAnswer { invocation -> outgoingChannels += invocation.getArgument<String>(0); outgoing += invocation.getArgument<BinaryMessenger.BinaryReply>(2); null }.`when`(messenger).send(anyString(), any(), any())
        registry = YlPlayerRegistry(messenger, textures, factory ?: YlPlayerSessionFactory {
            { createError?.let { throw it }; FakeSession().also(sessions::add) }
        }, YlFailureMapper(YlSafeDiagnostics {}), dispatcher, checkMainThread = {})
    }
    fun channel(suffix: String, method: String) = "dev.flutter.pigeon.yl_player_android.AndroidPlayerHostApi.$method.$suffix"
    fun call(suffix: String, method: String): List<*> = invoke(handlers.getValue(channel(suffix, method)))()
    fun invoke(handler: BinaryMessenger.BinaryMessageHandler, args: List<Any?> = emptyList()): () -> List<*> {
        var reply: List<*>? = null
        val message = AndroidPlayerHostApi.codec.encodeMessage(args)?.apply { flip() }
        handler.onMessage(message) { buffer -> reply = AndroidPlayerHostApi.codec.decodeMessage(buffer?.apply { flip() }) as List<*> }
        return { assertNotNull(reply) }
    }
    fun load(suffix: String, request: AndroidLoadRequest): Pair<() -> Unit, () -> List<*>> {
        var result: (() -> List<*>)? = null
        return Pair({ result = invoke(handlers.getValue(channel(suffix, "load")), listOf(request)) }, { result!!() })
    }
}

internal class FakeSession : YlPlayerSession {
    override val initialState = idleState()
    override val capabilities = AndroidCapabilitiesMessage("test", emptyList(), AndroidDecoderEvidence.NONE, hardwareVideoCodecs = emptyList(), supportedOperations = emptyList())
    var attachments = 0
    var closes = 0
    var attachError: Throwable? = null
    var closeError: Throwable? = null
    var closeCompletion: Deferred<Unit>? = null
    var events: YlPlayerEventSink? = null
    var loadRequest: AndroidLoadRequest? = null
    var loadCancelled = false
    var commandError: Throwable? = null
    var loadReply: AndroidLoadReply? = null
    var lifecycleError: Throwable? = null
    val lifecycleCalls = mutableListOf<String>()
    private fun command() { commandError?.let { throw it } }
    private fun lifecycle(event: String) { lifecycleError?.let { throw it }; lifecycleCalls += event }
    override fun attach(events: YlPlayerEventSink) { attachments++; this.events = events; attachError?.let { throw it } }
    override fun close(): Deferred<Unit> {
        closes++; events = null
        return closeCompletion ?: CompletableDeferred<Unit>().also { completion ->
            closeError?.let(completion::completeExceptionally) ?: completion.complete(Unit)
        }
    }
    override fun assess(request: AndroidAssessRequest): AndroidAssessmentReply { command(); return AndroidAssessmentReply(AndroidAssessmentOutcome.COMPATIBLE, satisfiedRequirements = emptyList(), limitations = emptyList()) }
    override suspend fun load(request: AndroidLoadRequest): AndroidLoadReply { loadRequest = request; command(); loadReply?.let { return it }; try { awaitCancellation() } finally { loadCancelled = true } }
    override suspend fun play(command: AndroidSessionCommand) = command()
    override fun pause(command: AndroidSessionCommand) = command()
    override fun seekTo(command: AndroidSeekCommand) = command()
    override suspend fun seekToLiveEdge(command: AndroidSessionCommand) = command()
    override fun setPlaybackSpeed(command: AndroidSpeedCommand) = command()
    override suspend fun selectAudioTrack(command: AndroidTrackCommand) = command()
    override fun setVideoConstraints(command: AndroidVideoConstraintsCommand) = command()
    override fun setVolume(volume: Double) = command()
    override suspend fun stop() = command()
    override fun onForeground() = lifecycle("foreground")
    override fun onBackground() = lifecycle("background")
    override fun onTrimMemory(level: Int) = lifecycle("trim:$level")
    override fun onConfigurationChanged() = lifecycle("configuration")
}

internal fun testLoadRequest(id: String) = AndroidLoadRequest(
    id, AndroidSourceMessage(AndroidSourceKind.FILE, "/fixture.mp4", AndroidStreamIntent.ON_DEMAND, AndroidMediaFormat.MP4),
    AndroidLoadOptionsMessage(false, bufferStrategy = AndroidBufferStrategyMessage(AndroidBufferKind.AUTOMATIC), videoConstraints = AndroidVideoConstraintsMessage()),
)
