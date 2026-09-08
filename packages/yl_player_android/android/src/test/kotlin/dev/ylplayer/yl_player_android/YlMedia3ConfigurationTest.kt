package dev.ylplayer.yl_player_android

import androidx.media3.common.AudioAttributes
import dev.ylplayer.yl_player_android.pigeon.*
import org.mockito.Mockito.*
import kotlin.test.*

class YlMedia3ConfigurationTest {
    @Test fun `shared transient pause keeps play intent and existing three second resource grace`() = withCore { core, player, _ ->
        core.play()
        core.pauseForAudioFocus()
        val lifecycle = core.javaClass.getDeclaredField("lifecycle").apply { isAccessible = true }.get(core) as YlLifecycleCoordinator
        assertTrue(lifecycle.state.playbackIntended)
        assertTrue(lifecycle.state.focusPaused)
        val handler = core.javaClass.getDeclaredField("handler").apply { isAccessible = true }.get(core) as android.os.Handler
        val runnable = org.mockito.ArgumentCaptor.forClass(Runnable::class.java)
        verify(handler).postDelayed(runnable.capture(), eq(3000L))
        runnable.value.run()
        assertTrue(lifecycle.state.resourcesReleased)
        verify(player).stop()
        assertTrue(core.snapshotRestorePoint().playbackIntended)
    }
    @Test fun `both actual ExoPlayer audio ownership flags are disabled for both policies`() {
        for (policy in AndroidAudioPolicy.entries) withCore(policy) { _, player, _ ->
            verify(player).setAudioAttributes(any(AudioAttributes::class.java), eq(false))
            verify(player).setHandleAudioBecomingNoisy(false)
        }
    }
}
