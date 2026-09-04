package dev.ylplayer.yl_player_android

internal enum class YlLifecycleEvent {
    SURFACE_LOST_FOREGROUND,
    RUNNING_LOW,
    RUNNING_CRITICAL,
    UI_HIDDEN,
    FOREGROUND,
    FOCUS_TRANSIENT_LOSS,
    FOCUS_GAIN,
    FOCUS_GRACE_EXPIRED,
    USER_PLAY,
    USER_PAUSE,
    DISPOSE,
}

internal enum class YlLifecycleAction {
    NONE,
    KEEP_PLAYER_DETACH_VIDEO,
    SHRINK_BUFFERS,
    PAUSE_KEEP_RESOURCES,
    RELEASE_AND_SAVE,
    REBUILD_IF_INTENDED,
    RESUME,
    DISPOSE,
}

internal data class YlLifecycleState(
    val playbackIntended: Boolean = false,
    val focusPaused: Boolean = false,
    val resourcesReleased: Boolean = false,
    val disposed: Boolean = false,
)

internal class YlLifecycleCoordinator {
    var state = YlLifecycleState()
        private set

    fun reduce(event: YlLifecycleEvent): YlLifecycleAction {
        if (state.disposed) return YlLifecycleAction.NONE
        return when (event) {
            YlLifecycleEvent.SURFACE_LOST_FOREGROUND ->
                YlLifecycleAction.KEEP_PLAYER_DETACH_VIDEO
            YlLifecycleEvent.RUNNING_LOW -> YlLifecycleAction.SHRINK_BUFFERS
            YlLifecycleEvent.RUNNING_CRITICAL,
            YlLifecycleEvent.UI_HIDDEN,
            -> releaseOnce()
            YlLifecycleEvent.FOREGROUND -> rebuildIfIntended()
            YlLifecycleEvent.FOCUS_TRANSIENT_LOSS -> pauseForFocus()
            YlLifecycleEvent.FOCUS_GAIN -> regainFocus()
            YlLifecycleEvent.FOCUS_GRACE_EXPIRED -> {
                if (state.focusPaused) releaseOnce() else YlLifecycleAction.NONE
            }
            YlLifecycleEvent.USER_PLAY -> {
                state = state.copy(playbackIntended = true, focusPaused = false)
                rebuildIfIntended()
            }
            YlLifecycleEvent.USER_PAUSE -> {
                state = state.copy(playbackIntended = false, focusPaused = false)
                YlLifecycleAction.NONE
            }
            YlLifecycleEvent.DISPOSE -> {
                state = state.copy(disposed = true, resourcesReleased = true)
                YlLifecycleAction.DISPOSE
            }
        }
    }

    private fun pauseForFocus(): YlLifecycleAction {
        if (!state.playbackIntended || state.resourcesReleased) return YlLifecycleAction.NONE
        state = state.copy(focusPaused = true)
        return YlLifecycleAction.PAUSE_KEEP_RESOURCES
    }

    private fun regainFocus(): YlLifecycleAction {
        if (!state.focusPaused || !state.playbackIntended) return YlLifecycleAction.NONE
        state = state.copy(focusPaused = false)
        if (state.resourcesReleased) {
            state = state.copy(resourcesReleased = false)
            return YlLifecycleAction.REBUILD_IF_INTENDED
        }
        return YlLifecycleAction.RESUME
    }

    private fun releaseOnce(): YlLifecycleAction {
        if (state.resourcesReleased) return YlLifecycleAction.NONE
        state = state.copy(resourcesReleased = true)
        return YlLifecycleAction.RELEASE_AND_SAVE
    }

    private fun rebuildIfIntended(): YlLifecycleAction {
        if (!state.resourcesReleased) return YlLifecycleAction.NONE
        state = state.copy(resourcesReleased = false)
        return YlLifecycleAction.REBUILD_IF_INTENDED
    }
}

internal class YlSurfaceGeneration {
    var generation: Long = 0
        private set
    var rebuildCount: Int = 0
        private set
    private var disposed = false

    fun rebuild(): Long {
        if (disposed) return generation
        generation += 1
        rebuildCount += 1
        return generation
    }

    fun invalidate(): Long {
        if (!disposed) generation += 1
        return generation
    }

    fun canAttach(
        expectedSurfaceGeneration: Long,
        expectedSourceGeneration: Long,
        currentSourceGeneration: Long,
    ): Boolean = !disposed &&
        expectedSurfaceGeneration == generation &&
        expectedSourceGeneration == currentSourceGeneration

    fun dispose(): Boolean {
        if (disposed) return false
        disposed = true
        generation += 1
        return true
    }
}
