package dev.ylplayer.yl_player_android

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class YlLifecyclePolicyTest {
    @Test
    fun `surface and memory events map to bounded actions`() {
        val coordinator = YlLifecycleCoordinator()

        assertEquals(
            YlLifecycleAction.KEEP_PLAYER_DETACH_VIDEO,
            coordinator.reduce(YlLifecycleEvent.SURFACE_LOST_FOREGROUND),
        )
        assertEquals(
            YlLifecycleAction.SHRINK_BUFFERS,
            coordinator.reduce(YlLifecycleEvent.RUNNING_LOW),
        )
        assertEquals(
            YlLifecycleAction.RELEASE_AND_SAVE,
            coordinator.reduce(YlLifecycleEvent.RUNNING_CRITICAL),
        )
    }

    @Test
    fun `background release is idempotent`() {
        val coordinator = YlLifecycleCoordinator()
        coordinator.reduce(YlLifecycleEvent.USER_PLAY)

        assertEquals(
            YlLifecycleAction.RELEASE_AND_SAVE,
            coordinator.reduce(YlLifecycleEvent.UI_HIDDEN),
        )
        assertEquals(
            YlLifecycleAction.NONE,
            coordinator.reduce(YlLifecycleEvent.UI_HIDDEN),
        )
        assertEquals(
            YlLifecycleAction.REBUILD_IF_INTENDED,
            coordinator.reduce(YlLifecycleEvent.FOREGROUND),
        )
    }

    @Test
    fun `foreground rebuilds a paused source without starting playback`() {
        val coordinator = YlLifecycleCoordinator()
        coordinator.reduce(YlLifecycleEvent.UI_HIDDEN)

        assertEquals(
            YlLifecycleAction.REBUILD_IF_INTENDED,
            coordinator.reduce(YlLifecycleEvent.FOREGROUND),
        )
        assertFalse(coordinator.state.playbackIntended)
        assertFalse(coordinator.state.resourcesReleased)
    }

    @Test
    fun `explicit pause is never undone by focus gain`() {
        val coordinator = YlLifecycleCoordinator()
        coordinator.reduce(YlLifecycleEvent.USER_PLAY)
        coordinator.reduce(YlLifecycleEvent.FOCUS_TRANSIENT_LOSS)
        coordinator.reduce(YlLifecycleEvent.USER_PAUSE)

        assertEquals(YlLifecycleAction.NONE, coordinator.reduce(YlLifecycleEvent.FOCUS_GAIN))
        assertFalse(coordinator.state.playbackIntended)
    }

    @Test
    fun `focus gain inside grace resumes only focus-paused playback`() {
        val coordinator = YlLifecycleCoordinator()
        coordinator.reduce(YlLifecycleEvent.USER_PLAY)

        assertEquals(
            YlLifecycleAction.PAUSE_KEEP_RESOURCES,
            coordinator.reduce(YlLifecycleEvent.FOCUS_TRANSIENT_LOSS),
        )
        assertEquals(
            YlLifecycleAction.RESUME,
            coordinator.reduce(YlLifecycleEvent.FOCUS_GAIN),
        )
        assertTrue(coordinator.state.playbackIntended)
        assertFalse(coordinator.state.focusPaused)
    }

    @Test
    fun `focus grace expiry releases and later gain rebuilds`() {
        val coordinator = YlLifecycleCoordinator()
        coordinator.reduce(YlLifecycleEvent.USER_PLAY)
        coordinator.reduce(YlLifecycleEvent.FOCUS_TRANSIENT_LOSS)

        assertEquals(
            YlLifecycleAction.RELEASE_AND_SAVE,
            coordinator.reduce(YlLifecycleEvent.FOCUS_GRACE_EXPIRED),
        )
        assertEquals(
            YlLifecycleAction.REBUILD_IF_INTENDED,
            coordinator.reduce(YlLifecycleEvent.FOCUS_GAIN),
        )
    }

    @Test
    fun `dispose is emitted exactly once`() {
        val coordinator = YlLifecycleCoordinator()

        assertEquals(YlLifecycleAction.DISPOSE, coordinator.reduce(YlLifecycleEvent.DISPOSE))
        assertEquals(YlLifecycleAction.NONE, coordinator.reduce(YlLifecycleEvent.DISPOSE))
    }

    @Test
    fun `surface generation rejects stale source and surface callbacks`() {
        val tracker = YlSurfaceGeneration()
        val first = tracker.rebuild()
        val second = tracker.rebuild()

        assertFalse(tracker.canAttach(first, expectedSourceGeneration = 4, currentSourceGeneration = 4))
        assertFalse(tracker.canAttach(second, expectedSourceGeneration = 3, currentSourceGeneration = 4))
        assertTrue(tracker.canAttach(second, expectedSourceGeneration = 4, currentSourceGeneration = 4))
        assertEquals(2, tracker.rebuildCount)
        val invalidated = tracker.invalidate()
        assertFalse(tracker.canAttach(second, expectedSourceGeneration = 4, currentSourceGeneration = 4))
        assertEquals(second + 1, invalidated)
        assertTrue(tracker.dispose())
        assertFalse(tracker.dispose())
    }
}
