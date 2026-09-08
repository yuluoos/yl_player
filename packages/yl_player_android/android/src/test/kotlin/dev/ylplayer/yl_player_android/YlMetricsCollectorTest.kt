package dev.ylplayer.yl_player_android

import android.content.Context
import android.os.Handler
import android.os.Process
import androidx.media3.common.*
import androidx.media3.exoplayer.*
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import dev.ylplayer.yl_player_android.pigeon.*
import org.mockito.Mockito.*
import kotlin.test.*

class YlMetricsCollectorTest {
    @Test fun `public texture resizes to renderer dimensions without coded rotation or PAR`() {
        val texture = mock(io.flutter.view.TextureRegistry.SurfaceTextureEntry::class.java)
        val surface = mock(android.graphics.SurfaceTexture::class.java)
        `when`(texture.surfaceTexture()).thenReturn(surface)
        val output = YlVideoOutput(texture, ownsTexture = false)
        output.updateGeometry(AndroidVideoGeometryMessage(AndroidSizeMessage(1920.0, 1080.0), AndroidSizeMessage(1080.0, 1920.0), 2.0, 0))
        verify(surface).setDefaultBufferSize(1080, 1920)
        output.release()
    }
    @Test fun `timestamped observations exclude initial buffering and preserve immutable snapshots`() {
        val metrics = YlMetricsCollector()
        assertEquals(AndroidMetricsMessage(), metrics.snapshot(100))
        metrics.start(100, true)
        metrics.buffering(110)
        metrics.ready(150)
        metrics.firstFrame(180)
        val ready = metrics.snapshot(180)
        assertEquals(50L, ready.loadToReadyMs); assertEquals(80L, ready.loadToFirstFrameMs)
        assertEquals(0L, ready.rebufferCount); assertEquals(0L, ready.rebufferDurationMs)
        assertEquals(0L, ready.reconnectCount)
        assertNull(ready.droppedVideoFrames); assertNull(ready.audioUnderruns)
        metrics.buffering(200); metrics.buffering(220)
        assertEquals(1L, metrics.snapshot(250).rebufferCount)
        assertEquals(50L, metrics.snapshot(250).rebufferDurationMs)
        metrics.endBuffering(270)
        metrics.ready(500)
        assertEquals(70L, metrics.snapshot(600).rebufferDurationMs)
        assertEquals(0L, ready.rebufferCount)
        assertEquals(50L, metrics.snapshot(600).loadToReadyMs)
    }
    @Test fun `measured zero counters and bandwidth remain distinct from unknown and allocator bytes`() {
        val metrics = YlMetricsCollector()
        metrics.videoEnabled(); metrics.audioEnabled(); metrics.bandwidth(0)
        val zero = metrics.snapshot(1, 0)
        assertEquals(0L, zero.droppedVideoFrames); assertEquals(0L, zero.audioUnderruns)
        assertEquals(0L, zero.estimatedBitrate); assertEquals(0L, zero.managedBufferedDurationMs)
        assertNull(zero.managedBufferedBytes)
        metrics.dropped(3); metrics.underrun(); metrics.retry(); metrics.retry()
        val observed = metrics.snapshot(2, 250, 120)
        assertEquals(3L, observed.droppedVideoFrames); assertEquals(1L, observed.audioUnderruns)
        assertEquals(2L, observed.reconnectCount); assertEquals(120L, observed.liveOffsetMs)
        assertEquals(0L, zero.droppedVideoFrames)
    }
    @Test fun `real analytics callbacks map bandwidth and observed counters while selected bitrate stays on track`() = withCore { core, player, events ->
        val item = MediaItem.Builder().setMediaId("test").build()
        `when`(player.currentMediaItem).thenReturn(item)
        val timeline = mock(Timeline::class.java)
        `when`(timeline.isEmpty).thenReturn(true)
        val event = androidx.media3.exoplayer.analytics.AnalyticsListener.EventTime(0, timeline, 0, null, 0, timeline, 0, null, 0, 0)
        val format = Format.Builder().setId("video").setSampleMimeType("video/avc").setAverageBitrate(900000).setWidth(1920).setHeight(1080).build()
        val tracks = Tracks(listOf(Tracks.Group(TrackGroup("video", format), false, intArrayOf(C.FORMAT_HANDLED), booleanArrayOf(true))))
        core.onTracksChanged(event, tracks)
        core.onVideoEnabled(event, DecoderCounters())
        core.onAudioEnabled(event, DecoderCounters())
        core.onBandwidthEstimate(event, 100, 10000, 800000)
        core.onDroppedVideoFrames(event, 2, 100)
        core.onAudioUnderrun(event, 1000, 10, 10)
        core.emitState()
        val snapshot = events.lastSnapshot()
        assertEquals(900000L, snapshot.videoTracks.single { it.isSelected }.bitrate)
        assertEquals(800000L, snapshot.metrics.estimatedBitrate)
        assertEquals(2L, snapshot.metrics.droppedVideoFrames); assertEquals(1L, snapshot.metrics.audioUnderruns)
        assertNull(snapshot.metrics.managedBufferedBytes)
    }
    @Test fun `periodic metrics delta does not repeat static video geometry`() {
        val reducer = YlStateReducer(clockMs = { 100 })
        val events = SessionEvents(); reducer.attach(events)
        reducer.commit(YlSessionIdentity("session", "load"), YlOutputIdentity(1, true))
        val geometry = AndroidVideoGeometryMessage(AndroidSizeMessage(1920.0, 1080.0), AndroidSizeMessage(1080.0, 1920.0), 2.0, 0)
        reducer.snapshot(YlEngineSnapshot(status = AndroidPlaybackStatus.READY, geometry = geometry))
        val count = events.states.size
        reducer.tick(emptyTimeline().copy(positionMs = 50), AndroidMetricsMessage(estimatedBitrate = 100))
        assertEquals(count, events.states.size)
        assertEquals(1, events.deltas.size)
        assertEquals(geometry, reducer.state.geometry)
        assertEquals(100L, events.deltas.single().metrics?.estimatedBitrate)
    }
    @Test fun `real core fresh metrics do not claim unobserved zero or managed allocator bytes`() = withCore { core, _, events ->
        core.emitState()
        assertEquals(AndroidMetricsMessage(), events.lastSnapshot().metrics)
    }
    @Test fun `real core keeps PAR out of rendered dimensions and uses coded format dimensions`() = withCore { core, player, events ->
        val format = Format.Builder().setWidth(1920).setHeight(1080).setRotationDegrees(90).build()
        `when`(player.videoFormat).thenReturn(format)
        core.field("lastVideoSize", VideoSize(1080, 1920, 2f))
        core.emitState()
        val geometry = assertNotNull(events.lastSnapshot().geometry)
        assertEquals(AndroidSizeMessage(1920.0, 1080.0), geometry.encodedSize)
        assertEquals(AndroidSizeMessage(1080.0, 1920.0), geometry.displaySize)
        assertEquals(2.0, geometry.pixelAspectRatio)
        assertEquals(0L, geometry.rotationDegrees)
    }
    @Test fun `selected representation bitrate is not a bandwidth estimate`() = withCore { core, _, events ->
        core.field("selectedVideoBitrate", 900000)
        core.emitState()
        assertNull(events.lastSnapshot().metrics.estimatedBitrate)
    }
}

internal fun MutableList<YlEngineEvent>.lastSnapshot() = filterIsInstance<YlEngineEvent.Snapshot>().last().value
internal fun YlMedia3Core.field(name: String, value: Any?) {
    javaClass.getDeclaredField(name).apply { isAccessible = true }.set(this, value)
}
internal fun withCore(policy: AndroidAudioPolicy = AndroidAudioPolicy.APP_MANAGED,
    action: (YlMedia3Core, ExoPlayer, MutableList<YlEngineEvent>) -> Unit) {
    val player = mock(ExoPlayer::class.java)
    `when`(player.duration).thenReturn(C.TIME_UNSET)
    `when`(player.currentLiveOffset).thenReturn(C.TIME_UNSET)
    val events = mutableListOf<YlEngineEvent>()
    val scoped = mutableListOf<AutoCloseable>()
    try {
        scoped += mockStatic(androidx.media3.common.util.Util::class.java) { invocation ->
            if (invocation.method.name == "isRunningOnEmulator") false else invocation.callRealMethod()
        }
        scoped += mockStatic(android.os.SystemClock::class.java)
        scoped += mockStatic(android.text.TextUtils::class.java) { invocation ->
            if (invocation.method.name == "isEmpty") (invocation.arguments[0] as? CharSequence).isNullOrEmpty() else invocation.callRealMethod()
        }
        scoped += mockStatic(Process::class.java)
        scoped += mockConstruction(DefaultTrackSelector::class.java, withSettings().defaultAnswer(RETURNS_DEEP_STUBS))
        scoped += mockConstruction(DefaultRenderersFactory::class.java, withSettings().defaultAnswer(RETURNS_SELF))
        scoped += mockConstruction(ExoPlayer.Builder::class.java, withSettings().defaultAnswer(RETURNS_SELF)) { builder, _ ->
            `when`(builder.build()).thenReturn(player)
        }
        val privateOutput = object : YlPrivateVideoOutput {
            override val identity = YlOutputIdentity(0, false)
            override val surface = mock(android.view.Surface::class.java)
            override fun releaseAfterAcknowledgedDetach() = Unit
        }
        val core = YlMedia3Core(mock(Context::class.java), YlSessionIdentity("test", "load"), source(), request("load").options,
            createMedia3Configuration(source(), request("load").options, sessionOptions.copy(audioPolicy = policy)),
            mock(Handler::class.java), YlEngineVideoOutput(privateOutput), events::add)
        core.initialize()
        action(core, player, events)
    } finally {
        scoped.asReversed().forEach { it.close() }
    }
}
