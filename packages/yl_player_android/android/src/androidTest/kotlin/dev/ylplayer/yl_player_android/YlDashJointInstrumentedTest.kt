package dev.ylplayer.yl_player_android

import android.content.Context
import android.os.Handler
import androidx.media3.common.*
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.ForwardingAudioSink
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.test.platform.app.InstrumentationRegistry
import okhttp3.mockwebserver.*
import okio.Buffer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Actual MediaCodec surface pixels paired with AudioTrack consumption. No microphone/display claim. */
class YlDashJointInstrumentedTest {
    @Test fun nativeJointBaseline() {
        for (name in listOf("manifest", "independent-pto", "clip-end", "cross-codec", "resolution"))
            for (run in 0 until 3) DashJointMeasurement.measure(name, run)
    }
}

class YlDashJointTimingControlTest {
    @Test fun timingControls() {
        for (run in 0 until 3) {
            DashJointMeasurement.measure("same-format-1500ms", run)
            DashJointMeasurement.measure("delayed-audio-init", run)
        }
    }
}

class YlDashPausedPreviewInstrumentedTest {
    @Test fun previewBeforePlay() = DashJointMeasurement.measure("paused-preview", 0)
}

class YlDashQueuedPauseInstrumentedTest {
    @Test fun crossCodec() {
        for (run in 0 until 3) DashJointMeasurement.measure("cross-codec", run)
    }
    @Test fun fullHdSurface() = DashJointMeasurement.measure("cross-codec", 0, fullHd = true)
    @Test fun pauseWithDecodedFramesQueued() = DashJointMeasurement.measure("cross-codec", 0, pauseDuringAvc = true)
}

private object DashJointMeasurement {
    private data class Frame(val ptsUs: Long, val formatId: String?, val periodStartUs: Long, val metadataNs: Long, val audioAtMetadataUs: Long?)
    fun measure(name: String, run: Int, pauseDuringAvc: Boolean = false, fullHd: Boolean = false) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val assets = instrumentation.context.assets
        val done = CountDownLatch(1)
        val preview = CountDownLatch(1)
        val beforeSwitch = CountDownLatch(1)
        var pauseAcknowledgedNs = 0L
        var resumedNs = 0L
        var failure: Throwable? = null
        var player: ExoPlayer? = null
        var sink: AudioSink? = null
        val trace = YlDashTimingTrace()
        var audioOffset = 0L
        var audioStart = 0L
        fun programmeClock(raw: Long?): Long? =
            raw?.takeUnless { it == AudioSink.CURRENT_POSITION_NOT_SET }?.let { it - audioOffset + audioStart }
        val frames = LinkedHashMap<Long, Frame>()
        val rows = mutableListOf<JSONObject>()
        val startedAt = android.os.SystemClock.elapsedRealtime()
        val periodBoundary = when (name) { "manifest" -> 4_000_000L; "cross-codec", "resolution", "same-format-1500ms" -> 1_500_000L; else -> Long.MAX_VALUE }
        var probe: YlDashSurfaceProbe? = null
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.path!!.substringBefore('?').removePrefix("/")
                if (path.contains("..")) return MockResponse().setResponseCode(404)
                val asset = when (path) {
                    "same-format-1500ms.mpd" -> "manifest.mpd"
                    "paused-preview.mpd", "delayed-audio-init.mpd" -> "independent-pto.mpd"
                    else -> path
                }
                var bytes = assets.open(asset).use { it.readBytes() }
                if (path == "same-format-1500ms.mpd") {
                    // Keep both AVC 320x180 streams and shorten each Period to match the switch fixtures.
                    bytes = String(bytes).replace("PT8S", "PT3S").replace("PT4S", "PT1.5S").toByteArray()
                }
                if (path.endsWith(".mpd")) {
                    // Test-only unique representation IDs identify exact Periods
                    // at the decoder callback; compressed media stays unchanged.
                    var index = 0
                    bytes = Regex("<Representation id=\"0\"").replace(String(bytes)) { "<Representation id=\"p${index++}-video\"" }.toByteArray()
                }
                trace.mark("fixtureResponsePrepared", "path" to path)
                return MockResponse().setBody(Buffer().write(bytes)).apply {
                    if (name == "delayed-audio-init" && path == "independent/init-1.m4s") {
                        setBodyDelay(160, TimeUnit.MILLISECONDS)
                    }
                }
            }
        }
        server.start()
        val item = MediaItem.fromUri(server.url("/$name.mpd").toString())
        try {
            instrumentation.runOnMainSync {
                val renderers = object : YlOutputRenderersFactory(context, YlVideoOutputObserver({ it() }) { _, _, _ -> }) {
                    override fun buildAudioSink(context: Context, enableFloatOutput: Boolean, enableAudioOutputPlaybackParams: Boolean): AudioSink {
                        val actual = object : ForwardingAudioSink(super.buildAudioSink(context, enableFloatOutput, enableAudioOutputPlaybackParams)!!) {
                            private var firstWrite = true
                            private var observedClock = false

                            override fun getCurrentPositionUs(sourceEnded: Boolean): Long {
                                val value = super.getCurrentPositionUs(sourceEnded)
                                if (!observedClock && value != AudioSink.CURRENT_POSITION_NOT_SET) {
                                    observedClock = true
                                    trace.mark("firstObservedClock", "positionUs" to programmeClock(value))
                                }
                                return value
                            }

                            override fun play() {
                                trace.mark("sinkPlay")
                                super.play()
                            }

                            override fun pause() {
                                trace.mark("sinkPause")
                                super.pause()
                            }

                            override fun handleBuffer(buffer: java.nio.ByteBuffer, pts: Long, count: Int): Boolean {
                                if (!firstWrite) return super.handleBuffer(buffer, pts, count)
                                firstWrite = false
                                trace.mark("firstWriteEnter", "clockUs" to programmeClock(getCurrentPositionUs(false)))
                                val accepted = super.handleBuffer(buffer, pts, count)
                                trace.mark("firstWriteReturn", "accepted" to accepted,
                                    "clockUs" to programmeClock(getCurrentPositionUs(false)))
                                return accepted
                            }

                            override fun configure(config: AudioSink.AudioSinkConfig) {
                                val metadata = config.format.metadata!!
                                audioStart = (0 until metadata.length()).map(metadata::get).filterIsInstance<YlDashPcmWindow>().single().start.units(1_000_000)
                                super.configure(config)
                                trace.mark("sinkConfigured", "periodStartUs" to audioStart)
                            }
                            override fun setOutputStreamOffsetUs(value: Long) { audioOffset = value; super.setOutputStreamOffsetUs(value) }
                        }
                        sink = actual
                        return YlDashPcmAudioSink(actual)
                    }
                }
                // Use the same decoder budget as a real DASH session on this device.
                val profile = YlAndroidDeviceProfile.collect(context)
                renderers.allowDashPrewarming = profile.tier != YlDeviceTier.CONSTRAINED
                renderers.dashDecoderSizing = YlDashDecoderSizing.forDevice(profile)
                val wantsPlayback = java.util.concurrent.atomic.AtomicBoolean()
                renderers.dashPlayWhenReady = wantsPlayback::get
                player = ExoPlayer.Builder(context, renderers).build().also { exo ->
                    exo.addAnalyticsListener(trace)
                    exo.addListener(object : Player.Listener {
                        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                            wantsPlayback.set(playWhenReady)
                        }
                        override fun onPlaybackStateChanged(state: Int) {
                            trace.mark("playerState", "state" to state)
                            if (state == Player.STATE_ENDED) done.countDown()
                        }
                        override fun onPlayerError(error: PlaybackException) { failure = error; done.countDown() }
                    })
                    exo.setVideoFrameMetadataListener { pts, release, format, _ ->
                        val start = if (format.id == "p1-video") periodBoundary else 0L
                        val metadataNs = System.nanoTime()
                        val atGraphSwitch = format.id == null && name == "cross-codec" && pts == periodBoundary
                        val clock = if (pts <= 125_000L || atGraphSwitch) programmeClock(sink?.getCurrentPositionUs(false)) else null
                        frames[release] = Frame(pts, format.id, start, metadataNs, clock)
                        while (frames.size > 64) frames.remove(frames.keys.first())
                    }
                    val output = YlDashSurfaceProbe(Handler(exo.playbackLooper), sampleAcrossOutput = fullHd)
                    probe = output
                    if (name == "cross-codec" && renderers.dashDecoderSizing != null) {
                        val width = if (fullHd) 1920 else 640
                        val height = if (fullHd) 1080 else 360
                        output.texture.setDefaultBufferSize(width, height)
                        YlVideoSurfaceSize.update(output.surface, width, height)
                    }
                    output.observe({ timestamp, rgb, gpuStartNs, gpuEndNs ->
                        val frame = frames.remove(timestamp)
                        // The Media3 graph reports a composed programme PTS and drops the
                        // input representation ID. The two fixture palettes independently
                        // identify the actual decoded Period when observing this path.
                        val graphOutput = name == "cross-codec" && frame != null && frame.formatId == null &&
                            renderers.dashDecoderSizing?.transitionOutputSize != null
                        val representation = if (graphOutput) when {
                            rgb[0] > 223 && rgb[1] > 223 && rgb[2] < 32 ||
                                rgb[0] < 32 && rgb[1] > 223 && rgb[2] > 223 -> "p1-video"
                            rgb[0] > 223 && rgb[1] < 32 && rgb[2] < 32 ||
                                rgb[0] < 32 && rgb[1] > 223 && rgb[2] < 32 -> "p0-video"
                            else -> error("Unexpected cross-codec pixel $rgb")
                        } else frame?.formatId
                        val consumed = sink?.getCurrentPositionUs(false)
                        val observedHost = System.nanoTime()
                        val audio = programmeClock(consumed)
                        val video = frame?.let { it.ptsUs + it.periodStartUs }
                        // The decoder can deliver pixels before the codec's requested
                        // release instant. Retain both the observed consumption and the
                        // rate-1 projection to that native presentation timestamp.
                        val projected = audio?.let { it + (timestamp - observedHost) / 1000 }
                        val row = JSONObject().put("imageTimestampNs", timestamp).put("observedHostNs", observedHost)
                            .put("videoPtsUs", video ?: JSONObject.NULL).put("representation", representation ?: JSONObject.NULL)
                            .put("identitySource", if (graphOutput) "fixturePixel" else "decoderMetadata")
                            .put("audioUs", audio ?: JSONObject.NULL).put("audioProjectedAtReleaseUs", projected ?: JSONObject.NULL).put("audioPeriodStartUs", audioStart)
                            .put("audioStreamOffsetUs", audioOffset).put("metadataHostNs", frame?.metadataNs ?: JSONObject.NULL)
                            .put("audioAtMetadataUs", frame?.audioAtMetadataUs ?: JSONObject.NULL)
                            .put("gpuStartNs", gpuStartNs).put("gpuEndNs", gpuEndNs)
                            .put("rgb", JSONArray(rgb))
                            .put("rawDeltaUs", if (audio != null && video != null) video - audio else JSONObject.NULL)
                            .put("deltaUs", if (projected != null && video != null) video - projected else JSONObject.NULL)
                        synchronized(rows) { rows += row }
                        if (frame?.ptsUs == 0L) preview.countDown()
                        if (pauseDuringAvc && video != null && video >= 700_000L) beforeSwitch.countDown()
                    }, { error -> failure = error; done.countDown() })
                    exo.setVideoSurface(output.surface)
                    exo.setMediaSource(YlDashProgramMediaSource(item, DefaultHttpDataSource.Factory(),
                        YlDashManifestParser(null), DefaultLoadErrorHandlingPolicy(0), YlDashGapGroups(), renderers.dashDecoderSizing))
                    exo.prepare()
                    if (name != "paused-preview") exo.play()
                }
            }
            if (pauseDuringAvc) {
                assertTrue("AVC playback did not reach pause point", beforeSwitch.await(8, TimeUnit.SECONDS))
                instrumentation.runOnMainSync { player!!.pause() }
                val barrier = java.util.concurrent.FutureTask { System.nanoTime() }
                check(Handler(player!!.playbackLooper).post(barrier))
                pauseAcknowledgedNs = barrier.get(2, TimeUnit.SECONDS)
                Thread.sleep(650)
                resumedNs = System.nanoTime()
                instrumentation.runOnMainSync { player!!.play() }
            }
            if (name == "paused-preview") {
                assertTrue("Paused startup did not produce a preview", preview.await(5, TimeUnit.SECONDS))
                instrumentation.runOnMainSync {
                    assertFalse(player!!.playWhenReady)
                    player!!.play()
                }
            }
            assertTrue("Native AV did not finish", done.await(25, TimeUnit.SECONDS))
            probe?.drain()
            assertNull("Native AV failure", failure)
            trace.log(name, run)
            val measured = synchronized(rows) { rows.toList() }
            val record = JSONObject().put("fixture", name).put("run", run)
                .put("elapsedMs", android.os.SystemClock.elapsedRealtime() - startedAt).put("rows", JSONArray(measured))
            // Log one bounded row per line to avoid Android logcat truncation.
            android.util.Log.i("P01_JOINT", JSONObject().put("fixture", name).put("run", run).put("elapsedMs", record.getLong("elapsedMs")).toString())
            for (row in measured) android.util.Log.i("P01_JOINT_ROW", row.put("fixture", name).put("run", run).toString())
            if (pauseDuringAvc) {
                // Allow the one already-presented 24 fps frame to reach the consumer.
                val advanced = measured.filter { it.getLong("gpuStartNs") in (pauseAcknowledgedNs + 42_000_000L) until resumedNs }
                android.util.Log.i("P01_JOINT_PAUSE", JSONObject().put("ackNs", pauseAcknowledgedNs)
                    .put("resumeNs", resumedNs).put("framesDuringHold", advanced.size).toString())
                assertTrue("Video advanced after pause acknowledgement: $advanced", advanced.isEmpty())
            }
            assertTrue("Actual surface frames absent: ${measured.size}", measured.size > 12)
            assertTrue("Image timestamps must match rendered frame metadata", measured.all { !it.isNull("videoPtsUs") })
            assertTrue("Native consumed clock absent", measured.count { !it.isNull("audioUs") } > 12)
            if (periodBoundary != Long.MAX_VALUE) assertTrue("Second Period actual output absent", measured.any { it.optLong("videoPtsUs") >= periodBoundary })
            if (name == "cross-codec" && measured.any { it.optString("identitySource") == "fixturePixel" }) {
                assertEquals(1_458_333L, measured.last { it.getString("representation") == "p0-video" }.getLong("videoPtsUs"))
                assertEquals(1_500_000L, measured.first { it.getString("representation") == "p1-video" }.getLong("videoPtsUs"))
            }
            for (row in measured) {
                val pts = row.getLong("videoPtsUs")
                val second = pts >= periodBoundary
                val local = pts - if (second) periodBoundary else 0
                val colors = if (second) listOf(listOf(255,255,0), listOf(0,255,255), listOf(255,0,255), listOf(0,0,0))
                    else listOf(listOf(255,0,0), listOf(0,255,0), listOf(0,0,255), listOf(255,255,255))
                val expected = colors[(local / 1_000_000).toInt().coerceIn(0, 3)]
                val rgb = row.getJSONArray("rgb")
                for (c in 0..2) assertTrue("$name actual pixel at $pts: $rgb expected $expected", kotlin.math.abs(rgb.getInt(c) - expected[c]) < 32)
            }
        } finally {
            try {
                instrumentation.runOnMainSync {
                    try {
                        player?.clearVideoSurface()
                        probe?.close()
                    } finally {
                        player?.release()
                    }
                }
            } finally {
                server.shutdown()
            }
        }
    }
}
