package dev.ylplayer.yl_player_android

import android.view.Surface
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*
import org.mockito.Mockito.mock

@OptIn(ExperimentalCoroutinesApi::class)
class YlCandidateVideoOutputTest {
    @Test fun `acknowledged detach revokes render eligibility while retaining owned resources`() {
        val candidate = FakePrivateOutput()
        val output = YlEngineVideoOutput(candidate)
        val public = mock(Surface::class.java)
        output.switchTo(public, YlOutputIdentity(1, true)) { }
        output.detach { }
        assertNull(output.renderedIdentity(public))
        var reattached: Surface? = null
        output.attach(1, 1) { reattached = it }
        assertSame(public, reattached)
        assertEquals(YlOutputIdentity(1, true), output.renderedIdentity(public))
    }
    @Test fun `worker accepted old frame crossing rebuild cannot consume main public milestone`() = runTest {
        val main = StandardTestDispatcher(testScheduler, "main")
        val worker = StandardTestDispatcher(testScheduler, "worker")
        val f = SessionFixture(main)
        f.coordinator.load(request("one"))
        val output = YlEngineVideoOutput(FakePrivateOutput())
        val oldSurface = mock(Surface::class.java)
        val newSurface = mock(Surface::class.java)
        val delivery = CompletableDeferred<Unit>()
        val accepted = CompletableDeferred<Unit>()
        output.switchTo(oldSurface, f.output.identity) { }
        val oldCallback = launch(worker) {
            val event = checkNotNull(output.firstFrameEvent(oldSurface, 10))
            accepted.complete(Unit)
            delivery.await()
            withContext(main) { f.engines.single().emit(event) }
        }
        runCurrent()
        accepted.await()
        withContext(worker) { output.detach { } }
        f.output.identity = YlOutputIdentity(2, true)
        withContext(worker) { output.switchTo(newSurface, f.output.identity) { } }
        delivery.complete(Unit)
        runCurrent()
        oldCallback.join()
        assertTrue(f.events.frames.isEmpty())
        repeat(2) {
            val event = withContext(worker) { output.firstFrameEvent(newSurface, 20) }
            event?.let { withContext(main) { f.engines.single().emit(it) } }
        }
        assertEquals(20L, f.events.frames.single().occurredAtMs)
        f.finish()
    }
    @Test fun `private resource releases only after successful public output acknowledgement`() {
        val candidate = FakePrivateOutput()
        val output = YlEngineVideoOutput(candidate)
        val public = mock(Surface::class.java)
        val publicIdentity = YlOutputIdentity(1, true)
        assertFailsWith<IllegalStateException> { output.switchTo(public, publicIdentity) { throw IllegalStateException() } }
        assertEquals(0, candidate.releases)
        assertEquals(candidate.identity, output.renderedIdentity(candidate.surface))
        output.switchTo(public, publicIdentity) { assertEquals(0, candidate.releases) }
        assertEquals(1, candidate.releases)
        assertNull(output.renderedIdentity(candidate.surface))
        assertEquals(publicIdentity, output.renderedIdentity(public))
    }
    @Test fun `rollback retains private resources on unacknowledged detach`() {
        val candidate = FakePrivateOutput()
        val output = YlEngineVideoOutput(candidate)
        assertFailsWith<IllegalStateException> { output.dispose { throw IllegalStateException() } }
        assertEquals(0, candidate.releases)
        output.dispose { }
        output.dispose { }
        assertEquals(1, candidate.releases)
    }
    private class FakePrivateOutput : YlPrivateVideoOutput {
        override val surface = mock(Surface::class.java)
        override val identity = YlOutputIdentity(0, false)
        var releases = 0
        override fun releaseAfterAcknowledgedDetach() { releases++ }
    }
}
