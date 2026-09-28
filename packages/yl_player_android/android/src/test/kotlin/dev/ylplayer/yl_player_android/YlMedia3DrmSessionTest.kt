package dev.ylplayer.yl_player_android

import android.os.Looper
import androidx.media3.common.*
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.drm.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.mockito.Mockito.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class YlMedia3DrmSessionTest {
    private class Driver : YlDrmCryptoDriver {
        lateinit var event: (YlDrmSystemEvent) -> Unit
        var closes = 0
        var installs = 0
        var throwOnClose = false
        val initializations = mutableListOf<ByteArray?>()
        override fun open(callback: (YlDrmSystemEvent) -> Unit) { event = callback }
        override fun cryptoConfig() = FrameworkCryptoConfig(C.WIDEVINE_UUID, byteArrayOf(4, 2), false)
        override fun challenge(initData: ByteArray?, mime: String): ByteArray {
            initializations += initData?.copyOf()
            return byteArrayOf(8)
        }
        override fun install(response: ByteArray) { installs++ }
        override fun close() { closes++; if (throwOnClose) throw IllegalStateException("private-close-data") }
    }
    private class Fixture(scope: TestScope) {
        val drivers = mutableListOf<Driver>()
        val requests = mutableListOf<YlDrmKeyRequest>()
        val replies = mutableListOf<CompletableDeferred<ByteArray>>()
        var ignoreCancellation = false
        val manager = YlMedia3DrmSessionManager(
            YlDrmSessionIdentity(1, 2, "candidate", 3), false, 1000,
            exchange = {
                requests += it
                val reply = CompletableDeferred<ByteArray>().also(replies::add)
                if (ignoreCancellation) withContext(NonCancellable) { reply.await() } else reply.await()
            }, ownerFactory = {
                YlMedia3DrmOwner(StandardTestDispatcher(scope.testScheduler), {},
                    { Driver().also(drivers::add) })
            })
        init { manager.setPlayer(mock(Looper::class.java), PlayerId.UNSET); manager.prepare() }
    }
    private fun format(data: ByteArray = byteArrayOf(1), type: String = "cenc", uuid: java.util.UUID = C.WIDEVINE_UUID) =
        Format.Builder().setSampleMimeType("video/avc").setDrmInitData(DrmInitData(type,
            DrmInitData.SchemeData(uuid, "https://ignored.invalid/private", "video/mp4", data))).build()

    @Test fun `Media3 cannot decode until system keys usable and pending revokes usability`() = runTest {
        val f = Fixture(this); val session = f.manager.acquireSession(null, format())!!
        assertEquals(DrmSession.STATE_OPENING, session.state)
        runCurrent()
        assertEquals(DrmSession.STATE_OPENED, session.state)
        val crypto = assertIs<FrameworkCryptoConfig>(session.cryptoConfig)
        assertFalse(crypto.forceAllowInsecureDecoderComponents)
        assertContentEquals(byteArrayOf(4, 2), crypto.sessionId)
        assertTrue(session.requiresSecureDecoder("video/avc"))
        assertFalse(session.playClearSamplesWithoutKeys())
        f.replies[0].complete(byteArrayOf(7)); runCurrent()
        assertEquals(DrmSession.STATE_OPENED, session.state)
        f.drivers[0].event(YlDrmSystemEvent.USABLE); runCurrent()
        assertEquals(DrmSession.STATE_OPENED_WITH_KEYS, session.state)
        f.drivers[0].event(YlDrmSystemEvent.PENDING); runCurrent()
        assertEquals(DrmSession.STATE_OPENED, session.state)
        f.drivers[0].event(YlDrmSystemEvent.KEY_REQUIRED); runCurrent()
        assertEquals(2, f.requests.size)
        f.replies[1].complete(byteArrayOf(9)); runCurrent()
        f.drivers[0].event(YlDrmSystemEvent.USABLE); runCurrent()
        assertEquals(DrmSession.STATE_OPENED_WITH_KEYS, session.state)
        session.release(null); f.manager.release(); runCurrent()
        assertEquals(DrmSession.STATE_RELEASED, session.state)
        assertNull(session.cryptoConfig); assertContentEquals(byteArrayOf(0, 0), crypto.sessionId)
        assertEquals(1, f.drivers[0].closes)
    }
    @Test fun `reference counts retain decoder borrowed keys through manager release and system failure`() = runTest {
        val f = Fixture(this)
        val session = f.manager.acquireSession(null, format())!!
        val same = f.manager.acquireSession(null, format())!!
        assertSame(session, same); session.acquire(null); runCurrent()
        f.drivers[0].event(YlDrmSystemEvent.OUTPUT_RESTRICTED); runCurrent()
        assertEquals(DrmSession.STATE_ERROR, session.state)
        assertEquals(YlFailureKind.DRM_PROTECTION_INSUFFICIENT,
            (session.error!!.cause as YlBoundaryException).kind)
        assertEquals(0, f.drivers[0].closes)
        f.manager.release(); session.release(null); session.release(null); runCurrent()
        assertEquals(0, f.drivers[0].closes)
        session.release(null); runCurrent()
        assertEquals(1, f.drivers[0].closes)
        assertEquals(DrmSession.STATE_RELEASED, session.state)
        assertFailsWith<YlBoundaryException> { session.acquire(null) }
    }
    @Test fun `last release closes CDM and clears challenge before playback looper can quit`() = runTest {
        val f = Fixture(this)
        val session = f.manager.acquireSession(null, format())!!; runCurrent()
        val crypto = assertIs<FrameworkCryptoConfig>(session.cryptoConfig)
        session.release(null)
        assertEquals(1, f.drivers.single().closes)
        assertContentEquals(byteArrayOf(0, 0), crypto.sessionId)
        assertContentEquals(byteArrayOf(0), f.requests.single().bytes)
        f.manager.release(); runCurrent()
    }
    @Test fun `last release cancels license and discards late response and callback`() = runTest {
        val f = Fixture(this); f.ignoreCancellation = true
        val old = f.manager.acquireSession(null, format())!!; runCurrent()
        old.release(null); f.manager.release(); f.manager.prepare()
        val next = f.manager.acquireSession(null, format())!!; runCurrent()
        assertNotSame(old, next)
        f.replies[0].complete(byteArrayOf(7)); f.drivers[0].event(YlDrmSystemEvent.USABLE); runCurrent()
        assertEquals(0, f.drivers[0].installs); assertEquals(DrmSession.STATE_OPENED, next.state)
        f.replies[1].complete(byteArrayOf(7)); runCurrent(); f.drivers[1].event(YlDrmSystemEvent.USABLE); runCurrent()
        assertEquals(DrmSession.STATE_OPENED_WITH_KEYS, next.state)
        next.release(null); f.manager.release(); runCurrent()
        assertEquals(listOf(1, 1), f.drivers.map { it.closes })
        assertNotEquals(f.requests[0].exchangeId, f.requests[1].exchangeId)
    }
    @Test fun `changed Period initialization has independent session and bounded concurrency`() = runTest {
        val f = Fixture(this)
        val sessions = (1..4).map { f.manager.acquireSession(null, format(byteArrayOf(it.toByte())))!! }
        runCurrent(); assertEquals(4, f.drivers.size)
        val excess = f.manager.acquireSession(null, format(byteArrayOf(5)))!!
        assertEquals(DrmSession.STATE_ERROR, excess.state)
        assertEquals(YlFailureKind.RESOURCE_EXHAUSTED, (excess.error!!.cause as YlBoundaryException).kind)
        f.replies[0].completeExceptionally(YlBoundaryException(YlFailureKind.DRM_LICENSE_DENIED)); runCurrent()
        assertEquals(DrmSession.STATE_ERROR, sessions[0].state)
        assertEquals(DrmSession.STATE_OPENED, sessions[1].state)
        sessions.forEach { it.release(null) }; f.manager.release(); runCurrent()
        assertEquals(listOf(1, 1, 1, 1), f.drivers.map { it.closes })
    }
    @Test fun `clear and incompatible encryption do not open driver or send license`() = runTest {
        val f = Fixture(this)
        val clear = Format.Builder().setSampleMimeType("video/avc").build()
        assertNull(f.manager.acquireSession(null, clear)); assertEquals(C.CRYPTO_TYPE_NONE, f.manager.getCryptoType(clear))
        for (bad in listOf(format(type = "cbcs"), format(type = "cens"), format(uuid = C.PLAYREADY_UUID), format(byteArrayOf()))) {
            assertEquals(C.CRYPTO_TYPE_UNSUPPORTED, f.manager.getCryptoType(bad))
            assertEquals(DrmSession.STATE_ERROR, f.manager.acquireSession(null, bad)!!.state)
        }
        runCurrent(); assertTrue(f.drivers.isEmpty()); assertTrue(f.requests.isEmpty()); f.manager.release()
    }
    @Test fun `bounded key wait maps timeout and never claims expired`() = runTest {
        val f = Fixture(this); val session = f.manager.acquireSession(null, format())!!; runCurrent()
        f.replies[0].complete(byteArrayOf(7)); runCurrent(); advanceTimeBy(1000); runCurrent()
        assertEquals(DrmSession.STATE_ERROR, session.state)
        assertEquals(YlFailureKind.DRM_LICENSE_TIMEOUT, (session.error!!.cause as YlBoundaryException).kind)
        session.release(null); f.manager.release(); runCurrent()
    }
    @Test fun `event subscriptions balance duplicate acquires and late subscriber receives current state`() = runTest {
        val f = Fixture(this)
        val events = mock(DrmSessionEventListener.EventDispatcher::class.java)
        val session = f.manager.acquireSession(events, format())!!
        session.acquire(events); runCurrent()
        verify(events, times(1)).drmSessionAcquired(DrmSession.STATE_OPENED)
        f.replies[0].complete(byteArrayOf(7)); runCurrent()
        verify(events, never()).drmKeysLoaded(any())
        f.drivers[0].event(YlDrmSystemEvent.USABLE); runCurrent()
        verify(events, times(1)).drmKeysLoaded(any())
        val later = mock(DrmSessionEventListener.EventDispatcher::class.java)
        session.acquire(later)
        verify(later).drmSessionAcquired(DrmSession.STATE_OPENED_WITH_KEYS)
        verify(later).drmKeysLoaded(any())
        session.release(events); verify(events, never()).drmSessionReleased()
        session.release(events); verify(events).drmSessionReleased()
        clearInvocations(events)
        f.drivers[0].event(YlDrmSystemEvent.EXPIRED); runCurrent()
        verifyNoInteractions(events)
        verify(later).drmSessionManagerError(any())
        assertEquals(YlFailureKind.DRM_LICENSE_EXPIRED, (session.error!!.cause as YlBoundaryException).kind)
        session.release(later); f.manager.release(); runCurrent()
        verify(later).drmSessionReleased()
    }
    @Test fun `dispose before scheduled start allocates nothing and bad close cannot escape coroutine`() = runTest {
        val f = Fixture(this)
        val skipped = f.manager.acquireSession(null, format())!!
        skipped.release(null); runCurrent()
        assertTrue(f.drivers.isEmpty())
        val live = f.manager.acquireSession(null, format())!!; runCurrent()
        val crypto = assertIs<FrameworkCryptoConfig>(live.cryptoConfig)
        f.drivers[0].throwOnClose = true
        live.release(null); f.manager.release(); runCurrent()
        assertNull(live.cryptoConfig); assertContentEquals(byteArrayOf(0, 0), crypto.sessionId)
        assertEquals(1, f.drivers[0].closes)
    }
    @Test fun `format bytes copied and ambiguous or oversized init never creates session`() = runTest {
        val f = Fixture(this)
        val bytes = byteArrayOf(1, 2)
        val session = f.manager.acquireSession(null, format(bytes))!!
        bytes.fill(99); runCurrent()
        assertContentEquals(byteArrayOf(1, 2), f.drivers[0].initializations.single())
        val ambiguous = Format.Builder().setDrmInitData(DrmInitData("cenc",
            DrmInitData.SchemeData(C.WIDEVINE_UUID, "video/mp4", byteArrayOf(1)),
            DrmInitData.SchemeData(C.WIDEVINE_UUID, "video/mp4", byteArrayOf(2)))).build()
        for (bad in listOf(ambiguous, format(ByteArray(1024 * 1024 + 1)))) {
            assertEquals(DrmSession.STATE_ERROR, f.manager.acquireSession(null, bad)!!.state)
        }
        assertEquals(1, f.drivers.size)
        session.release(null); f.manager.release(); runCurrent()
    }

    @Test fun `DASH capability probe accepts missing manifest PSSH but acquisition still requires init bytes`() = runTest {
        val f = Fixture(this)
        val manifestFormat = Format.Builder().setSampleMimeType("video/avc")
            .setDrmInitData(DrmInitData("cenc", DrmInitData.SchemeData(C.WIDEVINE_UUID, "video/mp4", null))).build()
        assertEquals(C.CRYPTO_TYPE_FRAMEWORK, f.manager.getCryptoType(manifestFormat))
        assertEquals(DrmSession.STATE_ERROR, f.manager.acquireSession(null, manifestFormat)!!.state)
        runCurrent(); assertTrue(f.drivers.isEmpty()); assertTrue(f.requests.isEmpty())
        val sampleFormat = format(byteArrayOf(1, 2, 3))
        val session = f.manager.acquireSession(null, sampleFormat)!!; runCurrent()
        assertContentEquals(byteArrayOf(1, 2, 3), f.drivers[0].initializations.single())
        session.release(null); f.manager.release(); runCurrent()
    }

    @Test fun `candidate waits for usable system keys and failure ends readiness wait`() = runTest {
        val f = Fixture(this); val session = f.manager.acquireSession(null, format())!!
        val ready = async { f.manager.awaitUsableKeys() }; runCurrent()
        f.replies[0].complete(byteArrayOf(7)); runCurrent(); assertFalse(ready.isCompleted)
        f.drivers[0].event(YlDrmSystemEvent.USABLE); runCurrent(); ready.await()
        f.drivers[0].event(YlDrmSystemEvent.PENDING); runCurrent()
        val next = async { runCatching { f.manager.awaitUsableKeys() } }; runCurrent()
        assertFalse(next.isCompleted)
        f.drivers[0].event(YlDrmSystemEvent.EXPIRED); runCurrent()
        assertEquals(YlFailureKind.DRM_LICENSE_EXPIRED, (next.await().exceptionOrNull() as YlBoundaryException).kind)
        session.release(null); f.manager.release(); runCurrent()
    }

}
