package dev.ylplayer.yl_player_android

import android.app.Activity
import android.content.Context
import android.os.SystemClock
import android.util.Base64
import dev.ylplayer.yl_player_android.pigeon.*
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.URI
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject

/** Opt-in debug acceptance bridge only. Public Flutter APIs own playback and the real texture.
 * No surface substitution, alternate player, license capture or release-build endpoint exists.
 * Reflection is confined to installing observation factories before any public player exists.
 */
class YlBoundFlutterProbe private constructor(private val flutter: FlutterEngine, private val context: Context,
    private val plan: JSONObject) {
    private val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main)
    private val channel=MethodChannel(flutter.dartExecutor.binaryMessenger,"yl_player_example/debug/bound_av")
    private val apk=File(context.applicationInfo.sourceDir)
    private val output=File(context.filesDir,"p03-public-${plan.getString("runId")}")
    private var capture: Capture?=null
    private var nextCase=0
    private var verified=false
    init {
        check(output.mkdir()) {"Evidence run already exists"}
        try {
            check(plan.getString("platform")=="android" && plan.getString("artifactKind")=="android-public-flutter-debug-apk")
            check(fileHash(apk)==plan.getString("buildSha256") && plan.getString("testSha256")==plan.getString("buildSha256")) {"Installed APK identity mismatch"}
            val plugin=checkNotNull(flutter.plugins.get(YlPlayerAndroidPlugin::class.java))
            val registry=field(plugin,"registry")!!
            check((field(registry,"players") as Map<*,*>).isEmpty())
            val views=field(plugin,"protectedViews") as YlProtectedViewRegistry
            val factory=YlMedia3SessionFactory(context,protectedViews=views,
                createFallback={id,source,load,player->observe(id,source,load,player,false)},
                createEngine={id,source,load,player->observe(id,source,load,player,true)})
            registry.javaClass.getDeclaredField("sessionFactory").apply {isAccessible=true}.set(registry,factory)
            verified=true
        } catch(error: Throwable) {finish(false,error.toString())}
        channel.setMethodCallHandler {call,reply->scope.launch {
            try {
                check(verified) {"Runtime identity was not verified"}
                val args=call.arguments as? Map<*,*> ?: emptyMap<Any,Any>()
                val current=capture
                if(call.method !in listOf("plan","begin","finish"))check(args["sessionId"]==current?.id?.sessionId) {"Public/native session mismatch"}
                val value:Any?=when(call.method) {
                    "plan" -> jsonMap(plan)
                    "begin" -> {
                        check(capture==null)
                        val item=plan.getJSONArray("planned").getJSONObject(nextCase)
                        check(item.getString("caseId")==args["caseId"])
                        val file=File(args["path"] as String)
                        check(file.isFile && file.length() in 1..16*1024*1024 && hash(file.readBytes())==item.getString("mediaHash"))
                        capture=Capture(item,file,args["locator"] as? String ?: file.absolutePath);null
                    }
                    "bind" -> {checkNotNull(current).publicId=args["sessionId"] as String;null}
                    "clock" -> checkNotNull(current).sampleClock()
                    "pixel" -> {checkNotNull(current).pixel((args["token"] as Number).toLong(),args["rgb"] as List<*>)}
                    "retain" -> {checkNotNull(current).retain(args["phase"] as String);null}
                    "seekPhase" -> {checkNotNull(current).beginSeek((args["targetMs"] as Number).toLong());null}
                    "awaitPhase" -> {withTimeout(5000){while(!checkNotNull(current).phaseReady)delay(5)};null}
                    "finishCase" -> {
                        val c=checkNotNull(current);val a=checkNotNull(c.active)
                        try { withTimeout(5000){while(!a.disposed || !a.audioClosed())delay(5)} }
                        catch(error: Throwable) {
                            c.row.put("releaseObserved",a.disposed).put("audioClosedObserved",a.audioClosed())
                                .put("releaseFailure",a.releaseFailure).put("observedEngine",if(a.media3)"media3" else "native-fallback")
                            throw error
                        }
                        c.finish(args["lifecycle"] as Map<*,*>)
                        if(c.item.optString("transport")=="http")c.row.put("networkReceipt",JSONObject(args["networkReceipt"] as Map<*,*>))
                        File(output,"rows.jsonl").appendText(c.row.toString()+"\n")
                        nextCase++;capture=null;null
                    }
                    "finish" -> {finish(args["passed"]==true,args["failure"] as? String);null}
                    else -> error("Unknown observation method")
                }
                reply.success(value)
            } catch(error: Throwable) {reply.error("bound.observation",error.toString(),null)}
        } }
    }
    /** Factories create the same product engines; no recovery or decoder admission is forced. */
    private fun observe(id:YlSessionIdentity,source:AndroidSourceMessage,load:AndroidLoadOptionsMessage,
        player:AndroidPlayerOptionsMessage,media3:Boolean):YlPlaybackEngineAdapter {
        val c=checkNotNull(capture)
        check(sourceMatches(source,c.file.absolutePath,c.locator,c.item.optString("transport","file"),plan.getString("runId")))
        check(fileHash(c.file)==c.item.getString("mediaHash"));c.row.put("sourceVerified",true)
        check(c.id==null || c.id==id);c.id=id
        val a=Attempt(c,media3);c.active=a;c.clear()
        val engine=if(media3)YlMedia3Engine(context,id,source,load,player,renderersFactory=a.audio::factory)
        else YlNativeFallbackEngine(context,id,source,load,player,
            observePcm={synchronized(c.lock){if(c.active===a)c.pcm.add(it)}},
            observeAudioClock={synchronized(c.lock){if(c.active===a)c.clock=it to now()}})
        a.engine=engine
        return object:YlPlaybackEngineAdapter by engine {
            override fun registerCallback(callback:(YlSessionIdentity,YlEngineEvent)->Unit) {
                engine.registerCallback {identity,event->
                    if(c.active===a && event is YlEngineEvent.Snapshot) {
                        c.snapshot=event.value
                        if(event.value.status==AndroidPlaybackStatus.COMPLETED)c.completed=true
                    }
                    callback(identity,event)
                }
            }
            override suspend fun seekTo(positionMs:Long) {
                engine.seekTo(positionMs)
                if(!media3)c.flushed()
            }
            override fun dispose():Deferred<Unit> = try {
                engine.dispose().also {it.invokeOnCompletion {error->
                    if(error==null)a.disposed=true else a.releaseFailure=error.toString()
                }}
            } catch(error: Throwable) {a.releaseFailure=error.toString();throw error}
        }
    }
    private inner class Attempt(val c:Capture,val media3:Boolean) {
        lateinit var engine:YlPlaybackEngineAdapter
        @Volatile var disposed=false
        @Volatile var releaseFailure:String?=null
        val audio=YlBoundMedia3Audio({synchronized(c.lock){if(c.active===this)c.pcm.add(it)}},
            {if(c.active===this)c.flushed()})
        fun audioClosed()=if(media3)audio.closed else (engine as YlNativeFallbackEngine).audioOutputClosed
    }
    private inner class Capture(val item:JSONObject,val file:File,val locator:String) {
        val lock=Any();val pcm=mutableListOf<YlNativePcmChunk>();val pixels=mutableListOf<JSONObject>()
        var id:YlSessionIdentity?=null
        @Volatile var active:Attempt?=null
        @Volatile var snapshot:YlEngineSnapshot?=null
        @Volatile var completed=false
        @Volatile var phaseReady=true
        private var seeking=false
        var publicId:String?=null
        var clock:Pair<Long,Long>?=null
        private var token=0L
        private var pending:Triple<Long,Long,Long>?=null
        val row=JSONObject().put("schema",1).put("platform","android").put("caseId",item.getString("caseId"))
            .put("runId",plan.getString("runId")).put("buildSha256",plan.getString("buildSha256"))
            .put("testSha256",plan.getString("testSha256")).put("mediaHash",item.getString("mediaHash"))
            .put("transport",item.optString("transport","file")).put("networkPolicy",if(item.optString("transport")=="http")"managed" else "file")
            .put("identityVerified",true).put("audioClockMethod","audiotrack-playback-head")
            .put("publicApi","YlPlayerController/YlPlayerView").put("pixelSource","flutter-repaint-boundary")
            .put("runtime",android.os.Build.FINGERPRINT).put("outcome","failed").put("phases",JSONArray())
        fun clear()=synchronized(lock){pcm.clear();pixels.clear();clock=null;pending=null}
        fun flushed()=synchronized(lock){clear();if(seeking){phaseReady=true;seeking=false}}
        fun beginSeek(target:Long)=synchronized(lock) {
            val expected=plan.getJSONArray("phases").getJSONObject(row.getJSONArray("phases").length()).getString("phase")
            check(expected=="seek-$target");phaseReady=false;seeking=true;pending=null
        }
        /** Clock token can pair with exactly one screenshot, within 200 ms of the real head read. */
        fun sampleClock():Long {
            val a=checkNotNull(active)
            val observed=if(a.media3)a.audio.consumedUs()?.let {it to now()} else synchronized(lock){clock}
            return synchronized(lock) {
                token++
                pending=observed?.takeIf {now()-it.second in 0..200_000}?.let {Triple(token,it.first,it.second)}
                token
            }
        }
        /** Returns only the actual consumption paired with this screenshot, never public position. */
        fun pixel(value:Long,rgb:List<*>)=synchronized(lock) {
            check(rgb.size==3 && rgb.all {it is Int && it in 0..255})
            val stamp=pending;pending=null
            val pixel=JSONObject().put("format","rgb8").put("value",JSONArray(rgb)).put("hostTimeUs",now())
            val consumed=stamp?.takeIf {it.first==value && now()-it.third in 0..200_000}?.second
            if(consumed!=null)pixel.put("audioClockUs",consumed)
            pixels.add(pixel);check(pixels.size<=1000)
            consumed
        }
        fun origin()=JSONObject().put("runId",plan.getString("runId")).put("buildSha256",plan.getString("buildSha256")).put("sessionId",checkNotNull(id).sessionId)
        fun retain(phase:String)=synchronized(lock) {
            val expected=plan.getJSONArray("phases").getJSONObject(row.getJSONArray("phases").length())
            check(expected.getString("phase")==phase)
            val windows=JSONArray();val markers=expected.getJSONArray("markers")
            for(i in 0 until markers.length()) {
                val marker=markers.getInt(i)
                val start=if(phase=="play")marker*1_000_000L+250_000 else phase.removePrefix("seek-").toLong()*1000+100_000
                val channels=checkNotNull(pcm.firstOrNull()).channelCount
                check(channels==item.getInt("channels") || item.optInt("sourceChannels")==1 && channels in 1..2)
                val bytes=ByteBuffer.allocate(8192*channels*4).order(ByteOrder.LITTLE_ENDIAN);var first:Long?=null
                for(block in pcm) {
                    check(block.sampleRate==48000 && block.channelCount==channels)
                    val input=ByteBuffer.wrap(block.data).order(ByteOrder.LITTLE_ENDIAN)
                    for(frame in 0 until block.data.size/(2*channels)) {
                        val pts=block.presentationTimeUs+frame*1_000_000L/48000
                        repeat(channels) {val sample=input.short
                            if(pts>=start && pts<start+500_000 && bytes.hasRemaining()) {if(first==null)first=pts;bytes.putFloat(sample/32768f)}
                        }
                    }
                }
                val raw=bytes.array().copyOf(bytes.position())
                windows.put(origin().put("phase",phase).put("marker",marker).put("rate",48000).put("channels",channels)
                    .put("frames",raw.size/(4*channels)).put("startUs",first ?: -1).put("pcmSha256",hash(raw)).put("pcmF32LE",Base64.encodeToString(raw,Base64.NO_WRAP)))
            }
            row.getJSONArray("phases").put(origin().put("phase",phase).put("pixels",JSONArray(pixels)).put("pcmWindows",windows))
        }
        fun finish(lifecycle:Map<*,*>) {
            val a=checkNotNull(active)
            check(publicId==checkNotNull(id).sessionId && completed && a.disposed && a.audioClosed())
            check(listOf("created","ready","firstFrame","completed","disposed").all {lifecycle[it]==true})
            row.put("sessionId",id!!.sessionId).put("publicSessionId",publicId).put("publicLifecycle",JSONObject(lifecycle))
                .put("engine",if(a.media3)"media3" else "native-fallback").put("decoderMode",snapshot?.decoderMode?.name)
                .put("decoderIdentity",snapshot?.decoderIdentity).put("audioDecoderIdentity",a.audio.decoderIdentity)
                .put("completed",completed).put("disposed",a.disposed).put("audioOutputClosed",a.audioClosed()).put("outcome","passed")
        }
    }
    private fun finish(passed:Boolean,failure:String?) {
        val unchanged=fileHash(apk)==plan.getString("buildSha256")
        if(!passed)capture?.let {File(output,"rows.jsonl").appendText(it.row.put("failure",failure).toString()+"\n")}
        File(output,"status.json").writeText(JSONObject().put("passed",passed && nextCase==plan.getJSONArray("planned").length() && unchanged)
            .put("runId",plan.getString("runId")).put("identityVerified",verified).put("artifactsUnchanged",unchanged).put("failure",failure).toString())
    }
    companion object {
        /** Validates the actual source without changing product routing. */
        internal fun sourceMatches(source:AndroidSourceMessage,path:String,locator:String,transport:String,run:String):Boolean {
            if(source.drm!=null || source.locator!=locator)return false
            if(transport=="file")return source.kind==AndroidSourceKind.FILE && locator==path
            if(transport!="http" || source.kind!=AndroidSourceKind.NETWORK ||
                source.networkPolicy?.kind!=AndroidNetworkPolicyKind.MANAGED || source.request?.headers?.get("x-yl-bound-run")!=run)return false
            val uri=runCatching { URI(locator) }.getOrNull() ?: return false
            return uri.scheme=="http" && uri.host=="127.0.0.1" && uri.port>0 && uri.userInfo==null &&
                uri.rawQuery==null && uri.rawFragment==null && uri.path=="/"+File(path).name
        }

        /** Called only when this opt-in class exists and the host supplies a frozen plan. */
        @JvmStatic fun register(engine:FlutterEngine,context:Context) {
            val encoded=(context as? Activity)?.intent?.getStringExtra("p03Plan") ?: return
            YlBoundFlutterProbe(engine,context.applicationContext,JSONObject(String(Base64.decode(encoded,Base64.DEFAULT))))
        }
        private fun field(owner:Any,name:String)=owner.javaClass.getDeclaredField(name).apply {isAccessible=true}.get(owner)
        private fun now()=SystemClock.elapsedRealtimeNanos()/1000
        /** Hash the installed APK with bounded memory; Flutter debug APKs can exceed the app heap. */
        private fun fileHash(file:File):String {
            val digest=MessageDigest.getInstance("SHA-256")
            file.inputStream().use {input->val buffer=ByteArray(1024*1024)
                while(true) {val count=input.read(buffer);if(count<0)break;digest.update(buffer,0,count)}
            }
            return digest.digest().joinToString(""){"%02x".format(it)}
        }
        private fun hash(bytes:ByteArray)=MessageDigest.getInstance("SHA-256").digest(bytes).joinToString(""){"%02x".format(it)}
        private fun jsonMap(value:JSONObject):Map<String,Any?> = value.keys().asSequence().associateWith { key->convert(value.get(key)) }
        private fun convert(value:Any?):Any?=when(value) {is JSONObject->jsonMap(value);is JSONArray->(0 until value.length()).map {convert(value.get(it))};JSONObject.NULL->null;else->value}
    }
}
