package dev.ylplayer.yl_player_android

import kotlin.test.*

class YlAudioFocusCoordinatorTest {
    @Test fun `framework cleanup failure cannot throw across irrevocable session handoff and still abandons owned focus`() {
        val calls = mutableListOf<String>(); val failures = mutableListOf<Throwable>()
        val driver = object : YlAudioFocusDriver {
            override fun request(listener: (YlAudioFocusChange) -> Unit) = true
            override fun registerNoisy(listener: () -> Unit) = Unit
            override fun unregisterNoisy() { calls += "unregister"; throw IllegalStateException() }
            override fun abandon() { calls += "abandon" }
        }
        val coordinator = YlAudioFocusCoordinator(driver, failures::add)
        val participant = YlAudioFocusParticipant { }
        assertTrue(coordinator.acquire(participant))
        coordinator.release(participant)
        assertEquals(listOf("unregister", "abandon"), calls)
        assertEquals(1, failures.size)
        coordinator.release(participant)
        assertEquals(2, calls.size)
    }
    @Test fun `transient loss does not authorize new or repeated play until actual gain`() {
        val driver = RecordingAudioDriver(); val coordinator = YlAudioFocusCoordinator(driver)
        val first = YlAudioFocusParticipant { }; val second = YlAudioFocusParticipant { }
        assertTrue(coordinator.acquire(first))
        driver.listener!!(YlAudioFocusChange.LOSS_TRANSIENT)
        assertFalse(coordinator.acquire(first)); assertFalse(coordinator.acquire(second))
        assertEquals(listOf("request", "register"), driver.calls)
        driver.listener!!(YlAudioFocusChange.GAIN)
        assertTrue(coordinator.acquire(second))
        coordinator.release(first); coordinator.release(second)
    }
    @Test fun `first play acquires once and final participant alone releases focus and noisy`() {
        val driver = RecordingAudioDriver()
        val coordinator = YlAudioFocusCoordinator(driver)
        val first = YlAudioFocusParticipant { }
        val second = YlAudioFocusParticipant { }
        assertTrue(coordinator.acquire(first))
        assertTrue(coordinator.acquire(first))
        assertTrue(coordinator.acquire(second))
        assertEquals(listOf("request", "register"), driver.calls)
        coordinator.release(first)
        coordinator.release(first)
        assertEquals(listOf("request", "register"), driver.calls)
        coordinator.release(second)
        assertEquals(listOf("request", "register", "unregister", "abandon"), driver.calls)
    }
    @Test fun `denied acquisition never owns focus or receiver and a later play can retry`() {
        val driver = RecordingAudioDriver().apply { granted = false }
        val coordinator = YlAudioFocusCoordinator(driver)
        val participant = YlAudioFocusParticipant { }
        assertFalse(coordinator.acquire(participant))
        coordinator.release(participant)
        assertEquals(listOf("request"), driver.calls)
        driver.granted = true
        assertTrue(coordinator.acquire(participant))
        coordinator.release(participant)
        assertEquals(listOf("request", "request", "register", "unregister", "abandon"), driver.calls)
    }
    @Test fun `focus and noisy reach all current participants and stale released listener is ignored`() {
        val driver = RecordingAudioDriver()
        val coordinator = YlAudioFocusCoordinator(driver)
        val first = mutableListOf<YlAudioFocusChange>()
        val second = mutableListOf<YlAudioFocusChange>()
        val a = YlAudioFocusParticipant(first::add)
        val b = YlAudioFocusParticipant(second::add)
        assertTrue(coordinator.acquire(a)); assertTrue(coordinator.acquire(b))
        val stale = driver.listener!!
        stale(YlAudioFocusChange.DUCK)
        stale(YlAudioFocusChange.LOSS_TRANSIENT)
        stale(YlAudioFocusChange.GAIN)
        driver.noisy!!()
        assertEquals(listOf(YlAudioFocusChange.DUCK, YlAudioFocusChange.LOSS_TRANSIENT, YlAudioFocusChange.GAIN, YlAudioFocusChange.NOISY), first)
        assertEquals(first, second)
        coordinator.release(a); coordinator.release(b)
        stale(YlAudioFocusChange.GAIN)
        assertEquals(4, first.size)
    }
}
internal class RecordingAudioDriver : YlAudioFocusDriver {
    var granted = true
    val calls = mutableListOf<String>()
    var listener: ((YlAudioFocusChange) -> Unit)? = null
    var noisy: (() -> Unit)? = null
    override fun request(listener: (YlAudioFocusChange) -> Unit): Boolean { calls += "request"; this.listener = listener; return granted }
    override fun abandon() { calls += "abandon" }
    override fun registerNoisy(listener: () -> Unit) { calls += "register"; noisy = listener }
    override fun unregisterNoisy() { calls += "unregister" }
}
