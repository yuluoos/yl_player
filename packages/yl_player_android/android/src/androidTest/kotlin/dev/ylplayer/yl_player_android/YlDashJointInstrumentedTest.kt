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
            for (run in 0 until 3) measure(name, run)
    }
    private data class Frame(val ptsUs: Long, val formatId: String?, val periodStartUs: Long)
    private fun measure(name: String, run: Int) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val assets = instrumentation.context.assets
        val done = CountDownLatch(1)
        var failure: Throwable? = null
        var player: ExoPlayer? = null
        var sink: AudioSink? = null
        var audioOffset = 0L
        var audioStart = 0L
        val frames = LinkedHashMap<Long, Frame>()
        val rows = mutableListOf<JSONObject>()
        val startedAt = android.os.SystemClock.elapsedRealtime()
        val periodBoundary = when (name) { "manifest" -> 4_000_000L; "cross-codec", "resolution" -> 1_500_000L; else -> Long.MAX_VALUE }
        var probe: YlDashSurfaceProbe? = null
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.path!!.substringBefore('?').removePrefix("/")
                if (path.contains("..")) return MockResponse().setResponseCode(404)
                var bytes = assets.open(path).use { it.readBytes() }
                if (path.endsWith(".mpd")) {
                    // Test-only unique representation IDs identify exact Periods
                    // at the decoder callback; compressed media stays unchanged.
                    var index = 0
                    bytes = Regex("<Representation id=\"0\"").replace(String(bytes)) { "<Representation id=\"p${index++}-video\"" }.toByteArray()
                }
                return MockResponse().setBody(Buffer().write(bytes))
            }
        }
        server.start()
        val item = MediaItem.fromUri(server.url("/$name.mpd").toString())
        try {
            instrumentation.runOnMainSync {
                val renderers = object : YlOutputRenderersFactory(context, YlVideoOutputObserver({ it() }) { _, _, _ -> }) {
                    override fun buildAudioSink(context: Context, enableFloatOutput: Boolean, enableAudioOutputPlaybackParams: Boolean): AudioSink {
                        val actual = object : ForwardingAudioSink(super.buildAudioSink(context, enableFloatOutput, enableAudioOutputPlaybackParams)!!) {
                            override fun configure(config: AudioSink.AudioSinkConfig) {
                                val metadata = config.format.metadata!!
                                audioStart = (0 until metadata.length()).map(metadata::get).filterIsInstance<YlDashPcmWindow>().single().start.units(1_000_000)
                                super.configure(config)
                            }
                            override fun setOutputStreamOffsetUs(value: Long) { audioOffset = value; super.setOutputStreamOffsetUs(value) }
                        }
                        sink = actual
                        return YlDashPcmAudioSink(actual)
                    }
                }
                player = ExoPlayer.Builder(context, renderers).build().also { exo ->
                    exo.addListener(object : Player.Listener {
                        override fun onPlaybackStateChanged(state: Int) { if (state == Player.STATE_ENDED) done.countDown() }
                        override fun onPlayerError(error: PlaybackException) { failure = error; done.countDown() }
                    })
                    exo.setVideoFrameMetadataListener { pts, release, format, _ ->
                        val start = if (format.id == "p1-video") periodBoundary else 0L
                        frames[release] = Frame(pts, format.id, start)
                        while (frames.size > 64) frames.remove(frames.keys.first())
                    }
                    val output = YlDashSurfaceProbe(Handler(exo.playbackLooper))
                    probe = output
                    output.observe({ timestamp, rgb ->
                        val frame = frames.remove(timestamp)
                        val consumed = sink?.getCurrentPositionUs(false)
                        val observedHost = System.nanoTime()
                        val audio = if (consumed == null || consumed == AudioSink.CURRENT_POSITION_NOT_SET) null else consumed - audioOffset + audioStart
                        val video = frame?.let { it.ptsUs + it.periodStartUs }
                        // The decoder can deliver pixels before the codec's requested
                        // release instant. Retain both the observed consumption and the
                        // rate-1 projection to that native presentation timestamp.
                        val projected = audio?.let { it + (timestamp - observedHost) / 1000 }
                        val row = JSONObject().put("imageTimestampNs", timestamp).put("observedHostNs", observedHost)
                            .put("videoPtsUs", video ?: JSONObject.NULL).put("representation", frame?.formatId ?: JSONObject.NULL)
                            .put("audioUs", audio ?: JSONObject.NULL).put("audioProjectedAtReleaseUs", projected ?: JSONObject.NULL).put("audioPeriodStartUs", audioStart)
                            .put("audioStreamOffsetUs", audioOffset)
                            .put("rgb", JSONArray(rgb))
                            .put("rawDeltaUs", if (audio != null && video != null) video - audio else JSONObject.NULL)
                            .put("deltaUs", if (projected != null && video != null) video - projected else JSONObject.NULL)
                        synchronized(rows) { rows += row }
                    }, { error -> failure = error; done.countDown() })
                    exo.setVideoSurface(output.surface)
                    exo.setMediaSource(YlDashProgramMediaSource(item, DefaultHttpDataSource.Factory(),
                        YlDashManifestParser(null), DefaultLoadErrorHandlingPolicy(0), YlDashGapGroups()))
                    exo.prepare(); exo.play()
                }
            }
            assertTrue("Native AV did not finish", done.await(25, TimeUnit.SECONDS))
            probe?.drain()
            assertNull("Native AV failure", failure)
            val measured = synchronized(rows) { rows.toList() }
            val record = JSONObject().put("fixture", name).put("run", run)
                .put("elapsedMs", android.os.SystemClock.elapsedRealtime() - startedAt).put("rows", JSONArray(measured))
            // Log one bounded row per line to avoid Android logcat truncation.
            android.util.Log.i("P01_JOINT", JSONObject().put("fixture", name).put("run", run).put("elapsedMs", record.getLong("elapsedMs")).toString())
            for (row in measured) android.util.Log.i("P01_JOINT_ROW", row.put("fixture", name).put("run", run).toString())
            assertTrue("Actual surface frames absent: ${measured.size}", measured.size > 12)
            assertTrue("Image timestamps must match rendered frame metadata", measured.all { !it.isNull("videoPtsUs") })
            assertTrue("Native consumed clock absent", measured.count { !it.isNull("audioUs") } > 12)
            if (periodBoundary != Long.MAX_VALUE) assertTrue("Second Period actual output absent", measured.any { it.optLong("videoPtsUs") >= periodBoundary })
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
