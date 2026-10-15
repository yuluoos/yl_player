package dev.ylplayer.yl_player_android

import android.graphics.ImageFormat
import android.media.ImageReader
import android.os.Handler
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.test.platform.app.InstrumentationRegistry
import dev.ylplayer.yl_player_android.pigeon.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Actual owned PS and default Media3 output. Controlled admissions grant no
 * production software or physical-output qualification. Raw Media3's failed
 * audio-only PS baseline is retained in the P03 observations. */
class YlFormatDecodeInstrumentedTest {
    private fun openNativePs(): YlFfmpegSession {
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        val bytes = assets.open("format_matrix/ps-avc-mp3.mpg").use { it.readBytes() }
        val source = object : YlNativeByteSource {
            var position = 0; var cancelled = false
            override fun read(target: java.nio.ByteBuffer): Int {
                if (cancelled) return -2
                val count = minOf(target.remaining(), bytes.size - position)
                target.put(bytes, position, count); position += count; return count
            }
            override fun seek(offset: Long, whence: Int): Long {
                if (cancelled) return -2
                if (whence and 0x10000 != 0) return bytes.size.toLong()
                val next = when (whence and 3) { 0 -> offset; 1 -> position + offset; 2 -> bytes.size + offset; else -> return -3 }
                if (next !in 0L..bytes.size.toLong()) return -3
                position = next.toInt(); return next
            }
            override fun cancel() { cancelled = true }
            override fun close() { cancel() }
        }
        return YlFfmpegSession.open(source)
    }

    @Test fun nativePsMetadataAndZeroBasedSeek() {
        openNativePs().use { session ->
            val video = session.mediaInfo.streams.single { it.kind == YlNativeStreamKind.VIDEO }
            assertEquals(YlNativeCodec.H264, video.codec)
            assertEquals(320, video.width); assertEquals(180, video.height)
            assertTrue(video.fpsNumerator > 0 && video.fpsDenominator > 0)
            assertEquals(8, video.bitDepth); assertEquals(420, video.chroma)
            for (target in listOf(0L, 2_000_000L, 500_000L)) {
                assertTrue("PS seek failed", session.seekTo(target))
                val packet = generateSequence { session.readPacket() }.first { it.streamIndex == video.index }
                assertTrue("PS timestamp was not normalized: ${packet.presentationTimeUs}", packet.presentationTimeUs <= target + 100_000)
            }
        }
    }

    @Test fun admittedNativeSoftwareOutputsPixelsAndReturnsEveryReceipt() {
        val pool = YlSoftwareDecodePool()
        val thread = android.os.HandlerThread("p03-native-pixels").apply { start() }
        val reader = ImageReader.newInstance(320, 180, android.graphics.PixelFormat.RGBX_8888, 4)
        val pixels = java.util.Collections.synchronizedList(mutableListOf<List<Int>>())
        reader.setOnImageAvailableListener({ r -> r.acquireLatestImage()?.use { image ->
            val plane = image.planes[0]; val offset = 90 * plane.rowStride + 160 * plane.pixelStride
            pixels += (0..2).map { plane.buffer.get(offset + it).toInt() and 255 }
        } }, Handler(thread.looper))
        try {
            openNativePs().use { session ->
                val stream = session.mediaInfo.streams.single { it.kind == YlNativeStreamKind.VIDEO }
                val identity = YlSoftwareDecodeIdentity("controlled", "test", "test")
                val key = YlSoftwareDecodeKey(identity.model, identity.osBuild, identity.decoderBuild,
                    stream.codec.ordinal, stream.profile, stream.bitDepth, stream.chroma, stream.width, stream.height,
                    stream.fpsNumerator, stream.fpsDenominator, 2, 1)
                val limits = YlSoftwareDecodeLimits(32L * 1024 * 1024, 64, 1024 * 1024, 1_000_000_000, 1_000_000_000, 1_000_000_000)
                var tick = 0L
                val services = YlSoftwareDecodeServices(identity, YlSoftwareDecodeAdmission(mapOf(key to limits)), pool, 2) {
                    tick++; YlSoftwareDecodeObservation(tick, tick, 1, true)
                }
                val lease = services.acquire(stream)
                assertTrue(session.configureSoftwareVideo(stream.index, reader.surface, lease))
                assertTrue(session.seekTo(0))
                var frames = 0
                while (true) {
                    val packet = session.readPacket() ?: break
                    packet.use {
                        if (packet.streamIndex == stream.index) {
                            val timestamps = session.decodeSoftwareVideo(packet)
                            frames += timestamps.size
                            for (pts in timestamps) { assertTrue(pts >= 0); assertTrue(session.renderSoftwareVideoFrame()) }
                        }
                    }
                }
                val tail = session.finishSoftwareVideo(); frames += tail.size
                tail.forEach { assertTrue(session.renderSoftwareVideoFrame()) }
                assertEquals(96, frames)
                assertTrue("Actual surfaces were not charged", pool.ownedBytes > 0)
            }
            val drained = CountDownLatch(1); Handler(thread.looper).post { drained.countDown() }
            assertTrue(drained.await(2, TimeUnit.SECONDS))
            val observed = synchronized(pixels) { pixels.toList() }
            android.util.Log.i("P03_NATIVE", JSONObject().put("frames", observed.size).put("pixels", observed.toString())
                .put("remainingBytes", pool.ownedBytes).toString())
            assertTrue("No actual red marker", observed.any { it[0] > 220 && it[1] < 35 && it[2] < 35 })
            assertTrue("No actual green marker", observed.any { it[0] < 35 && it[1] > 220 && it[2] < 35 })
            assertEquals(0L, pool.ownedBytes)
        } finally { reader.close(); thread.quitSafely(); thread.join(2000) }
    }

    @Test fun nativeFrameBudgetFailureIsResourceExhaustedAndReleasesEverything() {
        val pool = YlSoftwareDecodePool()
        val reader = ImageReader.newInstance(320, 180, android.graphics.PixelFormat.RGBX_8888, 2)
        try {
            openNativePs().use { session ->
                val stream = session.mediaInfo.streams.single { it.kind == YlNativeStreamKind.VIDEO }
                val key = YlSoftwareDecodeKey("controlled", "test", "test", stream.codec.ordinal, stream.profile,
                    stream.bitDepth, stream.chroma, stream.width, stream.height, stream.fpsNumerator, stream.fpsDenominator, 2, 1)
                val limits = YlSoftwareDecodeLimits(32L * 1024 * 1024, 1, 1024 * 1024, 1_000_000_000, 1_000_000_000, 1_000_000_000)
                var tick = 0L
                val services = YlSoftwareDecodeServices(YlSoftwareDecodeIdentity("controlled", "test", "test"),
                    YlSoftwareDecodeAdmission(mapOf(key to limits)), pool, 2) {
                    tick++; YlSoftwareDecodeObservation(tick, tick, 1, true)
                }
                assertTrue(session.configureSoftwareVideo(stream.index, reader.surface, services.acquire(stream)))
                var failure: YlBoundaryException? = null
                try {
                    while (true) {
                        val packet = session.readPacket() ?: break
                        packet.use { if (it.streamIndex == stream.index) session.decodeSoftwareVideo(it) }
                    }
                    session.finishSoftwareVideo()
                } catch (error: YlBoundaryException) { failure = error }
                assertEquals(YlFailureKind.RESOURCE_EXHAUSTED, failure?.kind)
            }
            assertEquals(0L, pool.ownedBytes)
        } finally { reader.close() }
    }

    @Test fun nativePreparationNeverClaimsAnUninitializedDecoder() = kotlinx.coroutines.runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val file = File(instrumentation.targetContext.cacheDir, "p03-preparation.mpg")
        instrumentation.context.assets.open("format_matrix/ps-avc-mp3.mpg").use { input -> file.outputStream().use(input::copyTo) }
        val engine = YlNativeFallbackEngine(instrumentation.targetContext, YlSessionIdentity("p03", "prepare"),
            AndroidSourceMessage(AndroidSourceKind.FILE, file.absolutePath, AndroidStreamIntent.ON_DEMAND, AndroidMediaFormat.MPEG_PS),
            AndroidLoadOptionsMessage(false, bufferStrategy = AndroidBufferStrategyMessage(AndroidBufferKind.AUTOMATIC),
                videoConstraints = AndroidVideoConstraintsMessage()),
            AndroidPlayerOptionsMessage(AndroidDecoderPolicy.HARDWARE_PREFERRED, AndroidAudioPolicy.APP_MANAGED, 250),
            kotlinx.coroutines.Dispatchers.Unconfined)
        val snapshots = java.util.Collections.synchronizedList(mutableListOf<YlEngineSnapshot>())
        engine.registerCallback { _, event -> if (event is YlEngineEvent.Snapshot) snapshots += event.value }
        try {
            engine.prepare()
            assertTrue(snapshots.isNotEmpty())
            assertEquals(AndroidDecoderMode.UNKNOWN, snapshots.last().decoderMode)
            assertNull(snapshots.last().decoderIdentity)
        } finally { engine.dispose().await(); file.delete() }
    }

    @Test fun ownedPsHardwareOutputsPixels() {
        val thread = android.os.HandlerThread("p03-hardware-pixels").apply { start() }
        val reader = ImageReader.newInstance(320, 180, ImageFormat.YUV_420_888, 4)
        val images = java.util.concurrent.atomic.AtomicInteger()
        reader.setOnImageAvailableListener({ r -> r.acquireLatestImage()?.use {
            assertTrue(it.planes[0].buffer.remaining() > 0); images.incrementAndGet()
        } }, Handler(thread.looper))
        try {
            openNativePs().use { session ->
                val stream = session.mediaInfo.streams.single { it.kind == YlNativeStreamKind.VIDEO }
                val name = checkNotNull(YlHardwareCodecProbe.findVideoDecoder(stream))
                assertTrue(session.configureHardwareVideo(stream.index))
                YlHardwareVideoDecoder(stream, reader.surface, name, session.hardwareCodecConfig()).use { decoder ->
                    assertEquals(name, decoder.decoderIdentity)
                    while (true) {
                        val packet = session.readPacket() ?: break
                        packet.use { if (it.streamIndex == stream.index) decoder.consume(it) }
                    }
                    decoder.flush()
                    decoder.replaceSurface(reader.surface)
                    assertEquals(name, decoder.decoderIdentity)
                }
            }
            val drained = CountDownLatch(1); Handler(thread.looper).post { drained.countDown() }
            assertTrue(drained.await(2, TimeUnit.SECONDS))
            assertTrue("Owned PS produced no actual hardware images", images.get() > 0)
        } finally { reader.close(); thread.quitSafely(); thread.join(2000) }
    }
    @Test fun media3AviAvc() = media3("avi-avc-mp3.avi")
    @Test fun media3Av1() = media3("mkv-av1-opus.mkv")

    private fun media3(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val input = File(context.cacheDir, "p03-$name")
        instrumentation.context.assets.open("format_matrix/$name").use { source -> input.outputStream().use(source::copyTo) }
        val done = CountDownLatch(1)
        var player: ExoPlayer? = null
        var failure: PlaybackException? = null
        var decoder: String? = null
        var images = 0
        var ended = false
        val reader = ImageReader.newInstance(320, 180, ImageFormat.YUV_420_888, 4)
        try {
            instrumentation.runOnMainSync {
                reader.setOnImageAvailableListener({ r -> r.acquireLatestImage()?.use { image ->
                    check(image.planes[0].buffer.remaining() > 0)
                    images++
                } }, Handler(context.mainLooper))
                player = ExoPlayer.Builder(context).build().also { exo ->
                    exo.addAnalyticsListener(object : AnalyticsListener {
                        override fun onVideoDecoderInitialized(eventTime: AnalyticsListener.EventTime,
                            decoderName: String, initializedTimestampMs: Long, initializationDurationMs: Long) {
                            decoder = decoderName
                        }
                    })
                    exo.addListener(object : Player.Listener {
                        override fun onPlayerError(error: PlaybackException) { failure = error; done.countDown() }
                        override fun onPlaybackStateChanged(state: Int) {
                            if (state == Player.STATE_ENDED) { ended = true; done.countDown() }
                        }
                    })
                    exo.setVideoSurface(reader.surface)
                    exo.setMediaItem(MediaItem.fromUri(android.net.Uri.fromFile(input)))
                    exo.prepare(); exo.play()
                }
            }
            val finished = done.await(25, TimeUnit.SECONDS)
            instrumentation.runOnMainSync {
                android.util.Log.i("P03_FORMAT", JSONObject().put("fixture", name)
                    .put("decoder", decoder).put("images", images).put("ended", ended)
                    .put("state", player!!.playbackState).put("positionMs", player!!.currentPosition)
                    .put("playWhenReady", player!!.playWhenReady).put("suppression", player!!.playbackSuppressionReason)
                    .put("tracks", player!!.currentTracks.groups.joinToString { "${it.type}:${it.isSelected}" })
                    .put("failure", failure?.errorCodeName).put("cause", failure?.cause.toString()).toString())
                assertTrue("No real output: fixture=$name decoder=$decoder images=$images failure=$failure", images > 0)
                assertNotNull("Missing initialized decoder identity", decoder)
                assertTrue("Fixture did not reach EOS", ended)
            }
            assertTrue("Timed out", finished)
            assertNull(failure)
        } finally {
            instrumentation.runOnMainSync { player?.release(); reader.close() }
            input.delete()
        }
    }
}
