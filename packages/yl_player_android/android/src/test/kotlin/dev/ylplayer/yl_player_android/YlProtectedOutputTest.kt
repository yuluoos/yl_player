package dev.ylplayer.yl_player_android

import android.view.Surface
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.mockito.Mockito.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class YlProtectedOutputTest {
    private class Private : YlPrivateVideoOutput {
        override val surface = mock(Surface::class.java)
        override val identity = YlOutputIdentity(0, false)
        override val isProtected = true
        var releases = 0
        override fun releaseAfterAcknowledgedDetach() { releases++ }
    }
    @Test fun `protected output rejects insecure switch and inspection before touching decoder`() {
        val candidate = Private(); val output = YlEngineVideoOutput(candidate)
        var touches = 0
        assertFailsWith<YlBoundaryException> { output.switchTo(mock(Surface::class.java), YlOutputIdentity(1, true), { touches++ }) }
        val unprotected = object : YlPrivateVideoOutput {
            override val surface = mock(Surface::class.java)
            override val identity = YlOutputIdentity(0, false)
            override fun releaseAfterAcknowledgedDetach() {}
        }
        assertFailsWith<YlBoundaryException> { output.beginInspection(unprotected) { touches++ } }
        assertEquals(0, touches); assertEquals(0, candidate.releases)
        val public = mock(Surface::class.java)
        mockStatic(android.os.SystemClock::class.java).use { output.switchTo(public, YlOutputIdentity(1, true), {}, protected = true) }
        assertEquals(0, candidate.releases)
        output.parkProtected { assertSame(candidate.surface, it) }
        assertNull(output.firstFrameEvent(public, 1)); assertNull(output.firstFrameEvent(candidate.surface, 2))
        output.dispose {}; assertEquals(1, candidate.releases)
    }
    @Test fun `protected replacement rejects inactive and inspection branches`() {
        val candidate = Private(); val output = YlEngineVideoOutput(candidate)
        output.detach {}
        assertFailsWith<YlBoundaryException> { output.installReplacement(mock(Surface::class.java), YlOutputIdentity(1, true), false) {} }
        output.beginInspection(Private()) {}
        assertFailsWith<YlBoundaryException> { output.installReplacement(mock(Surface::class.java), YlOutputIdentity(2, true), true) {} }
        assertEquals(0, candidate.releases)
    }
    @Test fun `holder destruction and retirement detach before returning with attach held`() = runTest {
        val registry = YlProtectedViewRegistry(StandardTestDispatcher(testScheduler), {})
        val port = Port().apply { hold = CompletableDeferred() }
        val id = YlDrmSessionIdentity(1, 1, "holder", 1)
        val binding = registry.register(id, port) {}; binding.commit()
        val claim = registry.claim(id, 1)!!
        claim.available(mock(Surface::class.java)); runCurrent()
        claim.destroyed()
        assertEquals(1, port.parks, "native detach must complete without pumping main")
        port.hold!!.complete(Unit); runCurrent()
        claim.available(mock(Surface::class.java)); runCurrent()
        binding.retire()
        assertEquals(2, port.parks, "retirement must detach before invalidating the claim")
        claim.dispose(); runCurrent()
    }
    @Test fun `native old frame cannot acquire new revision when same surface is rebound`() {
        mockStatic(android.os.SystemClock::class.java).use { clock ->
            val output = YlEngineVideoOutput(Private())
            val surface = mock(Surface::class.java)
            clock.`when`<Long> { android.os.SystemClock.elapsedRealtime() }.thenReturn(100L)
            output.switchTo(surface, YlOutputIdentity(1, true), {}, protected = true)
            clock.`when`<Long> { android.os.SystemClock.elapsedRealtime() }.thenReturn(200L)
            output.switchTo(surface, YlOutputIdentity(2, true), {}, protected = true)
            assertNull(output.firstFrameEvent(surface, 150))
            assertNull(output.firstFrameEvent(surface, 200))
            assertEquals(YlOutputIdentity(2, true), output.firstFrameEvent(surface, 201)?.output)
        }
    }
    @Test fun `destroy waits for worker detach and queued attach rechecks revision`() = runTest {
        val registry = YlProtectedViewRegistry(StandardTestDispatcher(testScheduler), {})
        val attachGate = CompletableDeferred<Unit>()
        val detachEntered = java.util.concurrent.CountDownLatch(1)
        val detachAck = java.util.concurrent.CountDownLatch(1)
        val returned = java.util.concurrent.CountDownLatch(1)
        var attached = false
        val id = YlDrmSessionIdentity(1, 1, "waiting-holder", 1)
        val binding = registry.register(id, object : YlProtectedOutputPort {
            override suspend fun attach(surface: Surface, identity: YlOutputIdentity, isCurrent: () -> Boolean) {
                attachGate.await()
                if (isCurrent()) attached = true
            }
            override suspend fun park() {}
            override fun detachBeforeDestroy() {
                detachEntered.countDown()
                check(detachAck.await(5, java.util.concurrent.TimeUnit.SECONDS))
            }
        }) {}; binding.commit()
        val claim = registry.claim(id, 1)!!
        claim.available(mock(Surface::class.java)); runCurrent()
        val destroy = Thread { try { claim.destroyed() } finally { returned.countDown() } }.apply { start() }
        try {
            assertTrue(detachEntered.await(5, java.util.concurrent.TimeUnit.SECONDS))
            assertEquals(1L, returned.count, "callback must still be waiting for worker ACK")
        } finally { detachAck.countDown(); destroy.join(5000) }
        assertEquals(0L, returned.count)
        attachGate.complete(Unit); runCurrent()
        assertFalse(attached, "a queued worker attach must not borrow a destroyed holder")
        binding.retire()
    }
    private class Port : YlProtectedOutputPort {
        val attachments = mutableListOf<Pair<Surface, YlOutputIdentity>>()
        var parks = 0
        var hold: CompletableDeferred<Unit>? = null
        override suspend fun attach(surface: Surface, identity: YlOutputIdentity, isCurrent: () -> Boolean) { attachments += surface to identity; hold?.await() }
        override suspend fun park() { parks++ }
        override fun detachBeforeDestroy() { parks++ }
    }
    @Test fun `uncommitted unknown and duplicate view cannot borrow another candidate`() = runTest {
        val registry = YlProtectedViewRegistry(StandardTestDispatcher(testScheduler), {})
        val identity = YlDrmSessionIdentity(1, 2, "one", 3)
        val port = Port(); val binding = registry.register(identity, port) {}
        assertNull(registry.claim(identity, 10))
        binding.commit()
        assertNull(registry.claim(identity.copy(generation = 4), 10))
        val claim = assertNotNull(registry.claim(identity, 10))
        assertNull(registry.claim(identity, 11))
        val surface = mock(Surface::class.java)
        claim.available(surface); runCurrent()
        assertEquals(1, port.attachments.size)
        assertEquals(binding.outputIdentity, port.attachments.single().second)
        claim.dispose(); runCurrent(); assertEquals(1, port.parks)
        verify(surface, never()).release()
        binding.retire(); runCurrent()
    }
    @Test fun `late attachment ACK and frame are fenced across holder recreation and retire`() = runTest {
        val registry = YlProtectedViewRegistry(StandardTestDispatcher(testScheduler), {})
        val port = Port(); val id = YlDrmSessionIdentity(1, 2, "one", 3)
        val binding = registry.register(id, port) {}; binding.commit()
        val claim = registry.claim(id, 10)!!
        val ready = mutableListOf<YlOutputIdentity>()
        claim.onFrame = { ready += it }
        port.hold = CompletableDeferred()
        claim.available(mock(Surface::class.java)); runCurrent()
        val old = port.attachments.single().second
        claim.destroyed(); claim.available(mock(Surface::class.java))
        binding.frame(old); assertTrue(ready.isEmpty())
        port.hold!!.complete(Unit); runCurrent()
        val current = port.attachments.last().second
        assertNotEquals(old, current)
        binding.frame(old); assertTrue(ready.isEmpty())
        binding.frame(current); assertEquals(listOf(current), ready)
        binding.retire(); binding.frame(current); runCurrent()
        assertEquals(1, ready.size); assertNull(registry.claim(id, 11))
    }
    @Test fun `failed candidate does not retire current and commit fences previous owner`() = runTest {
        val registry = YlProtectedViewRegistry(StandardTestDispatcher(testScheduler), {})
        val oldId = YlDrmSessionIdentity(1, 1, "old", 1)
        val oldPort = Port(); val old = registry.register(oldId, oldPort) {}; old.commit()
        val oldClaim = registry.claim(oldId, 10)!!; oldClaim.available(mock(Surface::class.java)); runCurrent()
        val failed = registry.register(YlDrmSessionIdentity(1, 2, "failed", 2), Port()) {}
        failed.retire(); runCurrent()
        val frames = mutableListOf<YlOutputIdentity>(); oldClaim.onFrame = { frames += it }
        old.frame(old.outputIdentity); assertEquals(1, frames.size)
        val next = registry.register(YlDrmSessionIdentity(1, 3, "next", 3), Port()) {}; next.commit()
        old.frame(old.outputIdentity); runCurrent(); assertEquals(1, frames.size)
        assertNull(registry.claim(oldId, 11)); assertEquals(1, oldPort.parks)
        next.retire(); runCurrent()
    }
    @Test fun `frame arriving before attach acknowledgement reveals only after acknowledgement`() = runTest {
        val registry = YlProtectedViewRegistry(StandardTestDispatcher(testScheduler), {})
        val port = Port(); val id = YlDrmSessionIdentity(1, 2, "one", 3)
        val binding = registry.register(id, port) {}; binding.commit()
        val claim = registry.claim(id, 10)!!
        var frames = 0; claim.onFrame = { frames++ }
        port.hold = CompletableDeferred()
        claim.available(mock(Surface::class.java)); runCurrent()
        binding.frame(port.attachments.single().second)
        assertEquals(0, frames)
        port.hold!!.complete(Unit); runCurrent(); assertEquals(1, frames)
        binding.retire(); runCurrent()
    }

    @Test fun `protected core rejects ordinary output before attaching decoder`() {
        withCore(coreSource = source().copy(format = dev.ylplayer.yl_player_android.pigeon.AndroidMediaFormat.DASH), protectedDrm = mock(androidx.media3.exoplayer.drm.DrmSessionManager::class.java)) { core, player, _ ->
            val failure = assertFailsWith<YlBoundaryException> { core.switchOutput(mock(Surface::class.java), YlOutputIdentity(1, true)) }
            assertEquals(YlFailureKind.DRM_PROTECTION_INSUFFICIENT, failure.kind)
        }
    }

    @Test fun `coordinator publishes protected frame identity and failed replacement restores old session`() = runTest {
        val f = SessionFixture(StandardTestDispatcher(testScheduler))
        val first = FakeSessionEngine().apply { presentationIdentity = YlOutputIdentity(99, true) }
        f.next = first
        val old = f.coordinator.load(request("protected-old")); runCurrent()
        first.emit(YlEngineEvent.FirstFrame(f.output.identity, 100)); runCurrent()
        assertTrue(f.events.frames.isEmpty())
        first.emit(YlEngineEvent.FirstFrame(first.presentationIdentity!!, 101)); runCurrent()
        assertEquals(listOf(old.sessionId), f.events.frames.map { it.sessionId })
        f.next = FakeSessionEngine().apply {
            presentationIdentity = YlOutputIdentity(100, true)
            activationError = YlBoundaryException(YlFailureKind.DRM_PROTECTION_INSUFFICIENT)
        }
        assertFailsWith<YlBoundaryException> { f.coordinator.load(request("protected-failed")) }
        assertEquals(old.sessionId, f.coordinator.initialState.sessionId)
        assertEquals(1, first.restores)
        f.next = FakeSessionEngine().apply { presentationIdentity = YlOutputIdentity(101, true) }
        val next = f.coordinator.load(request("protected-next")); runCurrent()
        first.emit(YlEngineEvent.FirstFrame(first.presentationIdentity!!, 102)); runCurrent()
        assertEquals(1, f.events.frames.size)
        f.engines.last().emit(YlEngineEvent.FirstFrame(YlOutputIdentity(101, true), 103)); runCurrent()
        assertEquals(next.sessionId, f.events.frames.last().sessionId)
        f.finish()
    }

    @Test fun `declared protected source cannot silently commit clear selected video`() {
        fun tracks(protected: Boolean): androidx.media3.common.Tracks {
            val drm = if (protected) androidx.media3.common.DrmInitData("cenc",
                androidx.media3.common.DrmInitData.SchemeData(androidx.media3.common.C.WIDEVINE_UUID, "video/mp4", byteArrayOf(1))) else null
            val format = androidx.media3.common.Format.Builder().setSampleMimeType("video/avc").setDrmInitData(drm).build()
            return androidx.media3.common.Tracks(listOf(androidx.media3.common.Tracks.Group(
                androidx.media3.common.TrackGroup("v", format), false, intArrayOf(androidx.media3.common.C.FORMAT_HANDLED), booleanArrayOf(true))))
        }
        mockStatic(android.text.TextUtils::class.java) { call ->
            if (call.method.name == "isEmpty") (call.arguments[0] as? CharSequence).isNullOrEmpty() else call.callRealMethod()
        }.use {
            assertEquals(YlFailureKind.DRM_CONFIG_INVALID, assertFailsWith<YlBoundaryException> { requireProtectedTracks(tracks(false)) }.kind)
            requireProtectedTracks(tracks(true))
        }
    }

    @Test fun `protected primary never invokes clear native fallback on decoder failure`() = runTest {
        val primary = FakeSessionEngine().apply {
            identity = YlSessionIdentity("protected", "load")
            presentationIdentity = YlOutputIdentity(1, true)
            prepareError = YlBoundaryException(YlFailureKind.DECODER_UNAVAILABLE)
        }
        var fallbacks = 0
        val managed = YlManagedAndroidEngine(primary.identity, primary, { fallbacks++; FakeSessionEngine() }, StandardTestDispatcher(testScheduler))
        assertFailsWith<YlBoundaryException> { managed.prepare() }
        assertEquals(0, fallbacks); managed.dispose().await()
    }

}
