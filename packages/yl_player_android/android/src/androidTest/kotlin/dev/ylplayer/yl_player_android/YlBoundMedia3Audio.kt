package dev.ylplayer.yl_player_android

import android.content.Context
import android.media.AudioTrack
import android.os.Handler
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.audio.*
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import java.nio.ByteBuffer

/** Test-only, clear local PCM observation. The default sink still writes the real AudioTrack.
 * Custom processors run after Media3 trimming. This capture permits only 1x, no silence skip,
 * PCM16 stereo controls; origin is the sink's first input PTS minus its renderer stream offset.
 * AudioTrack's fresh playback head, never ExoPlayer's extrapolated position, pairs with pixels.
 */
internal class YlBoundMedia3Audio(private val pcm: (YlNativePcmChunk) -> Unit, private val flushed: () -> Unit) {
    private val lock=Any()
    private var origin: Long?=null
    private var offset=0L
    private var frames=0L
    private var track: AudioTrack?=null
    private val tracks=mutableListOf<AudioTrack>()
    @Volatile var generation=0L; private set
    @Volatile var decoderIdentity: String?=null; private set
    /** True only after every real track created during this session has been released. */
    val closed get()=synchronized(lock){tracks.isNotEmpty() && tracks.all {it.state==AudioTrack.STATE_UNINITIALIZED}}
    /** Programme time at the freshly read playback head; unavailable across flush/release. */
    fun consumedUs(): Long?=synchronized(lock) {
        val start=origin ?: return@synchronized null
        val actual=track ?: return@synchronized null
        if(actual.state!=AudioTrack.STATE_INITIALIZED)return@synchronized null
        start+(actual.playbackHeadPosition.toLong() and 0xffffffffL)*1_000_000L/48000
    }
    /** Pass-through post-trim PCM processor, also exercised by the empty-drain regression. */
    internal val tap=object:BaseAudioProcessor() {
        override fun onConfigure(input: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
            check(input.encoding==C.ENCODING_PCM_16BIT && input.sampleRate==48000 && input.channelCount==2)
            return input
        }
        override fun queueInput(input: ByteBuffer) {
            // Pipeline.getOutput drains with the shared EMPTY_BUFFER after consuming input.
            if(!input.hasRemaining())return
            val data=ByteArray(input.remaining());input.duplicate().get(data)
            synchronized(lock) {
                check(data.size%4==0)
                val start=checkNotNull(origin)
                pcm(YlNativePcmChunk(data,48000,2,start+frames*1_000_000L/48000))
                frames+=data.size/4
            }
            replaceOutputBuffer(data.size).put(input).flip()
        }
        override fun onFlush() {synchronized(lock){frames=0}}
    }
    private fun invalidate() {
        synchronized(lock){origin=null;track=null;frames=0;generation++}
        flushed()
    }
    /** Uses product video renderers/codec selection and the default, real audio output. */
    fun factory(context: Context, observer: YlVideoOutputObserver)=object:YlOutputRenderersFactory(context,observer) {
        override fun buildAudioSink(context: Context, enableFloatOutput: Boolean, enableAudioOutputPlaybackParams: Boolean): AudioSink {
            check(observer.dashVideoFamily==null && !enableFloatOutput)
            @Suppress("DEPRECATION")
            val sink=DefaultAudioSink.Builder(context).setAudioProcessors(arrayOf(tap))
                .setEnableFloatOutput(false).setEnableAudioOutputPlaybackParameters(enableAudioOutputPlaybackParams)
                .setAudioTrackProvider { config, attributes, session, ctx ->
                    DefaultAudioSink.AudioTrackProvider.DEFAULT.getAudioTrack(config,attributes,session,ctx).also {
                        synchronized(lock){track=it;tracks.add(it)}
                    }
                }.build()
            return object:ForwardingAudioSink(sink) {
                override fun setOutputStreamOffsetUs(value: Long) {synchronized(lock){offset=value};super.setOutputStreamOffsetUs(value)}
                override fun handleBuffer(buffer: ByteBuffer, pts: Long, count: Int): Boolean {
                    synchronized(lock){if(origin==null && buffer.hasRemaining())origin=pts-offset}
                    return super.handleBuffer(buffer,pts,count)
                }
                override fun setPlaybackParameters(value: androidx.media3.common.PlaybackParameters) {
                    check(value.speed==1f && value.pitch==1f);super.setPlaybackParameters(value)
                }
                override fun setSkipSilenceEnabled(value: Boolean) {check(!value);super.setSkipSilenceEnabled(value)}
                override fun flush() {invalidate();super.flush()}
                override fun reset() {invalidate();super.reset()}
            }
        }
        override fun buildAudioRenderers(context: Context, extensionRendererMode: Int, mediaCodecSelector: MediaCodecSelector,
            enableDecoderFallback: Boolean, audioSink: AudioSink, eventHandler: Handler,
            eventListener: AudioRendererEventListener, out: ArrayList<Renderer>) {
            val listener=object:AudioRendererEventListener by eventListener {
                override fun onAudioDecoderInitialized(name: String, time: Long, duration: Long) {
                    decoderIdentity=name;eventListener.onAudioDecoderInitialized(name,time,duration)
                }
            }
            super.buildAudioRenderers(context,extensionRendererMode,mediaCodecSelector,enableDecoderFallback,audioSink,eventHandler,listener,out)
        }
    }
}
