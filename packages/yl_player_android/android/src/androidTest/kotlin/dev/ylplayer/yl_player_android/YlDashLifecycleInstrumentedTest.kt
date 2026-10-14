package dev.ylplayer.yl_player_android

import android.os.Handler
import android.os.HandlerThread
import androidx.test.platform.app.InstrumentationRegistry
import dev.ylplayer.yl_player_android.pigeon.*
import okhttp3.mockwebserver.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/** Real core resource release/rebuild through the same callbacks used by app lifecycle. */
class YlDashLifecycleInstrumentedTest {
    @Test fun foregroundRebuildPreservesProgrammeAudioAndCrossPeriodProgress() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val assets = instrumentation.context.assets
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.path!!.substringBefore('?').removePrefix("/")
                if (path.contains("..")) return MockResponse().setResponseCode(404)
                return MockResponse().setBody(Buffer().write(assets.open(path).use { it.readBytes() }))
            }
        }
        server.start()
        val thread = HandlerThread("p01-lifecycle-probe").also { it.start() }
        val handler = Handler(thread.looper)
        fun <T> owned(action: () -> T): T {
            val result = CompletableFuture<T>()
            handler.post { try { result.complete(action()) } catch (error: Throwable) { result.completeExceptionally(error) } }
            return result.get(10, TimeUnit.SECONDS)
        }
        val events = mutableListOf<YlEngineEvent>()
        var latest = YlEngineSnapshot()
        var core: YlMedia3Core? = null
        try {
            owned {
                val source = AndroidSourceMessage(AndroidSourceKind.NETWORK, server.url("/cross-codec.mpd").toString(), AndroidStreamIntent.ON_DEMAND, AndroidMediaFormat.DASH,
                    networkPolicy = AndroidNetworkPolicyMessage(AndroidNetworkPolicyKind.MANAGED, 3000, 3000, 1, 100, 100, 2))
                val options = AndroidLoadOptionsMessage(false, bufferStrategy = AndroidBufferStrategyMessage(AndroidBufferKind.AUTOMATIC), videoConstraints = AndroidVideoConstraintsMessage())
                val playerOptions = AndroidPlayerOptionsMessage(AndroidDecoderPolicy.SYSTEM_DEFAULT, AndroidAudioPolicy.APP_MANAGED, 100)
                core = YlMedia3Core(context, YlSessionIdentity("p01-lifecycle", "load"), source, options,
                    createMedia3Configuration(source, options, playerOptions), handler,
                    YlEngineVideoOutput(YlCandidateVideoOutput(context)), { event ->
                        events += event
                        when (event) {
                            is YlEngineEvent.Snapshot -> latest = event.value
                            is YlEngineEvent.Tick -> latest = latest.copy(timeline = event.timeline, metrics = event.metrics)
                            else -> Unit
                        }
                    })
                core!!.initialize(); core!!.prepare(); core!!.initializeDecoder()
            }
            fun awaitState(predicate: (YlEngineSnapshot) -> Boolean): YlEngineSnapshot {
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
                while (System.nanoTime() < deadline) {
                    val value = owned {
                        assertTrue(events.filterIsInstance<YlEngineEvent.Failed>().toString(), events.none { it is YlEngineEvent.Failed })
                        latest
                    }
                    if (value != null && predicate(value)) return value
                    Thread.sleep(20)
                }
                throw AssertionError("Programme lifecycle state timed out: ${owned { latest }}; last events=${owned { events.takeLast(5) }}")
            }
            val ready = awaitState { it.audioTracks.isNotEmpty() }
            val audio = ready.audioTracks.single().id
            owned { core!!.selectAudioTrack(audio); core!!.seekTo(700); core!!.play() }
            awaitState { it.timeline.positionMs >= 800 }
            val held = owned { core!!.releaseForLifecycle(); core!!.snapshotRestorePoint() }
            Thread.sleep(150)
            val paused = owned { core!!.snapshotRestorePoint() }
            assertEquals(held.positionMs, paused.positionMs)
            assertEquals(audio, paused.selectedAudioTrack)
            owned { core!!.restoreAfterForeground() }
            val resumed = awaitState { it.timeline.positionMs >= 1800 && it.geometry?.encodedSize?.width == 640.0 }
            assertEquals(audio, owned { core!!.snapshotRestorePoint().selectedAudioTrack })
            assertTrue(resumed.audioTracks.any { it.id == audio && it.isSelected })
            owned { core!!.stop(); core!!.releaseForLifecycle(); core!!.restoreAfterForeground() }
            val stopped = owned { core!!.snapshotRestorePoint() }
            assertFalse(stopped.playbackIntended)
            owned { core!!.dispose(); core!!.dispose() }
            android.util.Log.i("P01_LIFECYCLE", "heldMs=${held.positionMs} resumedMs=${resumed.timeline.positionMs} audioPreserved=true disposedTwice=true")
        } finally {
            owned { core?.dispose() }
            thread.quitSafely(); thread.join(2000); server.shutdown()
        }
    }
}
