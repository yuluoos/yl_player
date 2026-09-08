package dev.ylplayer.yl_player_android

import android.content.*
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.*

internal enum class YlAudioFocusChange { GAIN, LOSS_TRANSIENT, DUCK, LOSS, NOISY }
internal fun interface YlAudioFocusParticipant { fun onAudioFocus(change: YlAudioFocusChange) }
internal interface YlAudioFocusDriver {
    fun request(listener: (YlAudioFocusChange) -> Unit): Boolean
    fun abandon()
    fun registerNoisy(listener: () -> Unit)
    fun unregisterNoisy()
}
/** Main-looper owner shared by all Flutter registrations. Candidates never participate. */
internal class YlAudioFocusCoordinator(
    private val driver: YlAudioFocusDriver,
    private val onFailure: (Throwable) -> Unit = { YlFailureMapper().record(it) },
) {
    private val participants = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<YlAudioFocusParticipant, Boolean>())
    private var generation = 0L
    private var focusGranted = false
    // Joining playback inherits the current request's policy before its first volume/play call.
    var volumeMultiplier = 1.0
        private set
    fun acquire(participant: YlAudioFocusParticipant): Boolean {
        if (participants.isNotEmpty() && !focusGranted) return false
        if (participant in participants) return true
        if (participants.isEmpty()) {
            val token = ++generation
            if (!driver.request { change -> if (token == generation) dispatch(change) }) { generation++; return false }
            try { driver.registerNoisy { if (token == generation) dispatch(YlAudioFocusChange.NOISY) } }
            catch (error: Throwable) { generation++; runCatching { driver.abandon() }.exceptionOrNull()?.let(::report); throw error }
        }
        focusGranted = true
        participants += participant
        return true
    }
    fun release(participant: YlAudioFocusParticipant) {
        if (!participants.remove(participant) || participants.isNotEmpty()) return
        retireRequest()
    }
    private fun retireRequest() {
        generation++
        focusGranted = false
        volumeMultiplier = 1.0
        // Cleanup must not make a committed session handoff fallible or strand other resources.
        runCatching { driver.unregisterNoisy() }.exceptionOrNull()?.let(::report)
        runCatching { driver.abandon() }.exceptionOrNull()?.let(::report)
    }
    private fun report(error: Throwable) { runCatching { onFailure(error) } }
    private fun dispatch(change: YlAudioFocusChange) {
        if (change == YlAudioFocusChange.LOSS) {
            val lost = participants.toList()
            participants.clear()
            // Permanent loss ends ownership irrevocably, independent of queued pause/Play intent.
            // Invalidate this request's listener before any participant can reacquire.
            retireRequest()
            lost.forEach { it.onAudioFocus(change) }
            return
        }
        when (change) {
            YlAudioFocusChange.GAIN -> { focusGranted = true; volumeMultiplier = 1.0 }
            YlAudioFocusChange.LOSS_TRANSIENT -> { focusGranted = false; volumeMultiplier = 1.0 }
            YlAudioFocusChange.DUCK -> volumeMultiplier = 0.2
            else -> Unit
        }
        participants.toList().forEach { if (it in participants) it.onAudioFocus(change) }
    }
}

/** Framework calls are main-owned. Keep application context only, independent of registry teardown. */
@Suppress("DEPRECATION")
internal class YlAndroidAudioFocusDriver(
    private val context: Context,
    private val apiLevel: Int = Build.VERSION.SDK_INT,
    private val handler: Handler = Handler(Looper.getMainLooper()),
) : YlAudioFocusDriver {
    private var manager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null
    private var focusListener: AudioManager.OnAudioFocusChangeListener? = null
    private var receiver: BroadcastReceiver? = null
    override fun request(listener: (YlAudioFocusChange) -> Unit): Boolean {
        check(focusListener == null)
        val audio = (context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager) ?: return false
        val callback = AudioManager.OnAudioFocusChangeListener { change ->
            val typed = when (change) {
                AudioManager.AUDIOFOCUS_GAIN -> YlAudioFocusChange.GAIN
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> YlAudioFocusChange.LOSS_TRANSIENT
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK ->
                    if (apiLevel >= 26) YlAudioFocusChange.LOSS_TRANSIENT else YlAudioFocusChange.DUCK
                AudioManager.AUDIOFOCUS_LOSS -> YlAudioFocusChange.LOSS
                else -> null
            }
            typed?.let { handler.post { listener(it) } }
        }
        val request = if (apiLevel >= 26) AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
            // Modern convenience mode promises pause on CAN_DUCK; legacy devices use manual ducking.
            .setWillPauseWhenDucked(true)
            .setAcceptsDelayedFocusGain(false)
            .setOnAudioFocusChangeListener(callback, handler)
            .build() else null
        val granted = if (request != null) audio.requestAudioFocus(request)
            else audio.requestAudioFocus(callback, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        if (granted != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) return false
        manager = audio; focusRequest = request; focusListener = callback
        return true
    }
    override fun abandon() {
        val listener = focusListener ?: return
        val request = focusRequest
        focusListener = null; focusRequest = null
        val audio = manager; manager = null
        if (apiLevel >= 26 && request != null) audio?.abandonAudioFocusRequest(request)
        else audio?.abandonAudioFocus(listener)
    }
    override fun registerNoisy(listener: () -> Unit) {
        if (receiver != null) return
        val next = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) listener()
            }
        }
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (apiLevel >= 33) context.registerReceiver(next, filter, null, handler, Context.RECEIVER_NOT_EXPORTED)
        else context.registerReceiver(next, filter, null, handler)
        receiver = next
    }
    override fun unregisterNoisy() {
        val previous = receiver ?: return
        receiver = null
        context.unregisterReceiver(previous)
    }
}

/** Android has one app process audio policy even with several Flutter engines. */
internal object YlSharedAudioFocus {
    private var coordinator: YlAudioFocusCoordinator? = null
    fun get(context: Context): YlAudioFocusCoordinator = coordinator ?: YlAudioFocusCoordinator(
        YlAndroidAudioFocusDriver(context.applicationContext ?: context)).also { coordinator = it }
}
