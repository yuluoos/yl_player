package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class YlDrmBridgeTest {
    @Test fun `redirect rejection retains its actionable failure code`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val views = YlProtectedViewRegistry(dispatcher, {})
        val bridge = YlDrmBridge(1, views, { AndroidDrmLicenseReply(it.id, null, "drm.license_redirect_rejected") }, {}, {}, dispatcher)
        val request = YlDrmKeyRequest(YlDrmSessionIdentity(1, 2, "s", 3), 1, 1, byteArrayOf(7))
        assertEquals("drm.license_redirect_rejected", assertFailsWith<YlBoundaryException> { bridge.exchange("load-1", request) }.kind.code)
        bridge.close()
    }
    @Test fun `binary reply must match complete exchange identity and standard errors retain meaning`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val views = YlProtectedViewRegistry(dispatcher, {})
        var mismatch = true
        val bridge = YlDrmBridge(1, views, { request ->
            if (mismatch) AndroidDrmLicenseReply(request.id.copy(requestId = 99), byteArrayOf(8), null)
            else AndroidDrmLicenseReply(request.id, null, "drm.license_denied")
        }, {}, {}, dispatcher)
        val request = YlDrmKeyRequest(YlDrmSessionIdentity(1, 2, "s", 3), 4, 5, byteArrayOf(7))
        assertEquals(YlFailureKind.PROTOCOL_MISMATCH, assertFailsWith<YlBoundaryException> { bridge.exchange("load-1", request) }.kind)
        mismatch = false
        assertEquals(YlFailureKind.DRM_LICENSE_DENIED, assertFailsWith<YlBoundaryException> { bridge.exchange("load-1", request) }.kind)
        bridge.close()
    }
    @Test fun `cancelling exact pending load preserves current session and cannot cancel a newer request`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val current = f.coordinator.load(request("current"))
        val candidate = FakeSessionEngine().apply { preparation = CompletableDeferred() }
        f.next = candidate
        val loading = async { runCatching { f.coordinator.load(request("pending")) } }; runCurrent()
        f.coordinator.cancelProtectedLoad("older")
        assertFalse(loading.isCompleted)
        f.coordinator.cancelProtectedLoad("pending"); runCurrent()
        assertEquals(YlFailureKind.LOAD_CANCELLED, (loading.await().exceptionOrNull() as YlBoundaryException).kind)
        assertEquals(current.sessionId, f.events.states.last().sessionId)
        assertTrue(candidate.disposals > 0)
        f.finish()
    }
    @Test fun `coordinator routes DRM through protected factory and license bridge then returns descriptor`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val views = YlProtectedViewRegistry(dispatcher, {})
        val events = SessionEvents()
        var exchanges = 0
        val bridge = YlDrmBridge(1, views, { exchanges++; AndroidDrmLicenseReply(it.id, byteArrayOf(8), null) }, {}, {}, dispatcher)
        val factory = object : YlPlaybackEngineFactory {
            override fun create(identity: YlSessionIdentity, source: AndroidSourceMessage, options: AndroidLoadOptionsMessage): YlPlaybackEngineAdapter = error("DRM escaped to clear")
            override fun createProtected(identity: YlSessionIdentity, source: AndroidSourceMessage, options: AndroidLoadOptionsMessage,
                playback: YlProtectedPlayback): YlPlaybackEngineAdapter {
                assertTrue(playback.cbcs)
                val fake = FakeSessionEngine().also { it.identity = identity }
                return object : YlPlaybackEngineAdapter by fake {
                    override val protectedSurface = playback.identity
                    override val presentationIdentity = YlOutputIdentity(0, true)
                    override suspend fun prepare() {
                        assertContentEquals(byteArrayOf(8), playback.exchange(YlDrmKeyRequest(playback.identity, 1, 1, byteArrayOf(7))))
                        fake.prepare()
                    }
                }
            }
        }
        val coordinator = YlSessionCoordinator(1, sessionOptions, FakeSessionOutput(), factory, dispatcher,
            clockMs = { 100L }, protectedViews = views, drmDevice = { 35 to true })
        coordinator.bindLeases(YlDecoderLeaseCoordinator(dispatcher) { 100L }); coordinator.bindDrm(bridge); coordinator.attach(events)
        val load = request("protected").copy(source = source().copy(format = AndroidMediaFormat.DASH, drm = AndroidDrmConfigMessage(true, 1000)))
        val assessment = coordinator.assess(AndroidAssessRequest(load.source, load.options))
        assertEquals(AndroidAssessmentOutcome.REQUIRES_INSPECTION, assessment.outcome)
        assertTrue(assessment.limitations.contains("drm.secureDecoderUnknown"))
        val reply = coordinator.load(load)
        assertEquals(reply.sessionId, reply.protectedSurface?.sessionId)
        assertEquals(1L, reply.protectedSurface?.playerId)
        assertEquals(1, exchanges)
        coordinator.close().await(); bridge.close()
    }
    @Test fun `view ACK waits for worker attachment and rejects wrong owner`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val views = YlProtectedViewRegistry(dispatcher, {})
        val hold = CompletableDeferred<Unit>()
        val id = YlDrmSessionIdentity(1, 2, "view", 3)
        val record = views.register(id, object : YlProtectedOutputPort {
            override suspend fun attach(surface: android.view.Surface, identity: YlOutputIdentity, isCurrent: () -> Boolean) { hold.await() }
            override suspend fun park() {}
            override fun detachBeforeDestroy() {}
        }) {}; record.commit()
        views.claim(id, 10)!!.available(org.mockito.Mockito.mock(android.view.Surface::class.java))
        val bridge = YlDrmBridge(1, views, { error("unexpected license") }, {}, {}, dispatcher)
        val command = AndroidProtectedViewCommand(id.wire(), 10)
        val ack = async { bridge.attachProtectedView(command) }; runCurrent(); assertFalse(ack.isCompleted)
        hold.complete(Unit); runCurrent()
        assertEquals(1L, ack.await().revision)
        assertTrue(ack.await().attached)
        assertEquals("session.stale", assertFailsWith<FlutterError> { bridge.attachProtectedView(command.copy(surface = command.surface.copy(playerId = 99))) }.code)
        assertFalse(bridge.detachProtectedView(command).attached)
        record.retire(); bridge.close()
    }
    @Test fun `cancelled native request sends cancellation and never installs late reply`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val views = YlProtectedViewRegistry(dispatcher, {})
        val cancelled = mutableListOf<AndroidDrmExchangeId>()
        val reply = CompletableDeferred<AndroidDrmLicenseReply>()
        var sent: AndroidDrmLicenseRequest? = null
        val bridge = YlDrmBridge(1, views, { sent = it; reply.await() }, { cancelled += it }, {}, dispatcher)
        val request = YlDrmKeyRequest(YlDrmSessionIdentity(1, 2, "s", 3), 1, 1, byteArrayOf(7))
        val task = async { bridge.exchange("load-1", request) }; runCurrent()
        task.cancel(); runCurrent()
        assertEquals(sent!!.id, cancelled.single())
        reply.complete(AndroidDrmLicenseReply(sent!!.id, byteArrayOf(8), null)); runCurrent()
        assertTrue(task.isCancelled)
        bridge.close()
    }
}
