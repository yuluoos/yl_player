package dev.ylplayer.yl_player_android

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class YlDrmKeySessionTest {
    private class Driver : YlDrmSystemDriver {
        lateinit var event: (YlDrmSystemEvent) -> Unit
        var opens = 0; var closes = 0; var installs = 0; var requests = 0
        var failOpen = false
        var failChallenge = false
        val retained = mutableListOf<ByteArray>()
        override fun open(callback: (YlDrmSystemEvent) -> Unit) {
            event = callback; opens++
            if (failOpen) throw YlBoundaryException(YlFailureKind.DRM_PROTECTION_INSUFFICIENT)
        }
        override fun challenge(initData: ByteArray?, mime: String): ByteArray {
            requests++
            if (failChallenge) throw YlBoundaryException(YlFailureKind.DRM_LICENSE_FAILED)
            return byteArrayOf(1, 2, 3)
        }
        override fun install(response: ByteArray) { installs++; retained += response }
        override fun close() { closes++ }
        fun usable() = event(YlDrmSystemEvent.USABLE)
    }
    private class Fixture(scope: TestScope) {
        val drivers = mutableListOf<Driver>()
        val requests = mutableListOf<YlDrmKeyRequest>()
        val replies = mutableListOf<CompletableDeferred<ByteArray>>()
        val failures = mutableListOf<YlFailureKind>()
        var ignoreCancellation = false
        var failOpen = false
        val session = YlDrmKeySession(
            YlDrmSessionIdentity(1, 2, "session", 3), byteArrayOf(9), "video/mp4",
            dispatcher = StandardTestDispatcher(scope.testScheduler), timeoutMs = 1000,
            makeDriver = { Driver().also { it.failOpen = failOpen; drivers += it } },
            exchange = { request ->
                requests += request
                val reply = CompletableDeferred<ByteArray>().also { replies += it }
                if (ignoreCancellation) withContext(NonCancellable) { reply.await() } else reply.await()
            }, onFailure = { failures += it })
    }
    @Test fun `HTTP success is not usable keys and duplicate response cannot install twice`() = runTest {
        val f = Fixture(this); val ready = f.session.start(); runCurrent()
        assertFalse(ready.isCompleted)
        val bytes = byteArrayOf(7, 8)
        f.replies.single().complete(bytes); runCurrent()
        assertEquals(YlDrmKeyPhase.AWAITING_KEYS, f.session.phase)
        assertFalse(ready.isCompleted); assertEquals(1, f.drivers.single().installs)
        assertContentEquals(byteArrayOf(0, 0), f.drivers.single().retained.single())
        assertContentEquals(byteArrayOf(7, 8), bytes) // caller-owned buffer isn't mutated
        f.drivers.single().usable(); runCurrent(); ready.await()
        assertEquals(YlDrmKeyPhase.USABLE, f.session.phase)
        f.session.dispose(); assertEquals(1, f.drivers.single().closes)
    }
    @Test fun `background cancels old callbacks and foreground owns a new driver`() = runTest {
        val f = Fixture(this); f.ignoreCancellation = true
        val first = f.session.start(); runCurrent()
        val old = f.drivers.single()
        f.session.suspendSession(); assertTrue(first.isCancelled)
        val second = f.session.start(); runCurrent()
        assertEquals(2, f.drivers.size); assertEquals(1, old.closes)
        f.replies[0].complete(byteArrayOf(4)); old.usable(); runCurrent()
        assertEquals(0, old.installs); assertFalse(second.isCompleted)
        f.replies[1].complete(byteArrayOf(5)); runCurrent()
        f.drivers[1].usable(); runCurrent(); second.await()
        f.session.dispose(); assertEquals(listOf(1, 1), f.drivers.map { it.closes })
    }
    @Test fun `deadline includes waiting for system usable keys`() = runTest {
        val f = Fixture(this); val ready = f.session.start(); runCurrent()
        f.replies.single().complete(byteArrayOf(5)); runCurrent()
        advanceTimeBy(1000); runCurrent()
        assertTrue(ready.isCompleted)
        assertEquals(listOf(YlFailureKind.DRM_LICENSE_TIMEOUT), f.failures)
        assertEquals(1, f.drivers.single().closes)
        f.drivers.single().usable(); runCurrent()
        assertEquals(YlDrmKeyPhase.FAILED, f.session.phase)
        f.session.dispose()
    }
    @Test fun `renewal coalesces repeated events and dispose discards late results`() = runTest {
        val f = Fixture(this); f.ignoreCancellation = true
        val ready = f.session.start(); runCurrent()
        f.replies[0].complete(byteArrayOf(4)); runCurrent(); f.drivers[0].usable(); runCurrent(); ready.await()
        repeat(5) { f.drivers[0].event(YlDrmSystemEvent.KEY_REQUIRED) }; runCurrent()
        assertEquals(2, f.requests.size)
        f.session.dispose(); f.replies[1].complete(byteArrayOf(6)); runCurrent()
        assertEquals(1, f.drivers[0].installs)
        assertEquals(1, f.drivers[0].closes)
        assertEquals(YlDrmKeyPhase.DISPOSED, f.session.phase)
        assertTrue(f.failures.isEmpty())
    }
    @Test fun `denial is not expiry and explicit system expiry is distinguished`() = runTest {
        val denied = Fixture(this); denied.session.start(); runCurrent()
        denied.replies[0].completeExceptionally(YlBoundaryException(YlFailureKind.DRM_LICENSE_DENIED)); runCurrent()
        assertEquals(listOf(YlFailureKind.DRM_LICENSE_DENIED), denied.failures)
        denied.session.dispose()
        val expired = Fixture(this); expired.session.start(); runCurrent()
        expired.drivers[0].event(YlDrmSystemEvent.EXPIRED); runCurrent()
        assertEquals(listOf(YlFailureKind.DRM_LICENSE_EXPIRED), expired.failures)
        assertEquals(1, expired.drivers[0].closes); expired.session.dispose()
    }
    @Test fun `failed candidate cannot revoke another session and open failure releases driver`() = runTest {
        val active = Fixture(this); val ready = active.session.start(); runCurrent()
        active.replies[0].complete(byteArrayOf(4)); runCurrent(); active.drivers[0].usable(); runCurrent(); ready.await()
        val candidate = Fixture(this); candidate.failOpen = true
        candidate.session.start(); runCurrent()
        assertEquals(listOf(YlFailureKind.DRM_PROTECTION_INSUFFICIENT), candidate.failures)
        assertEquals(1, candidate.drivers[0].closes)
        assertEquals(YlDrmKeyPhase.USABLE, active.session.phase)
        assertEquals(0, active.drivers[0].closes)
        active.session.dispose(); candidate.session.dispose()
    }
    @Test fun `oversize response and system output restriction fail closed`() = runTest {
        val f = Fixture(this); f.session.start(); runCurrent()
        f.replies[0].complete(ByteArray(4 * 1024 * 1024 + 1)); runCurrent()
        assertEquals(listOf(YlFailureKind.DRM_PAYLOAD_TOO_LARGE), f.failures)
        assertEquals(0, f.drivers[0].installs); f.session.dispose()
        val g = Fixture(this); g.session.start(); runCurrent()
        g.drivers[0].event(YlDrmSystemEvent.OUTPUT_RESTRICTED); runCurrent()
        assertEquals(listOf(YlFailureKind.DRM_PROTECTION_INSUFFICIENT), g.failures)
        g.session.dispose()
    }
    @Test fun `pending status revokes usable state and cannot wait forever`() = runTest {
        val f = Fixture(this); val ready = f.session.start(); runCurrent()
        f.replies[0].complete(byteArrayOf(4)); runCurrent(); f.drivers[0].usable(); runCurrent(); ready.await()
        f.drivers[0].event(YlDrmSystemEvent.PENDING); runCurrent()
        assertEquals(YlDrmKeyPhase.AWAITING_KEYS, f.session.phase)
        advanceTimeBy(1000); runCurrent()
        assertEquals(listOf(YlFailureKind.DRM_LICENSE_TIMEOUT), f.failures)
        f.session.dispose()
    }
    @Test fun `queued initial key request cannot publish readiness before renewal finishes`() = runTest {
        val f = Fixture(this); val ready = f.session.start(); runCurrent()
        repeat(8) { f.drivers[0].event(YlDrmSystemEvent.KEY_REQUIRED) }; runCurrent()
        f.replies[0].complete(byteArrayOf(4)); runCurrent(); f.drivers[0].usable(); runCurrent()
        assertEquals(2, f.requests.size); assertFalse(ready.isCompleted)
        f.replies[1].complete(byteArrayOf(5)); runCurrent(); f.drivers[0].usable(); runCurrent()
        ready.await(); assertEquals(YlDrmKeyPhase.USABLE, f.session.phase)
        f.session.dispose()
    }
    @Test fun `timeout cancels transport and late result cannot install even before dispose`() = runTest {
        val f = Fixture(this); f.ignoreCancellation = true; f.session.start(); runCurrent()
        advanceTimeBy(1000); runCurrent()
        f.replies[0].complete(byteArrayOf(9)); f.drivers[0].usable(); runCurrent()
        assertEquals(0, f.drivers[0].installs)
        assertEquals(YlDrmKeyPhase.FAILED, f.session.phase)
        assertEquals(listOf(YlFailureKind.DRM_LICENSE_TIMEOUT), f.failures)
        f.session.dispose(); f.session.dispose(); assertEquals(1, f.drivers[0].closes)
    }
    @Test fun `pending then key-required starts a renewal without waiting for usable`() = runTest {
        val f = Fixture(this); val ready = f.session.start(); runCurrent()
        f.replies[0].complete(byteArrayOf(4)); runCurrent(); f.drivers[0].usable(); runCurrent(); ready.await()
        f.drivers[0].event(YlDrmSystemEvent.PENDING)
        f.drivers[0].event(YlDrmSystemEvent.KEY_REQUIRED); runCurrent()
        assertEquals(2, f.requests.size)
        f.replies[1].complete(byteArrayOf(5)); runCurrent(); f.drivers[0].usable(); runCurrent()
        assertEquals(YlDrmKeyPhase.USABLE, f.session.phase)
        f.session.dispose()
    }
    @Test fun `synchronous install callbacks are processed after successful installation only`() = runTest {
        for (event in listOf(YlDrmSystemEvent.USABLE, YlDrmSystemEvent.FAILED, YlDrmSystemEvent.OUTPUT_RESTRICTED)) {
            var callback: ((YlDrmSystemEvent) -> Unit)? = null
            var closes = 0
            val failures = mutableListOf<YlFailureKind>()
            val driver = object : YlDrmSystemDriver {
                override fun open(value: (YlDrmSystemEvent) -> Unit) { callback = value }
                override fun challenge(initData: ByteArray?, mime: String) = byteArrayOf(1)
                override fun install(response: ByteArray) { callback!!(event) }
                override fun close() { closes++ }
            }
            val session = YlDrmKeySession(YlDrmSessionIdentity(1, 2, "s", 1), byteArrayOf(1), "video/mp4",
                object : CoroutineDispatcher() {
                    override fun dispatch(context: kotlin.coroutines.CoroutineContext, block: Runnable) = block.run()
                }, 1000, { driver }, { byteArrayOf(2) }, { failures += it })
            val ready = session.start(); runCurrent()
            if (event == YlDrmSystemEvent.USABLE) {
                assertTrue(ready.isCompleted); assertEquals(YlDrmKeyPhase.USABLE, session.phase)
                assertTrue(failures.isEmpty())
            } else {
                assertEquals(YlDrmKeyPhase.FAILED, session.phase)
                assertEquals(1, closes); assertEquals(1, failures.size)
            }
            session.dispose(); assertEquals(1, closes)
        }
    }
    @Test fun `queued renewal challenge failure completes failure instead of losing its deadline`() = runTest {
        val f = Fixture(this); val ready = f.session.start(); runCurrent()
        f.drivers[0].event(YlDrmSystemEvent.KEY_REQUIRED); runCurrent()
        f.drivers[0].failChallenge = true
        f.replies[0].complete(byteArrayOf(5)); runCurrent()
        assertEquals(YlDrmKeyPhase.FAILED, f.session.phase)
        assertTrue(ready.isCompleted)
        assertEquals(listOf(YlFailureKind.DRM_LICENSE_FAILED), f.failures)
        assertEquals(1, f.drivers[0].closes); f.session.dispose()
    }
    @Test fun `challenge copies and diagnostics never print binary data`() = runTest {
        val f = Fixture(this); f.session.start(); runCurrent()
        val request = f.requests.single(); val copy = request.bytes; copy.fill(99)
        assertContentEquals(byteArrayOf(1, 2, 3), request.bytes)
        assertFalse(request.toString().contains("1, 2, 3"))
        f.session.dispose()
    }
}
