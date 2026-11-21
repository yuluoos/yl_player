package dev.ylplayer.yl_player_android

import android.os.Handler
import androidx.test.platform.app.InstrumentationRegistry
import dev.ylplayer.yl_player_android.pigeon.*
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test

/** Force the legacy switch on the device's real HEVC decoder without changing decoder selection. */
class YlLegacyHevcSurfaceInstrumentedTest {
    @Test fun seekableReplacementWhilePausedResumesAtTheSamePosition() = checkReplacement(replay = true)
    @Test fun forwardOnlyReplacementWhilePlayingWaitsForNextKeyFrame() = checkReplacement(replay = false)

    private fun checkReplacement(replay: Boolean) = runBlocking<Unit> {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val file = File.createTempFile("surface-restart", ".mov", context.cacheDir)
        instrumentation.context.assets.open("format_matrix/mov-hevc-aac.mov").use { input ->
            file.outputStream().use(input::copyTo)
        }
        val probe = YlDashSurfaceProbe(Handler(context.mainLooper))
        val output = YlVideoOutput(object : TextureRegistry.SurfaceTextureEntry {
            override fun id() = 905L
            override fun surfaceTexture() = probe.texture
            override fun release() = Unit // Probe owns the texture and its EGL context.
        })
        val pixels = AtomicInteger()
        val pts = AtomicLong(-1)
        val failure = AtomicReference<Throwable?>()
        val seekTarget = AtomicLong(-1)
        val switches = AtomicInteger()
        val decoderName = AtomicReference<String>()
        val pausedMs = AtomicLong(-1)
        val engine = YlNativeFallbackEngine(context, YlSessionIdentity("hevc", "surface-restart"),
            AndroidSourceMessage(AndroidSourceKind.FILE, file.absolutePath, AndroidStreamIntent.ON_DEMAND,
                AndroidMediaFormat.AUTOMATIC),
            AndroidLoadOptionsMessage(false, bufferStrategy = AndroidBufferStrategyMessage(AndroidBufferKind.AUTOMATIC),
                videoConstraints = AndroidVideoConstraintsMessage()),
            AndroidPlayerOptionsMessage(AndroidDecoderPolicy.HARDWARE_PREFERRED, AndroidAudioPolicy.APP_MANAGED, 100),
            dispatcher = Dispatchers.Unconfined, observeVideo = pts::set,
            requiresSurfaceRestart = { name -> decoderName.set(name); switches.incrementAndGet(); true },
            seekNative = { native, target ->
                seekTarget.set(target)
                replay && native.seekTo(target)
            })
        probe.observe({ _, _, _, _ -> pixels.incrementAndGet() }, failure::set)
        engine.registerCallback { _, event ->
            if (event is YlEngineEvent.Failed) failure.set(AssertionError(event.kind.toString(), event.cause))
            if (event is YlEngineEvent.Snapshot && event.value.status == AndroidPlaybackStatus.PAUSED) {
                pausedMs.set(event.value.timeline.positionMs)
            }
        }
        suspend fun awaitState(condition: () -> Boolean) = withTimeout(8000) {
            while (!condition()) { failure.get()?.let { throw it }; delay(10) }
        }
        try {
            engine.prepare()
            engine.activate(output)
            engine.play()
            awaitState { pixels.get() > 0 && pts.get() >= 200_000 }
            if (replay) engine.pause()
            engine.onConfigurationChanged()
            assertEquals(1, switches.get())
            assertEquals(1, output.surfaceRebuildCount)
            val target = seekTarget.get()
            assertTrue("replacement did not capture playback position", target > 0)
            probe.drain()
            val oldPixels = pixels.get()
            if (replay) {
                assertEquals(pausedMs.get(), target / 1000)
                delay(100)
                assertEquals(oldPixels, pixels.get())
                engine.play()
            }
            val previousPts = pts.get()
            awaitState { pixels.get() > oldPixels && pts.get() > previousPts && pts.get() >= target }
            failure.get()?.let { throw it }
            android.util.Log.i("YL_HEVC_SURFACE", "decoder=${decoderName.get()} replay=$replay targetUs=$target resumedPtsUs=${pts.get()}")
        } finally {
            try { engine.dispose().await() } finally {
                output.release()
                probe.close()
                file.delete()
            }
        }
    }
}
