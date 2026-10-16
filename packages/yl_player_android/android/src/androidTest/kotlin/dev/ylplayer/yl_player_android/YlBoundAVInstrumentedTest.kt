package dev.ylplayer.yl_player_android

import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Base64
import androidx.test.platform.app.InstrumentationRegistry
import dev.ylplayer.yl_player_android.pigeon.*
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Foreground host for app-managed audio in this instrumentation APK only. */
class YlBoundAVActivity : android.app.Activity() {
    override fun onCreate(state: android.os.Bundle?) {
        super.onCreate(state)
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}

/** Raw same-player observations from the actual instrumented library APK.
 * The APK includes both product and harness; it is not a Flutter release build.
 * The host freezes bytes before install and independently checks every window.
 */
class YlBoundAVInstrumentedTest {
    private fun sha(bytes: ByteArray)=MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private fun fileSha(file: File): String {
        val digest=MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input -> val buffer=ByteArray(1024*1024); while(true) {
            val count=input.read(buffer); if(count<0)break; digest.update(buffer,0,count)
        } }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
    @Test fun frozenProductSamePlayerAV() = runBlocking {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val encoded=InstrumentationRegistry.getArguments().getString("p03Plan")
        // This separately invoked evidence job requires a host-frozen identity.
        org.junit.Assume.assumeNotNull(encoded)
        val plan=JSONObject(String(Base64.decode(encoded,Base64.DEFAULT)))
        assertEquals("android",plan.getString("platform"))
        val apk=File(instrumentation.context.applicationInfo.sourceDir)
        assertEquals(plan.getString("buildSha256"),fileSha(apk))
        assertEquals(plan.getString("testSha256"),fileSha(apk))
        val sink=File(instrumentation.context.filesDir,"p03-${plan.getString("runId")}.jsonl")
        assertTrue("A run must never overwrite prior evidence",sink.createNewFile())
        val activity=instrumentation.startActivitySync(android.content.Intent(instrumentation.context,YlBoundAVActivity::class.java)
            .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
        val focus=YlAndroidAudioFocusDriver(activity)
        val failures=mutableListOf<String>()
        try {
        assertTrue("Foreground app-managed audio focus denied",focus.request {})
        val planned=plan.getJSONArray("planned")
        for(index in 0 until planned.length()) {
            val case=planned.getJSONObject(index)
            val row=JSONObject().put("schema",1).put("runId",plan.getString("runId"))
                .put("sessionId",UUID.randomUUID().toString()).put("platform","android")
                .put("buildSha256",plan.getString("buildSha256")).put("testSha256",plan.getString("testSha256"))
                .put("caseId",case.getString("caseId")).put("identityVerified",true)
                .put("audioClockMethod","audiotrack-playback-head")
                .put("outcome","failed").put("completed",false).put("disposed",false).put("releasedAudioBytes",-1)
                .put("runtime",android.os.Build.FINGERPRINT).put("phases",JSONArray())
            try { capture(plan,case,row) } catch(error: Throwable) {
                row.put("failureCode",(error as? YlBoundaryException)?.kind?.name ?: error.javaClass.name).put("failure",error.message ?: "")
                failures.add("${case.getString("caseId")}: $error")
            } finally { sink.appendText(row.toString()+"\n") }
        }
        assertEquals("Installed APK changed during collection",plan.getString("buildSha256"),fileSha(apk))
        assertTrue(failures.joinToString("\n"),failures.isEmpty())
        } finally {focus.abandon();instrumentation.runOnMainSync {activity.finish()}}
    }

    private suspend fun capture(plan: JSONObject, case: JSONObject, row: JSONObject) {
        val instrumentation=InstrumentationRegistry.getInstrumentation(); val context=instrumentation.targetContext
        val file=File(context.cacheDir,"p03-bound-${case.getString("file")}")
        instrumentation.context.assets.open("format_matrix/${case.getString("file")}").use { input -> file.outputStream().use(input::copyTo) }
        row.put("mediaHash",fileSha(file));assertEquals(case.getString("mediaHash"),row.getString("mediaHash"))
        val texture=SurfaceTexture(false)
        val output=YlVideoOutput(object:io.flutter.view.TextureRegistry.SurfaceTextureEntry {
            override fun id()=905L
            override fun surfaceTexture()=texture
            override fun release()=texture.release()
        })
        val thread=HandlerThread("p03-bound-images").apply {start()}
        val reader=ImageReader.newInstance(320,180,ImageFormat.YUV_420_888,4)
        val lock=Any(); val pixels=mutableListOf<JSONObject>(); val pcm=mutableListOf<YlNativePcmChunk>()
        val clock=AtomicReference<Pair<Long,Long>>()
        var recording=true
        reader.setOnImageAvailableListener({ r -> r.acquireLatestImage()?.use { image ->
            val value=JSONArray()
            for(i in 0..2) {val p=image.planes[i]; val x=if(i==0)160 else 80;val y=if(i==0)90 else 45
                value.put(p.buffer.get(y*p.rowStride+x*p.pixelStride).toInt() and 255)}
            val now=SystemClock.elapsedRealtimeNanos()/1000
            val pixel=JSONObject().put("value",value).put("format","yuv420-center").put("hostTimeUs",now)
            clock.get()?.let { if(now-it.second in 0..200_000)pixel.put("audioClockUs",it.first) }
            synchronized(lock) {if(recording)pixels.add(pixel)}
        } },Handler(thread.looper))
        val errors=java.util.Collections.synchronizedList(mutableListOf<YlFailureKind>())
        val state=AtomicReference<YlEngineSnapshot>()
        val position=java.util.concurrent.atomic.AtomicLong()
        val engine=YlNativeFallbackEngine(context,YlSessionIdentity("p03",row.getString("sessionId")),
            AndroidSourceMessage(AndroidSourceKind.FILE,file.absolutePath,AndroidStreamIntent.ON_DEMAND,AndroidMediaFormat.AUTOMATIC),
            AndroidLoadOptionsMessage(false,bufferStrategy=AndroidBufferStrategyMessage(AndroidBufferKind.AUTOMATIC),videoConstraints=AndroidVideoConstraintsMessage()),
            AndroidPlayerOptionsMessage(AndroidDecoderPolicy.HARDWARE_REQUIRED,AndroidAudioPolicy.APP_MANAGED,250),
            Dispatchers.Unconfined,observePcm={synchronized(lock){if(recording)pcm.add(it)}},
            observeAudioClock={clock.set(it to SystemClock.elapsedRealtimeNanos()/1000)},surfaceForOutput={reader.surface})
        engine.registerCallback {_,event -> when(event) {
            is YlEngineEvent.Failed -> errors.add(event.kind)
            is YlEngineEvent.Snapshot -> {state.set(event.value);position.set(event.value.timeline.positionMs)}
            is YlEngineEvent.Tick -> position.set(event.timeline.positionMs)
            else -> Unit
        } }
        suspend fun advance(condition:()->Boolean) {withTimeout(12000) {while(!condition()) {
            check(errors.isEmpty()) {errors.toString()};delay(10)
        } } }
        fun origin()=JSONObject().put("runId",row.getString("runId")).put("sessionId",row.getString("sessionId")).put("buildSha256",row.getString("buildSha256"))
        fun retain(phase:String,markers:List<Int>) {
            val windows=JSONArray()
            synchronized(lock) {
                assertTrue("Native audio clock was never observed",pixels.any {it.has("audioClockUs")})
                for(marker in markers) {
                    val start=if(phase=="play")marker*1_000_000L+250_000 else phase.removePrefix("seek-").toLong()*1000+100_000
                    val channels=case.getInt("channels"); val bytes=ByteBuffer.allocate(8192*channels*4).order(ByteOrder.LITTLE_ENDIAN)
                    var first:Long?=null
                    for(block in pcm) {
                        assertEquals(channels,block.channelCount);assertEquals(48000,block.sampleRate)
                        val input=ByteBuffer.wrap(block.data).order(ByteOrder.LITTLE_ENDIAN)
                        for(frame in 0 until block.data.size/(channels*2)) {
                            val pts=block.presentationTimeUs+frame*1_000_000L/block.sampleRate
                            for(channel in 0 until channels) {
                                val sample=input.short
                                if(pts>=start && pts<start+500_000 && bytes.hasRemaining()) {
                                    if(first==null)first=pts;bytes.putFloat(sample/32768f)
                                }
                            }
                        }
                    }
                    val raw=bytes.array().copyOf(bytes.position())
                    windows.put(origin().put("phase",phase).put("marker",marker).put("rate",48000).put("channels",channels)
                        .put("startUs",first ?: -1).put("frames",raw.size/(channels*4)).put("pcmSha256",sha(raw))
                        .put("pcmF32LE",Base64.encodeToString(raw,Base64.NO_WRAP)))
                }
                row.getJSONArray("phases").put(origin().put("phase",phase).put("pixels",JSONArray(pixels)).put("pcmWindows",windows))
            }
        }
        try {
            engine.prepare();engine.activate(output)
            // Actual APK identity covers the mapped JNI library as well as Kotlin code.
            val apk=File(instrumentation.context.applicationInfo.sourceDir)
            val mapped=File("/proc/self/maps").readLines().filter {it.contains("libyl_player_ffmpeg") || it.contains(apk.absolutePath)}
            check(mapped.isNotEmpty()) {"Native bridge not mapped"}
            row.put("loadedNativeMappings",JSONArray(mapped.map {it.substringAfterLast(' ')}.distinct()))
            engine.play()
            advance {synchronized(lock){pcm.isNotEmpty() && pixels.isNotEmpty()}}
            assertNotNull("Native audio clock was never observed",clock.get())
            advance {state.get()?.status==AndroidPlaybackStatus.COMPLETED}
            row.put("completed",true);retain("play",listOf(0,1,2,3))
            for(target in listOf(1250L,2250L,0L)) {
                engine.pause();synchronized(lock){recording=false};engine.seekTo(target)
                synchronized(lock){pcm.clear();pixels.clear();clock.set(null);recording=true}
                engine.play();advance {position.get()>=target+500}
                retain("seek-$target",listOf((target/1000).toInt()))
            }
            assertTrue(errors.toString(),errors.isEmpty());row.put("outcome","passed")
        } finally {
            row.put("lastState",state.get()?.status?.name).put("lastPositionMs",position.get())
            row.put("lastAudioClockUs",clock.get()?.first)
            synchronized(lock){row.put("capturedPCMBlocks",pcm.size).put("capturedImages",pixels.size)}
            engine.dispose().await();row.put("disposed",true).put("audioOutputClosed",engine.audioOutputClosed)
            output.release();reader.close();thread.quitSafely();thread.join(2000);file.delete()
        }
    }
}
