package dev.ylplayer.yl_player_android

import android.view.Surface
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*
import org.mockito.Mockito.*
import io.flutter.view.TextureRegistry

@OptIn(ExperimentalCoroutinesApi::class)
class YlCandidateVideoOutputTest {
    @Test fun `configuration replacement during strict inspection cannot publish the new public surface`() {
        val output = YlEngineVideoOutput(FakePrivateOutput())
        val previous = mock(Surface::class.java)
        val replacement = mock(Surface::class.java)
        output.switchTo(previous, YlOutputIdentity(1, true)) { }
        val inspection = FakePrivateOutput()
        output.beginInspection(inspection) { }
        output.detach { }
        var attached: Surface? = null
        output.installReplacement(replacement, YlOutputIdentity(2, true), true) { attached = it }
        assertSame(inspection.surface, attached)
        assertEquals(0, inspection.releases)
        assertNull(output.firstFrameEvent(replacement, 10))
        output.finishInspection { attached = it }
        assertSame(replacement, attached)
        assertEquals(1, inspection.releases)
    }
    @Test fun `strict reacquisition keeps public surface private until new evidence and acknowledged handoff`() {
        val output = YlEngineVideoOutput(FakePrivateOutput())
        val public = mock(Surface::class.java)
        output.switchTo(public, YlOutputIdentity(1, true)) { }
        val inspection = FakePrivateOutput()
        output.beginInspection(inspection) { assertSame(inspection.surface, it) }
        assertNull(output.firstFrameEvent(inspection.surface, 10))
        assertNull(output.firstFrameEvent(public, 10))
        assertFailsWith<IllegalStateException> { output.finishInspection { throw IllegalStateException() } }
        assertEquals(0, inspection.releases)
        output.finishInspection { assertSame(public, it) }
        assertEquals(1, inspection.releases)
        assertNotNull(output.firstFrameEvent(public, 20))
    }
    @Test fun `foreground during recreate install gap never attaches a released wrapper`() = runTest {
        val main = StandardTestDispatcher(testScheduler, "main")
        val worker = StandardTestDispatcher(testScheduler, "worker")
        val released = mutableSetOf<Surface>()
        mockConstruction(Surface::class.java) { surface, _ ->
            doAnswer { released += surface; null }.`when`(surface).release()
        }.use {
            val public = YlVideoOutput(mock(TextureRegistry.SurfaceTextureEntry::class.java), ownsTexture = false)
            val output = YlEngineVideoOutput(FakePrivateOutput())
            var active = true
            val old = public.borrowSurface()
            output.switchTo(old, public.identity) { }
            val recreated = CompletableDeferred<Unit>()
            val install = CompletableDeferred<Unit>()
            val attached = mutableListOf<Surface>()
            val replacement = launch(main) {
                replacePublicVideoOutput(public,
                    canRebuild = { withContext(worker) { active } },
                    detach = { withContext(worker) { output.detach { } } },
                    install = { surface, identity ->
                        recreated.complete(Unit)
                        install.await()
                        withContext(worker) {
                            output.installReplacement(surface, identity, active) {
                                assertFalse(it in released)
                                attached += it
                            }
                        }
                    })
            }
            runCurrent()
            recreated.await()
            withContext(worker) {
                active = false
                output.detach { }
                active = true
                output.attach(1, 1) {
                    assertFalse(it in released, "Foreground must not reattach a released wrapper before installation")
                    attached += it
                }
            }
            assertFalse(old in released)
            install.complete(Unit)
            runCurrent()
            replacement.join()
            val current = public.borrowSurface()
            assertSame(current, attached.last())
            assertFalse(current in released)
            assertTrue(old in released)
            public.release()
        }
    }
    @Test fun `background during actual public replacement retains current unreleased output for foreground`() = runTest {
        for (holdAfter in listOf("canRebuild", "detach")) {
            val main = StandardTestDispatcher(testScheduler, "main")
            val worker = StandardTestDispatcher(testScheduler, "worker")
            val released = mutableSetOf<Surface>()
            mockConstruction(Surface::class.java) { surface, _ ->
                doAnswer { released += surface; null }.`when`(surface).release()
            }.use {
                val texture = mock(TextureRegistry.SurfaceTextureEntry::class.java)
                val public = YlVideoOutput(texture, ownsTexture = false)
                val output = YlEngineVideoOutput(FakePrivateOutput())
                var active = true
                val attached = mutableListOf<Surface>()
                val old = public.borrowSurface()
                output.switchTo(old, public.identity) { attached += it }
                attached.clear()
                val held = CompletableDeferred<Unit>()
                val continueReplacement = CompletableDeferred<Unit>()
                val replacement = launch(main) {
                    replacePublicVideoOutput(public,
                        canRebuild = {
                            val allowed = withContext(worker) { active }
                            if (holdAfter == "canRebuild") { held.complete(Unit); continueReplacement.await() }
                            allowed
                        },
                        detach = {
                            withContext(worker) { output.detach { } }
                            if (holdAfter == "detach") { held.complete(Unit); continueReplacement.await() }
                        },
                        install = { surface, identity ->
                            withContext(worker) { output.installReplacement(surface, identity, active) { attached += it } }
                        })
                }
                runCurrent()
                held.await()
                withContext(worker) { active = false; output.detach { } }
                continueReplacement.complete(Unit)
                runCurrent()
                replacement.join()
                val current = public.borrowSurface()
                assertTrue(old in released)
                assertNotSame(old, current)
                assertTrue(attached.isEmpty(), "Background install must retain output without attaching it")
                assertNull(output.renderedIdentity(current))
                withContext(worker) {
                    active = true
                    output.attach(1, 1) { attached += it }
                }
                assertSame(current, attached.single())
                assertFalse(attached.single() in released)
                assertEquals(public.identity, output.renderedIdentity(current))
                public.release()
            }
        }
    }
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
