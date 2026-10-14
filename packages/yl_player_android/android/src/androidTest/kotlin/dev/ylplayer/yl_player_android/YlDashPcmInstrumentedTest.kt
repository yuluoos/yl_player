package dev.ylplayer.yl_player_android

import android.content.Context
import androidx.media3.common.*
import androidx.media3.datasource.DefaultHttpDataSource
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

    @Test fun leadingAudioGapIsRealSilence() = measure("independent-pto", 192000,
        { it.replace("presentationTimeOffset=\"960000\"", "presentationTimeOffset=\"936000\"") }, 0 until 20000)
    @Test fun internalAudioGapIsRealSilence() = measure("independent-pto", 192000,
        { audioGap(it, false) }, 52800 until 86400)
    @Test fun trailingAudioGapIsRealSilence() = measure("independent-pto", 192000,
        { audioGap(it, true) }, 110000 until 180000)

    @Test fun seekInsideAacBufferPreservesDecodedPrerollTail() = measure("independent-pto", 168000,
        seekMs = 500, tone = 24000 until 24480)

    private fun audioGap(xml: String, trailing: Boolean): String {
        val adaptation = xml.indexOf("<AdaptationSet contentType=\"audio\"")
        val start = xml.indexOf("<SegmentTemplate", adaptation)
        val end = xml.indexOf("</SegmentTemplate>", start) + "</SegmentTemplate>".length
        val segments = if (trailing) listOf(1 to (960000 to 47104), 2 to (1007104 to 48128))
            else listOf(1 to (960000 to 47104), 3 to (1055232 to 48128), 4 to (1103360 to 48128), 5 to (1151488 to 512))
        val timeline = segments.joinToString("") { "<S t=\"${it.second.first}\" d=\"${it.second.second}\"/>" }
        val urls = segments.joinToString("") { "<SegmentURL media=\"chunk-1-${it.first.toString().padStart(5, '0')}.m4s\"/>" }
        return xml.replaceRange(start, end, "<SegmentList timescale=\"48000\" presentationTimeOffset=\"960000\"><Initialization sourceURL=\"init-1.m4s\"/><SegmentTimeline>$timeline</SegmentTimeline>$urls</SegmentList>")
    }

    private fun measure(name: String, expectedFrames: Int, transform: (String) -> String = { it }, silence: IntRange? = null, seekMs: Long = 0, tone: IntRange? = null) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val assets = instrumentation.context.assets
        val observations = mutableListOf<Triple<Long, Int, Int>>()
        var silentFrames = 0
        var silencePeak = 0
        var toneFrames = 0
        var tonePeak = 0
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
                val body = if (path.endsWith(".mpd")) transform(String(bytes)).replace(
                    Regex("<AdaptationSet[^>]*contentType=\"video\".*?</AdaptationSet>", RegexOption.DOT_MATCHES_ALL), "").toByteArray() else bytes
                return MockResponse().setBody(Buffer().write(body))
            }
        }
        server.start()
        val item = MediaItem.fromUri(server.url("/$name.mpd").toString())
        try {
            instrumentation.runOnMainSync {
                val renderers = object : YlOutputRenderersFactory(context, YlVideoOutputObserver({ it() }) { _, _ -> }) {
                    override fun buildAudioSink(context: Context, enableFloatOutput: Boolean, enableAudioOutputPlaybackParams: Boolean): AudioSink {
                        val recording = object : ForwardingAudioSink(super.buildAudioSink(context, enableFloatOutput, enableAudioOutputPlaybackParams)!!) {
                            var pcm = Format.Builder().build()
                            var previousPts = Long.MIN_VALUE
                            var offsetUs = 0L
                            override fun configure(config: AudioSink.AudioSinkConfig) {
                                pcm = config.format
                                check(pcm.encoderDelay == 0 && pcm.encoderPadding == 0) { "Probe must observe PCM after gapless trimming" }
                                super.configure(config)
                            }
                            override fun setOutputStreamOffsetUs(value: Long) { offsetUs = value; super.setOutputStreamOffsetUs(value) }
                            override fun handleBuffer(buffer: ByteBuffer, pts: Long, encodedAccessUnitCount: Int): Boolean {
                                if (pts != previousPts) {
                                    check(pcm.sampleMimeType == MimeTypes.AUDIO_RAW && pcm.pcmEncoding == C.ENCODING_PCM_16BIT)
                                    synchronized(observations) { val metadata = pcm.metadata
                                        val boundary = metadata?.let { (0 until it.length()).map(it::get).filterIsInstance<YlDashPcmWindow>().firstOrNull() }
                                        val programmeUs = pts - offsetUs + (boundary?.start?.units(1_000_000) ?: 0)
                                        val frames = buffer.remaining() / (2 * pcm.channelCount)
                                        observations.add(Triple(programmeUs, frames, pcm.sampleRate))
                                        if (silence != null || tone != null) {
                                            val firstFrame = (programmeUs * pcm.sampleRate + 500000) / 1000000
                                            val samples = buffer.duplicate().order(java.nio.ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                                            for (frame in 0 until frames) {
                                                val index = (firstFrame + frame).toInt()
                                                if (tone != null && index in tone) {
                                                    toneFrames++
                                                    for (channel in 0 until pcm.channelCount) tonePeak = maxOf(tonePeak,
                                                        kotlin.math.abs(samples.get(frame * pcm.channelCount + channel).toInt()))
                                                }
                                                if (silence == null || index !in silence) continue
                                                silentFrames++
                                                for (channel in 0 until pcm.channelCount) silencePeak = maxOf(silencePeak,
                                                    kotlin.math.abs(samples.get(frame * pcm.channelCount + channel).toInt()))
                                            }
                                        } }
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
                    if (seekMs != 0L) exo.seekTo(seekMs)
                    exo.prepare(); exo.play()
                }
            }
            assertTrue("Real audio did not finish", done.await(25, TimeUnit.SECONDS))
            assertNull("Playback failed", error)
            instrumentation.runOnMainSync {
                assertEquals("Sample availability must not shorten the programme", (expectedFrames + seekMs * 48) / 48, player!!.duration)
            }
            val samples = synchronized(observations) { observations.toList() }
            assertTrue(samples.isNotEmpty())
            assertTrue(samples.all { it.third == 48000 })
            android.util.Log.i("P01_PCM", "case=$name buffers=${samples.size} frames=${samples.sumOf { it.second }} first=${samples.first()} last=${samples.last()}")
            assertEquals("Decoded PCM must cover exactly the programme window", expectedFrames, samples.sumOf { it.second })
            if (silence != null) {
                assertEquals("Silence must consume real programme frames", silence.count(), silentFrames)
                assertEquals("Gap must contain zero PCM", 0, silencePeak)
            }
            if (tone != null) {
                assertEquals("The seek slice must contain real samples", tone.count(), toneFrames)
                assertTrue("The partial preroll tail must not be replaced with silence", tonePeak > 100)
            }
            assertTrue("No PCM may extend beyond programme end", samples.all { it.first * 48000 + it.second * 1000000L <= (expectedFrames + seekMs * 48) * 1000000L })
        } finally {
            instrumentation.runOnMainSync { player?.release() }
            server.shutdown()
        }
    }
}
