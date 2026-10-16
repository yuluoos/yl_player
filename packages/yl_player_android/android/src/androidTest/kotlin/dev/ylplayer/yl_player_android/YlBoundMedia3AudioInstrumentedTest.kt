package dev.ylplayer.yl_player_android

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import org.junit.Assert.assertEquals
import org.junit.Test

/** Media3 drains a processor with EMPTY_BUFFER; this must neither emit PCM nor copy onto itself. */
class YlBoundMedia3AudioInstrumentedTest {
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
