package dev.ylplayer.yl_player_android

import android.content.Context
import androidx.media3.common.*
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.ForwardingAudioSink
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.test.platform.app.InstrumentationRegistry
import okhttp3.mockwebserver.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Real MediaCodec decode and AudioTrack consumption; captures submitted PCM, not physical sound. */
class YlDashPcmInstrumentedTest {
    @Test fun clipEndHasExactlyThreeAndHalfSecondsOfPcm() = measure("clip-end", 168000)
    @Test fun independentPtoHasExactlyFourSecondsOfPcm() = measure("independent-pto", 192000)
    @Test fun crossPeriodHasExactlyThreeSecondsOfPcm() = measure("cross-codec", 144000)

    private fun measure(name: String, expectedFrames: Int) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val assets = instrumentation.context.assets
        val observations = mutableListOf<Triple<Long, Int, Int>>()
        val done = CountDownLatch(1)
        var error: PlaybackException? = null
        var player: ExoPlayer? = null
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.path!!.substringBefore('?').removePrefix("/")
                if (path.contains("..")) return MockResponse().setResponseCode(404)
                val bytes = assets.open(path).use { it.readBytes() }
                // This probe isolates audio while preserving the source's exact Period/PTO.
                val body = if (path.endsWith(".mpd")) String(bytes).replace(
                    Regex("<AdaptationSet[^>]*contentType=\"video\".*?</AdaptationSet>", RegexOption.DOT_MATCHES_ALL), "").toByteArray() else bytes
                return MockResponse().setBody(Buffer().write(body))
            }
        }
        server.start()
        val item = MediaItem.fromUri(server.url("/$name.mpd").toString())
        try {
            instrumentation.runOnMainSync {
                val renderers = object : DefaultRenderersFactory(context) {
                    override fun buildAudioSink(context: Context, enableFloatOutput: Boolean, enableAudioOutputPlaybackParams: Boolean): AudioSink {
                        val recording = object : ForwardingAudioSink(super.buildAudioSink(context, enableFloatOutput, enableAudioOutputPlaybackParams)!!) {
                            var pcm = Format.Builder().build()
                            var previousPts = Long.MIN_VALUE
                            var offsetUs = 0L
                            override fun configure(config: AudioSink.AudioSinkConfig) { pcm = config.format; super.configure(config) }
                            override fun setOutputStreamOffsetUs(value: Long) { offsetUs = value; super.setOutputStreamOffsetUs(value) }
                            override fun handleBuffer(buffer: ByteBuffer, pts: Long, encodedAccessUnitCount: Int): Boolean {
                                if (pts != previousPts) {
                                    check(pcm.sampleMimeType == MimeTypes.AUDIO_RAW && pcm.pcmEncoding == C.ENCODING_PCM_16BIT)
                                    synchronized(observations) { val metadata = pcm.metadata
                                        val boundary = metadata?.let { (0 until it.length()).map(it::get).filterIsInstance<YlDashPcmWindow>().firstOrNull() }
                                        observations.add(Triple(pts - offsetUs + (boundary?.start?.units(1_000_000) ?: 0), buffer.remaining() / (2 * pcm.channelCount), pcm.sampleRate)) }
                                    previousPts = pts
                                }
                                return super.handleBuffer(buffer, pts, encodedAccessUnitCount)
                            }
                        }
                        return YlDashPcmAudioSink(recording)
                    }
                }
                player = ExoPlayer.Builder(context, renderers).build().also { exo ->
                    exo.addListener(object : Player.Listener {
                        override fun onPlaybackStateChanged(state: Int) { if (state == Player.STATE_ENDED) done.countDown() }
                        override fun onPlayerError(value: PlaybackException) { error = value; done.countDown() }
                    })
                    exo.setMediaSource(YlDashProgramMediaSource(item, DefaultHttpDataSource.Factory(),
                        YlDashManifestParser(null), DefaultLoadErrorHandlingPolicy(0), YlDashGapGroups()))
                    exo.prepare(); exo.play()
                }
            }
            assertTrue("Real audio did not finish", done.await(25, TimeUnit.SECONDS))
            assertNull("Playback failed", error)
            val samples = synchronized(observations) { observations.toList() }
            assertTrue(samples.isNotEmpty())
            assertTrue(samples.all { it.third == 48000 })
            android.util.Log.i("P01_PCM", "case=$name buffers=${samples.size} frames=${samples.sumOf { it.second }} first=${samples.first()} last=${samples.last()}")
            assertEquals("Decoded PCM must be clipped inside the final AAC packet", expectedFrames, samples.sumOf { it.second })
            assertTrue("No PCM may extend beyond programme end", samples.all { it.first * 48000 + it.second * 1000000L <= expectedFrames * 1000000L })
        } finally {
            instrumentation.runOnMainSync { player?.release() }
            server.shutdown()
        }
    }
}
