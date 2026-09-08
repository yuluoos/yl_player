package dev.ylplayer.yl_player_android

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class YlDecoderLeaseCoordinatorTest {
    @Test fun `quiesce failure disposes candidate without changing owner`() = runTest {
        val f = LeaseFixture(StandardTestDispatcher(testScheduler)) { testScheduler.currentTime }
        val old = f.player("old").apply { quiesceError = true }
        f.leases.acquire(old) {}
        val next = f.player("next")
        assertFailsWith<IllegalStateException> { f.leases.acquire(next) {} }
        assertEquals(old, f.leases.owner)
        assertEquals(1, next.disposals)
        assertEquals(0, next.activations)
        assertEquals(0, old.restores)
    }
    @Test fun `quiesce deadline waits for acknowledgement then restores without activation`() = runTest {
        val f = LeaseFixture(StandardTestDispatcher(testScheduler)) { testScheduler.currentTime }
        val old = f.player("old").apply { holdQuiesce = true }
        f.leases.acquire(old) {}
        val next = f.player("next")
        val result = async { runCatching { f.leases.acquire(next) {} } }
        runCurrent(); advanceTimeBy(5_000); runCurrent()
        assertFalse(result.isCompleted)
        assertEquals(0, next.activations)
        old.quiesceCallback!!(Result.success(old.snapshot()))
        runCurrent()
        assertEquals(YlFailureKind.RESOURCE_EXHAUSTED, (result.await().exceptionOrNull() as YlBoundaryException).kind)
        assertEquals(1, old.restores)
        assertEquals(0, next.activations)
    }
    @Test fun `restore deadline quarantines release and late success cannot change ownership`() = runTest {
        val f = LeaseFixture(StandardTestDispatcher(testScheduler)) { testScheduler.currentTime }
        val old = f.player("old").apply { holdRestore = true; release = CompletableDeferred() }
        f.leases.acquire(old) {}
        val next = f.player("next").apply { activationError = true }
        val result = async { runCatching { f.leases.acquire(next) {} } }
        runCurrent(); advanceTimeBy(15_000); runCurrent()
        assertNull(f.leases.owner)
        assertEquals(1, old.restoreFailures)
        assertFalse(result.isCompleted)
        val last = f.player("last")
        val newer = async { f.leases.acquire(last) {} }
        runCurrent()
        assertEquals(0, last.activations)
        old.restoreCallback!!(Result.success(Unit))
        runCurrent()
        assertNull(f.leases.owner)
        old.release.complete(Unit)
        runCurrent(); newer.await()
        assertEquals(last, f.leases.owner)
        assertTrue(result.await().isFailure)
    }
    @Test fun `nonexclusive replacements quiesce their own former without touching video peer`() = runTest {
        val f = LeaseFixture(StandardTestDispatcher(testScheduler)) { testScheduler.currentTime }
        val video = f.player("video")
        f.leases.acquire(video) {}
        val oldAudio = f.player("audio:old").apply { needsExclusiveLease = false; exclusiveAfterActivation = false }
        f.leases.acquire(oldAudio) {}
        val nextAudio = f.player("audio:new").apply { needsExclusiveLease = false; exclusiveAfterActivation = false }
        f.leases.acquire(nextAudio, oldAudio) {}
        assertEquals(video, f.leases.owner)
        assertEquals(0, video.quiesces)
        assertEquals(1, oldAudio.quiesces)
        assertEquals(1, oldAudio.deactivations)
    }

    @Test fun `prepare failure does not touch prior owner`() = runTest {
        val f = LeaseFixture(StandardTestDispatcher(testScheduler)) { testScheduler.currentTime }
        val old = f.player("old")
        f.leases.acquire(old) {}
        val next = f.player("next")
        assertFailsWith<IllegalStateException> { f.leases.acquire(next) { error("prepare") } }
        assertEquals(old, f.leases.owner)
        assertEquals(0, old.quiesces)
    }
    @Test fun `activation and commit failure restore exactly once after candidate release`() = runTest {
        for (commit in listOf(false, true)) {
            val f = LeaseFixture(StandardTestDispatcher(testScheduler)) { testScheduler.currentTime }
            val old = f.player("old")
            f.leases.acquire(old) {}
            val next = f.player("next").apply { if (commit) commitError = true else activationError = true }
            assertFailsWith<IllegalStateException> { f.leases.acquire(next) {} }
            assertEquals(old, f.leases.owner)
            assertEquals(1, old.restores)
            assertTrue(f.calls.indexOf("next:dispose") < f.calls.indexOf("old:restore"))
            assertEquals(0, old.deactivations)
        }
    }
    @Test fun `commit precedes prior deactivation and same player old engine participates`() = runTest {
        val f = LeaseFixture(StandardTestDispatcher(testScheduler)) { testScheduler.currentTime }
        val old = f.player("p:old")
        f.leases.acquire(old) {}
        val next = f.player("p:new")
        f.leases.acquire(next) {}
        assertEquals(next, f.leases.owner)
        assertEquals(1, old.quiesces)
        assertTrue(f.calls.indexOf("p:new:commit") < f.calls.indexOf("p:old:deactivate"))
    }
    @Test fun `new request waits for safe candidate release then rollback before ownership transfer`() = runTest {
        val f = LeaseFixture(StandardTestDispatcher(testScheduler)) { testScheduler.currentTime }
        val old = f.player("old")
        f.leases.acquire(old) {}
        val first = f.player("first").apply { holdActivation = true; release = CompletableDeferred() }
        val a = async { runCatching { f.leases.acquire(first) {} } }
        runCurrent()
        val second = f.player("second")
        val b = async { f.leases.acquire(second) {} }
        runCurrent()
        assertFalse(b.isCompleted)
        assertEquals(0, second.activations)
        first.release.complete(Unit)
        runCurrent()
        b.await()
        first.activationCallback!!(Result.success(Unit))
        runCurrent()
        assertEquals(second, f.leases.owner)
        assertTrue(a.await().isFailure)
    }
    @Test fun `activation deadline releases candidate and observes asynchronous restore`() = runTest {
        val f = LeaseFixture(StandardTestDispatcher(testScheduler)) { testScheduler.currentTime }
        val old = f.player("old").apply { holdRestore = true }
        f.leases.acquire(old) {}
        val next = f.player("next").apply { holdActivation = true }
        val result = async { runCatching { f.leases.acquire(next) {} } }
        runCurrent(); advanceTimeBy(15_000); runCurrent()
        assertEquals(1, next.disposals)
        assertEquals(1, old.restores)
        assertFalse(result.isCompleted)
        old.restoreCallback!!(Result.success(Unit))
        runCurrent()
        assertEquals(YlFailureKind.RESOURCE_EXHAUSTED, (result.await().exceptionOrNull() as YlBoundaryException).kind)
        assertEquals(old, f.leases.owner)
    }
    @Test fun `restore failure clears resource ownership and reports prior terminal failure`() = runTest {
        val f = LeaseFixture(StandardTestDispatcher(testScheduler)) { testScheduler.currentTime }
        val old = f.player("old").apply { restoreError = true }
        f.leases.acquire(old) {}
        val next = f.player("next").apply { activationError = true }
        val error = assertFailsWith<YlBoundaryException> { f.leases.acquire(next) {} }
        assertEquals(YlFailureKind.RESOURCE_EXHAUSTED, error.kind)
        assertEquals(1, old.restoreFailures)
        assertNull(f.leases.owner)
    }
    @Test fun `detach releases previous and candidate without restoring`() = runTest {
        val f = LeaseFixture(StandardTestDispatcher(testScheduler)) { testScheduler.currentTime }
        val old = f.player("old")
        f.leases.acquire(old) {}
        val next = f.player("next").apply { holdActivation = true }
        val result = async { runCatching { f.leases.acquire(next) {} } }
        runCurrent(); f.leases.detach(); runCurrent()
        assertTrue(result.await().isFailure)
        assertTrue(old.disposals > 0)
        assertTrue(next.disposals > 0)
        assertEquals(0, old.restores)
        assertNull(f.leases.owner)
    }
    @Test fun `unknown candidate proven nonexclusive restores prior before audio commit`() = runTest {
        val f = LeaseFixture(StandardTestDispatcher(testScheduler)) { testScheduler.currentTime }
        val old = f.player("video")
        f.leases.acquire(old) {}
        val audio = f.player("audio").apply { exclusiveAfterActivation = false }
        f.leases.acquire(audio) {}
        assertEquals(old, f.leases.owner)
        assertEquals(1, old.restores)
        assertEquals(0, old.deactivations)
        assertTrue(f.calls.indexOf("video:restore") < f.calls.indexOf("audio:commit"))
    }
}
private class LeaseFixture(dispatcher: CoroutineDispatcher, clock: () -> Long) {
    val calls = mutableListOf<String>()
    val leases = YlDecoderLeaseCoordinator(dispatcher, clock)
    fun player(id: String) = LeasePlayer(id, calls)
}
private class LeasePlayer(override val leaseId: String, val calls: MutableList<String>) : YlDecoderLeaseParticipant {
    override val playerLeaseId get() = leaseId.substringBefore(':')
    override var needsExclusiveLease = true
    var exclusiveAfterActivation = true
    var quiesceError = false
    var holdQuiesce = false
    var quiesceCallback: ((Result<YlLeaseSnapshot>) -> Unit)? = null
    var activationError = false
    var commitError = false
    var restoreError = false
    var holdActivation = false
    var holdRestore = false
    var release = CompletableDeferred(Unit)
    var activationCallback: ((Result<Unit>) -> Unit)? = null
    var restoreCallback: ((Result<Unit>) -> Unit)? = null
    var quiesces = 0; var activations = 0; var restores = 0; var disposals = 0
    var deactivations = 0; var restoreFailures = 0
    override fun quiesceForLease(attempt: YlLeaseAttempt, complete: (Result<YlLeaseSnapshot>) -> Unit): YlCancelHandle {
        quiesces++; calls += "$leaseId:quiesce"
        quiesceCallback = complete
        if (!holdQuiesce) complete(if (quiesceError) Result.failure(IllegalStateException()) else Result.success(snapshot()))
        return YlCancelHandle {}
    }
    fun snapshot() = YlLeaseSnapshot(YlSessionIdentity(leaseId, leaseId), source(), request("x").options,
        YlEngineRestorePoint(123, false, true), YlOutputIdentity(1, true))
    override fun activateForLease(attempt: YlLeaseAttempt, complete: (Result<Unit>) -> Unit): YlCancelHandle {
        activations++; calls += "$leaseId:activate"; needsExclusiveLease = exclusiveAfterActivation
        activationCallback = complete
        if (!holdActivation) complete(if (activationError) Result.failure(IllegalStateException()) else Result.success(Unit))
        return YlCancelHandle {}
    }
    override fun commitLease() { calls += "$leaseId:commit"; if (commitError) error("commit") }
    override fun rollbackLease(snapshot: YlLeaseSnapshot, attempt: YlLeaseAttempt, complete: (Result<Unit>) -> Unit): YlCancelHandle {
        restores++; calls += "$leaseId:restore"; restoreCallback = complete
        if (!holdRestore) complete(if (restoreError) Result.failure(IllegalStateException()) else Result.success(Unit))
        return YlCancelHandle {}
    }
    override fun deactivateAfterLeaseTransfer() { deactivations++; calls += "$leaseId:deactivate" }
    override fun disposeForLease(): Deferred<Unit> { disposals++; calls += "$leaseId:dispose"; return release }
    override fun restorationFailed() { restoreFailures++ }
    override val canRestore get() = true
}
