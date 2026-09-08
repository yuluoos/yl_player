package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class YlSessionAudioTest {
    private val managed = sessionOptions.copy(audioPolicy = AndroidAudioPolicy.PLUGIN_MANAGED_MEDIA_PLAYBACK)
    @Test fun `noisy and permanent loss pause all participants and late gain cannot restart them`() = runTest {
        for (change in listOf(YlAudioFocusChange.NOISY, YlAudioFocusChange.LOSS)) {
            val driver = RecordingAudioDriver(); val audio = YlAudioFocusCoordinator(driver)
            val a = SessionFixture(StandardTestDispatcher(testScheduler), options = managed, audioFocus = { audio })
            val b = SessionFixture(StandardTestDispatcher(testScheduler), 8, managed, { audio })
            a.coordinator.load(request("a").withAutoplay(true)); b.coordinator.load(request("b").withAutoplay(true)); runCurrent()
            val callback = assertNotNull(driver.listener)
            if (change == YlAudioFocusChange.NOISY) assertNotNull(driver.noisy)() else callback(change)
            runCurrent()
            assertFalse(a.engines.single().playing); assertFalse(b.engines.single().playing)
            assertEquals(listOf("request", "register", "unregister", "abandon"), driver.calls)
            callback(YlAudioFocusChange.GAIN); runCurrent()
            assertEquals(1, a.engines.single().playCalls); assertEquals(1, b.engines.single().playCalls)
            a.finish(); b.finish()
        }
    }
    @Test fun `same player successful autoplay handoff retains ownership and nonautoplay replacement releases it`() = runTest {
        val driver = RecordingAudioDriver(); val audio = YlAudioFocusCoordinator(driver)
        val f = SessionFixture(StandardTestDispatcher(testScheduler), options = managed, audioFocus = { audio })
        f.coordinator.load(request("one").withAutoplay(true)); runCurrent()
        f.coordinator.load(request("two").withAutoplay(true)); runCurrent()
        assertEquals(listOf("request", "register"), driver.calls)
        assertTrue(f.engines.last().playing)
        f.coordinator.load(request("three")); runCurrent()
        assertFalse(f.engines.last().playing)
        assertEquals(listOf("request", "register", "unregister", "abandon"), driver.calls)
        f.finish()
    }
    @Test fun `cross player candidate failure keeps acquired focus throughout quiesce and rollback`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val leases = YlDecoderLeaseCoordinator(dispatcher) { testScheduler.currentTime }
        val driver = RecordingAudioDriver(); val audio = YlAudioFocusCoordinator(driver)
        val a = SessionFixture(dispatcher, 1, managed, { audio }).also { it.coordinator.bindLeases(leases) }
        val b = SessionFixture(dispatcher, 2, managed, { audio }).also { it.coordinator.bindLeases(leases) }
        a.coordinator.load(request("one").withAutoplay(true)); runCurrent()
        val candidate = FakeSessionEngine().apply { activationAcknowledgement = CompletableDeferred(); activationError = YlBoundaryException(YlFailureKind.DECODER_UNAVAILABLE) }
        b.next = candidate
        val load = async { runCatching { b.coordinator.load(request("two").withAutoplay(true)) } }; runCurrent()
        assertFalse(a.engines.single().playing)
        assertEquals(listOf("request", "register"), driver.calls)
        candidate.activationAcknowledgement!!.complete(Unit); runCurrent(); assertTrue(load.await().isFailure)
        assertTrue(a.engines.single().playing)
        assertEquals(listOf("request", "register"), driver.calls)
        a.finish(); b.finish()
    }
    @Test fun `focus gain awaiting volume cannot replay into a pending background quiesce`() = runTest {
        val driver = RecordingAudioDriver(); val audio = YlAudioFocusCoordinator(driver)
        val f = SessionFixture(StandardTestDispatcher(testScheduler), options = managed, audioFocus = { audio })
        f.coordinator.load(request("one").withAutoplay(true)); runCurrent()
        val engine = f.engines.single(); val callback = assertNotNull(driver.listener)
        callback(YlAudioFocusChange.LOSS_TRANSIENT); runCurrent()
        engine.volumeAcknowledgement = CompletableDeferred()
        callback(YlAudioFocusChange.GAIN); runCurrent()
        engine.quiesceAcknowledgement = CompletableDeferred()
        f.coordinator.onBackground(); runCurrent()
        engine.volumeAcknowledgement!!.complete(Unit); runCurrent()
        assertEquals(1, engine.playCalls)
        assertFalse(engine.playing)
        engine.quiesceAcknowledgement!!.complete(Unit); runCurrent()
        f.finish()
    }
    @Test fun `managed explicit play awaiting volume preserves intent through background without playing hidden`() = runTest {
        val driver = RecordingAudioDriver(); val audio = YlAudioFocusCoordinator(driver)
        val f = SessionFixture(StandardTestDispatcher(testScheduler), options = managed, audioFocus = { audio })
        val id = f.coordinator.load(request("one")).sessionId; runCurrent()
        val engine = f.engines.single(); engine.volumeAcknowledgement = CompletableDeferred()
        val play = async { f.coordinator.play(AndroidSessionCommand(id)) }; runCurrent()
        f.coordinator.onBackground(); runCurrent()
        engine.volumeAcknowledgement!!.complete(Unit); runCurrent(); play.await()
        assertEquals(0, engine.playCalls); assertFalse(engine.playing)
        f.coordinator.onForeground(); runCurrent(); assertTrue(engine.playing)
        f.finish()
    }
    @Test fun `app managed play pause background stop and close never touch shared driver`() = runTest {
        val driver = RecordingAudioDriver()
        val audio = YlAudioFocusCoordinator(driver)
        val f = SessionFixture(StandardTestDispatcher(testScheduler), audioFocus = { audio })
        val id = f.coordinator.load(request("one").withAutoplay(true)).sessionId
        runCurrent(); f.coordinator.pause(AndroidSessionCommand(id)); runCurrent()
        f.coordinator.play(AndroidSessionCommand(id)); f.coordinator.onBackground(); runCurrent()
        f.coordinator.onForeground(); runCurrent(); f.coordinator.stop(); f.finish()
        assertTrue(driver.calls.isEmpty())
    }
    @Test fun `candidate prepare is silent and denied direct play never starts engine`() = runTest {
        val driver = RecordingAudioDriver().apply { granted = false }
        val audio = YlAudioFocusCoordinator(driver)
        val f = SessionFixture(StandardTestDispatcher(testScheduler), options = managed, audioFocus = { audio })
        val id = f.coordinator.load(request("one")).sessionId
        runCurrent(); assertTrue(driver.calls.isEmpty())
        assertFailsWith<YlBoundaryException> { f.coordinator.play(AndroidSessionCommand(id)) }
        assertEquals(0, f.engines.single().playCalls)
        f.finish(); assertEquals(listOf("request"), driver.calls)
    }
    @Test fun `denied autoplay reports failure after commit without starting engine`() = runTest {
        val driver = RecordingAudioDriver().apply { granted = false }
        val audio = YlAudioFocusCoordinator(driver)
        val f = SessionFixture(StandardTestDispatcher(testScheduler), options = managed, audioFocus = { audio })
        f.coordinator.load(request("one").withAutoplay(true)); runCurrent()
        assertEquals(0, f.engines.single().playCalls)
        assertEquals(AndroidPlaybackStatus.FAILED, f.events.states.last().status)
        f.finish(); assertEquals(listOf("request"), driver.calls)
    }
    @Test fun `two managed players share focus and close of one does not release the other`() = runTest {
        val driver = RecordingAudioDriver(); val audio = YlAudioFocusCoordinator(driver)
        val a = SessionFixture(StandardTestDispatcher(testScheduler), options = managed, audioFocus = { audio })
        val b = SessionFixture(StandardTestDispatcher(testScheduler), playerId = 8, options = managed, audioFocus = { audio })
        a.coordinator.load(request("a").withAutoplay(true)); b.coordinator.load(request("b").withAutoplay(true)); runCurrent()
        assertEquals(listOf("request", "register"), driver.calls)
        a.finish(); assertEquals(2, driver.calls.size)
        b.coordinator.stop(); assertEquals(listOf("request", "register", "unregister", "abandon"), driver.calls)
        b.finish()
    }
    @Test fun `transient gain never overrides later explicit pause or stop`() = runTest {
        for (stop in listOf(false, true)) {
            val driver = RecordingAudioDriver(); val audio = YlAudioFocusCoordinator(driver)
            val f = SessionFixture(StandardTestDispatcher(testScheduler), options = managed, audioFocus = { audio })
            val id = f.coordinator.load(request("one").withAutoplay(true)).sessionId; runCurrent()
            val callback = assertNotNull(driver.listener)
            callback(YlAudioFocusChange.LOSS_TRANSIENT); runCurrent()
            assertFalse(f.engines.single().playing)
            callback(YlAudioFocusChange.GAIN)
            if (stop) f.coordinator.stop() else f.coordinator.pause(AndroidSessionCommand(id))
            runCurrent(); assertEquals(1, f.engines.single().playCalls)
            assertFalse(f.engines.single().playing); f.finish()
        }
    }
    @Test fun `focus resumes intended current player and duck composes latest volume`() = runTest {
        val driver = RecordingAudioDriver(); val audio = YlAudioFocusCoordinator(driver)
        val f = SessionFixture(StandardTestDispatcher(testScheduler), options = managed, audioFocus = { audio })
        f.coordinator.load(request("one").withAutoplay(true)); runCurrent()
        val callback = assertNotNull(driver.listener)
        callback(YlAudioFocusChange.DUCK); runCurrent()
        f.coordinator.setVolume(0.4); runCurrent()
        assertEquals(0.08, f.engines.single().currentVolume, 0.000001)
        callback(YlAudioFocusChange.GAIN); runCurrent()
        assertEquals(0.4, f.engines.single().currentVolume)
        callback(YlAudioFocusChange.LOSS_TRANSIENT); runCurrent()
        callback(YlAudioFocusChange.GAIN); runCurrent()
        assertTrue(f.engines.single().playing)
        assertEquals(2, f.engines.single().playCalls)
        f.finish()
    }
    @Test fun `background waits for quiesce and release acknowledgement then foreground reacquires`() = runTest {
        val driver = RecordingAudioDriver(); val audio = YlAudioFocusCoordinator(driver)
        val f = SessionFixture(StandardTestDispatcher(testScheduler), options = managed, audioFocus = { audio })
        f.coordinator.load(request("one").withAutoplay(true)); runCurrent()
        val engine = f.engines.single()
        engine.backgroundAcknowledgement = CompletableDeferred()
        f.coordinator.onBackground(); runCurrent()
        assertEquals(listOf("request", "register"), driver.calls)
        f.coordinator.onForeground(); runCurrent(); assertFalse(engine.playing)
        engine.backgroundAcknowledgement!!.complete(Unit); runCurrent()
        assertTrue(engine.playing)
        assertEquals(listOf("request", "register", "unregister", "abandon", "request", "register"), driver.calls)
        f.finish()
    }
    @Test fun `failed same player handoff preserves ownership and ducked latest volume on rollback`() = runTest {
        val driver = RecordingAudioDriver(); val audio = YlAudioFocusCoordinator(driver)
        val f = SessionFixture(StandardTestDispatcher(testScheduler), options = managed, audioFocus = { audio })
        f.coordinator.load(request("one").withAutoplay(true)); runCurrent()
        assertNotNull(driver.listener)(YlAudioFocusChange.DUCK); runCurrent()
        val candidate = FakeSessionEngine().apply { activationAcknowledgement = CompletableDeferred(); activationError = YlBoundaryException(YlFailureKind.DECODER_UNAVAILABLE) }
        f.next = candidate
        val load = async { runCatching { f.coordinator.load(request("two").withAutoplay(true)) } }; runCurrent()
        f.coordinator.setVolume(0.3)
        candidate.activationAcknowledgement!!.complete(Unit); runCurrent(); assertTrue(load.await().isFailure)
        assertEquals(listOf("request", "register"), driver.calls)
        assertEquals(0.06, f.engines.first().currentVolume, 0.000001)
        assertNotNull(driver.listener)(YlAudioFocusChange.GAIN); runCurrent()
        assertEquals(0.3, f.engines.first().currentVolume)
        f.finish()
    }
}
