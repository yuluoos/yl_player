package dev.ylplayer.yl_player_android

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import org.junit.Assert.*
import dev.ylplayer.yl_player_android.pigeon.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Media3 drains a processor with EMPTY_BUFFER; this must neither emit PCM nor copy onto itself. */
class YlBoundMedia3AudioInstrumentedTest {
    @Test fun sourceBindingRequiresManagedPolicyAndExactRunLocator() {
        val url="http://127.0.0.1:1234/case.mkv"
        val source=AndroidSourceMessage(AndroidSourceKind.NETWORK,url,AndroidStreamIntent.ON_DEMAND,AndroidMediaFormat.AUTOMATIC,
            AndroidHttpRequestMessage(mapOf("x-yl-bound-run" to "run"),emptyMap()),AndroidNetworkPolicyMessage(AndroidNetworkPolicyKind.MANAGED))
        fun matches(s:AndroidSourceMessage)=YlBoundFlutterProbe.sourceMatches(s,"/tmp/case.mkv",url,"http","run")
        assertTrue(matches(source))
        assertFalse(matches(source.copy(networkPolicy=AndroidNetworkPolicyMessage(AndroidNetworkPolicyKind.PLATFORM_DEFAULT))))
        assertFalse(matches(source.copy(request=AndroidHttpRequestMessage(mapOf("x-yl-bound-run" to "wrong"),emptyMap()))))
        assertFalse(matches(source.copy(locator="http://127.0.0.1:1235/case.mkv")))
        assertFalse(matches(source.copy(kind=AndroidSourceKind.FILE,locator="/tmp/case.mkv")))
    }

    @Test fun monoTapPreservesActualBytesChannelsAndFramePositions() {
        val chunks=mutableListOf<YlNativePcmChunk>()
        val observed=YlBoundMedia3Audio(chunks::add,{})
        observed.tap.configure(AudioProcessor.AudioFormat(48000,1,C.ENCODING_PCM_16BIT))
        observed.tap.flush()
        observed.javaClass.getDeclaredField("origin").apply {isAccessible=true}.set(observed,1000L)
        val input=ByteBuffer.allocateDirect(4).order(ByteOrder.LITTLE_ENDIAN).putShort(123).putShort(-456)
        input.flip();observed.tap.queueInput(input)
        assertEquals(1,chunks.single().channelCount)
        assertEquals(1000L,chunks.single().presentationTimeUs)
        assertArrayEquals(byteArrayOf(123,0,56,-2),chunks.single().data)
        assertEquals(4,observed.tap.output.remaining())
        observed.tap.queueInput(AudioProcessor.EMPTY_BUFFER)
        assertEquals(1,chunks.size)
    }
    @Test fun emptyDrainDoesNotInventSamplesOrRequireAnOrigin() {
        val chunks=mutableListOf<YlNativePcmChunk>()
        val observed=YlBoundMedia3Audio(chunks::add,{})
        observed.tap.configure(AudioProcessor.AudioFormat(48000,2,C.ENCODING_PCM_16BIT))
        observed.tap.flush()
        observed.tap.queueInput(AudioProcessor.EMPTY_BUFFER)
        assertEquals(0,chunks.size)
        assertEquals(0,observed.tap.output.remaining())
    }
}
