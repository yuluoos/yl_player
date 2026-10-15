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
    private fun openNativePs(name: String = "ps-avc-mp3.mpg"): YlFfmpegSession {
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        val bytes = assets.open("format_matrix/$name").use { it.readBytes() }
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
            for (target in listOf(0L, 2_000_000L, 1_250_000L, 500_000L)) {
                assertTrue("PS seek failed", session.seekTo(target))
                val packet = generateSequence { session.readPacket() }.first { it.streamIndex == video.index }
                android.util.Log.i("P03_SEEK", "target=$target pts=${packet.presentationTimeUs} key=${packet.keyFrame}")
                packet.use {
                    assertTrue("PS timestamp was not normalized: ${it.presentationTimeUs}", it.presentationTimeUs <= target + 100_000)
                    assertTrue("PS seek must restore a decodable keyframe at or before target", it.keyFrame)
                }
            }
        }
    }

    @Test fun nativeTransportAndAviTimestampsAreUsable() {
        for(name in listOf("ts-avc-ac3.ts","avi-avc-mp3.avi")) openNativePs(name).use { session ->
            val video=session.mediaInfo.streams.single {it.kind==YlNativeStreamKind.VIDEO}
            assertTrue(session.seekTo(0))
            val packet=generateSequence {session.readPacket()}.first {it.streamIndex==video.index}
            packet.use {assertTrue("$name pts=${it.presentationTimeUs}",it.presentationTimeUs in 0..100_000)}
        }
    }
    @Test fun nativeAviSeekKeepsPacketClockIdentity() {
        openNativePs("avi-avc-mp3.avi").use { session ->
            val video=session.mediaInfo.streams.single {it.kind==YlNativeStreamKind.VIDEO}
            val linear=mutableMapOf<Long,ByteArray>()
            while(true) {
                val packet=session.readPacket() ?: break
                packet.use { if(it.streamIndex==video.index) linear[it.presentationTimeUs]=it.data }
            }
            for(target in listOf(2_000_000L,1_250_000L,500_000L)) {
                assertTrue(session.seekTo(target))
                var videoPackets=0
                while(true) {
                    val packet=session.readPacket() ?: break
                    packet.use { if(it.streamIndex==video.index) {
                        if(videoPackets++==0) assertTrue(it.presentationTimeUs<=target)
                        assertArrayEquals("AVI seek relabeled a different frame at ${it.presentationTimeUs}",linear[it.presentationTimeUs],it.data)
                    } }
                }
                assertTrue(videoPackets>0)
            }
        }
    }

    @Test fun nativeMain10MetadataPreservesProfile() {
        openNativePs("mkv-hevc-main10-aac.mkv").use { session ->
            val video=session.mediaInfo.streams.single {it.kind==YlNativeStreamKind.VIDEO}
            assertEquals(2,video.profile)
            assertEquals(10,video.bitDepth)
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

    @Test fun actualEngineBudgetFailureIsOneTerminalEventAndCleanup() = kotlinx.coroutines.runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File(context.cacheDir, "p03-engine-budget.mpg")
        InstrumentationRegistry.getInstrumentation().context.assets.open("format_matrix/ps-avc-mp3.mpg").use { input -> file.outputStream().use(input::copyTo) }
        val pool = YlSoftwareDecodePool()
        val stream = openNativePs().use { it.mediaInfo.streams.single { s -> s.kind == YlNativeStreamKind.VIDEO } }
        val key = YlSoftwareDecodeKey("controlled", "test", "test", stream.codec.ordinal, stream.profile,
            stream.bitDepth, stream.chroma, stream.width, stream.height, stream.fpsNumerator, stream.fpsDenominator, 2, 1)
        val limits = YlSoftwareDecodeLimits(32L*1024*1024,1,1024*1024,1_000_000_000,1_000_000_000,1_000_000_000)
        var tick=0L
        val services = YlSoftwareDecodeServices(YlSoftwareDecodeIdentity("controlled","test","test"),
            YlSoftwareDecodeAdmission(mapOf(key to limits)),pool,2) { tick++;YlSoftwareDecodeObservation(tick,tick,1,true) }
        val texture = android.graphics.SurfaceTexture(false)
        val entry = object : io.flutter.view.TextureRegistry.SurfaceTextureEntry {
            override fun id() = 903L
            override fun surfaceTexture() = texture
            override fun release() = texture.release()
        }
        val output = YlVideoOutput(entry)
        val engine = YlNativeFallbackEngine(context,YlSessionIdentity("p03","budget"),
            AndroidSourceMessage(AndroidSourceKind.FILE,file.absolutePath,AndroidStreamIntent.ON_DEMAND,AndroidMediaFormat.MPEG_PS),
            AndroidLoadOptionsMessage(false,bufferStrategy=AndroidBufferStrategyMessage(AndroidBufferKind.AUTOMATIC),videoConstraints=AndroidVideoConstraintsMessage()),
            AndroidPlayerOptionsMessage(AndroidDecoderPolicy.HARDWARE_PREFERRED,AndroidAudioPolicy.APP_MANAGED,250),
            kotlinx.coroutines.Dispatchers.Unconfined,services,findHardwareDecoder={null})
        val failure = kotlinx.coroutines.CompletableDeferred<YlFailureKind>()
        val count = java.util.concurrent.atomic.AtomicInteger()
        val snapshots = java.util.Collections.synchronizedList(mutableListOf<YlEngineSnapshot>())
        engine.registerCallback { _,event -> when(event) {
            is YlEngineEvent.Failed -> {count.incrementAndGet();failure.complete(event.kind)}
            is YlEngineEvent.Snapshot -> snapshots.add(event.value)
            else -> Unit
        } }
        try {
            engine.prepare();engine.activate(output)
            assertEquals(AndroidDecoderMode.SOFTWARE,snapshots.last().decoderMode)
            assertEquals("ffmpeg-h264",snapshots.last().decoderIdentity)
            engine.onConfigurationChanged()
            engine.play()
            assertEquals(YlFailureKind.RESOURCE_EXHAUSTED,kotlinx.coroutines.withTimeout(5000) { failure.await() })
            kotlinx.coroutines.delay(100)
            assertEquals(1,count.get())
        } finally {engine.dispose().await();output.release();file.delete()}
        assertEquals(0L,pool.ownedBytes)
    }

    @Test fun nativeInitialPositionTrimsActualAudioAndVideo() = kotlinx.coroutines.runBlocking {
        for (fixture in listOf("avi-avc-mp3.avi", "flv-avc-mp3.flv")) checkTimelineReset(fixture, false)
    }
    @Test fun nativeAudioSwitchTrimsPrerollAndFlushesActualVideo() = kotlinx.coroutines.runBlocking {
        checkTimelineReset("avi-two-audio-control.avi", true)
    }
    @Test fun nativeFailedAudioSwitchSeekRetainsSelectedTrack() = kotlinx.coroutines.runBlocking {
        checkTimelineReset("avi-two-audio-control.avi", true, true)
    }
    private suspend fun checkTimelineReset(fixture: String, switch: Boolean, failSeek: Boolean = false) {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext
        val file=File(context.cacheDir,"p03-reset-$fixture")
        instrumentation.context.assets.open("format_matrix/$fixture").use { source -> file.outputStream().use(source::copyTo) }
        val texture=android.graphics.SurfaceTexture(false)
        val entry=object : io.flutter.view.TextureRegistry.SurfaceTextureEntry {
            override fun id()=904L
            override fun surfaceTexture()=texture
            override fun release()=texture.release()
        }
        val output=YlVideoOutput(entry)
        val reader=ImageReader.newInstance(320,180,ImageFormat.YUV_420_888,4)
        val luminance=java.util.Collections.synchronizedList(mutableListOf<Int>())
        reader.setOnImageAvailableListener({ r -> r.acquireLatestImage()?.use { image ->
            val plane=image.planes[0]
            luminance.add(plane.buffer.get(90*plane.rowStride+160*plane.pixelStride).toInt() and 255)
        } },Handler(context.mainLooper))
        val pcm=java.util.Collections.synchronizedList(mutableListOf<YlNativePcmChunk>())
        val video=java.util.Collections.synchronizedList(mutableListOf<Long>())
        val errors=java.util.Collections.synchronizedList(mutableListOf<YlFailureKind>())
        var rejectSeek=false
        var floorUs=2_500_000L
        val snapshot=java.util.concurrent.atomic.AtomicReference<YlEngineSnapshot>()
        val engine=YlNativeFallbackEngine(context,YlSessionIdentity("p03","reset"),
            AndroidSourceMessage(AndroidSourceKind.FILE,file.absolutePath,AndroidStreamIntent.ON_DEMAND,AndroidMediaFormat.AUTOMATIC),
            AndroidLoadOptionsMessage(false,startPositionMs=if(switch) 0 else 2500,
                bufferStrategy=AndroidBufferStrategyMessage(AndroidBufferKind.AUTOMATIC),videoConstraints=AndroidVideoConstraintsMessage()),
            AndroidPlayerOptionsMessage(AndroidDecoderPolicy.HARDWARE_REQUIRED,AndroidAudioPolicy.APP_MANAGED,250),
            kotlinx.coroutines.Dispatchers.Unconfined,observePcm={pcm.add(it)},observeVideo={video.add(it)},
            seekNative={native,target -> if(rejectSeek) false else native.seekTo(target)},surfaceForOutput={reader.surface})
        engine.registerCallback { _,event -> when(event) {
            is YlEngineEvent.Failed -> errors.add(event.kind)
            is YlEngineEvent.Snapshot -> snapshot.set(event.value)
            else -> Unit
        } }
        try {
            engine.prepare();engine.activate(output)
            if(switch) {
                // Prime real old decoder output, then establish a paused,
                // non-keyframe programme point before replacing audio.
                engine.seekTo(2500);engine.play()
                kotlinx.coroutines.withTimeout(5000) { while(pcm.isEmpty() || video.isEmpty()) kotlinx.coroutines.delay(5) }
                engine.pause()
                floorUs=snapshot.get().timeline.positionMs*1000
                pcm.clear();video.clear();luminance.clear()
                rejectSeek=failSeek
                if(failSeek) {
                    try {engine.selectAudioTrack("ffmpeg-audio-2");fail("Failed seek was ignored")}
                    catch(error: YlBoundaryException) {assertEquals(YlFailureKind.SOURCE_INVALID,error.kind)}
                    assertEquals("ffmpeg-audio-1",snapshot.get().audioTracks.single {it.isSelected}.id)
                    return
                }
                engine.selectAudioTrack("ffmpeg-audio-2")
            }
            engine.play()
            kotlinx.coroutines.withTimeout(5000) { while(pcm.isEmpty() || video.isEmpty() || luminance.isEmpty()) {assertTrue(errors.toString(),errors.isEmpty());kotlinx.coroutines.delay(5)} }
            engine.pause()
            assertTrue("$fixture preroll PCM escaped: ${pcm.map {it.presentationTimeUs}}",pcm.all {it.presentationTimeUs>=floorUs})
            assertTrue("$fixture old/preroll video escaped: $video",video.all {it>=floorUs})
            assertTrue("Missing actual samples",pcm.first().data.isNotEmpty())
            assertTrue("First output must be blue, actual Y=$luminance",luminance.first() in 30..50)
            assertTrue(errors.toString(),errors.isEmpty())
        } finally {engine.dispose().await();output.release();reader.close();file.delete()}
    }

    @Test fun ownedPsHardwareOutputsPixels() = hardwarePixels("ps-avc-mp3.mpg")
    @Test fun ownedEac3ContainerHardwareOutputsPixels() = hardwarePixels("mkv-avc-eac3.mkv")
    private fun hardwarePixels(fixture: String) {
        val thread = android.os.HandlerThread("p03-hardware-pixels").apply { start() }
        val reader = ImageReader.newInstance(320, 180, ImageFormat.YUV_420_888, 4)
        val images = java.util.concurrent.atomic.AtomicInteger()
        reader.setOnImageAvailableListener({ r -> r.acquireLatestImage()?.use {
            assertTrue(it.planes[0].buffer.remaining() > 0); images.incrementAndGet()
        } }, Handler(thread.looper))
        try {
            openNativePs(fixture).use { session ->
                val stream = session.mediaInfo.streams.single { it.kind == YlNativeStreamKind.VIDEO }
                val name = checkNotNull(YlHardwareCodecProbe.findVideoDecoder(stream))
                assertTrue(session.configureHardwareVideo(stream.index))
                YlHardwareVideoDecoder(stream, reader.surface, name, session.hardwareCodecConfig()).use { decoder ->
                    assertEquals(name, decoder.decoderIdentity)
                    while (true) {
                        val packet = session.readPacket() ?: break
                        packet.use { if (it.streamIndex == stream.index) decoder.consume(it) }
                    }
                    decoder.finish()
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
    @Test fun media3Eac3VideoOnly() = media3("mkv-avc-eac3.mkv", videoOnly=true)
    @Test fun media3Av1() = media3("mkv-av1-opus.mkv")

    private fun media3(name: String, videoOnly: Boolean = false) {
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
                    if(videoOnly) exo.trackSelectionParameters=exo.trackSelectionParameters.buildUpon()
                        .setTrackTypeDisabled(androidx.media3.common.C.TRACK_TYPE_AUDIO,true).build()
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
