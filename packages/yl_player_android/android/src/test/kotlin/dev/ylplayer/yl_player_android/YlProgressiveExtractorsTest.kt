package dev.ylplayer.yl_player_android

import androidx.media3.common.DataReader
import androidx.media3.common.ParserException
import androidx.media3.extractor.DefaultExtractorInput
import java.io.ByteArrayInputStream
import java.io.File
import kotlin.test.*

class YlProgressiveExtractorsTest {
    private fun input(bytes: ByteArray): DefaultExtractorInput {
        val stream = ByteArrayInputStream(bytes)
        return DefaultExtractorInput(DataReader { buffer, offset, length -> stream.read(buffer, offset, length) }, 0, bytes.size.toLong())
    }
    private fun fixture(name: String): ByteArray {
        val relative = "packages/yl_player/example/assets/test_media/format_matrix/$name"
        val root = generateSequence(File(checkNotNull(System.getProperty("user.dir")))) { it.parentFile }
            .first { File(it, relative).isFile }
        return File(root, relative).readBytes()
    }
    @Test fun `actual MPEG1 PS cannot fall through to raw MP3 detection`() {
        val extractor = YlProgressiveExtractors.PsOwnedRoute()
        assertFailsWith<ParserException> { extractor.sniff(input(fixture("ps-avc-mp3.mpg"))) }
    }
    @Test fun `ordinary MP4 remains available to the standard extractors`() {
        val bytes = fixture("mp4-avc-aac.mp4")
        assertFalse(YlProgressiveExtractors.PsOwnedRoute().sniff(input(bytes)))
        androidx.media3.common.util.ParsableByteArray.setShouldEnforceLimitOnLegacyMethods(true)
        try { assertTrue(androidx.media3.extractor.mp4.Mp4Extractor().sniff(input(bytes))) }
        finally { androidx.media3.common.util.ParsableByteArray.setShouldEnforceLimitOnLegacyMethods(null) }
    }
    @Test fun `pack prefix without valid marker bits is not a PS route`() {
        val bytes = byteArrayOf(0, 0, 1, 0xba.toByte()) + ByteArray(18)
        assertFalse(YlProgressiveExtractors.PsOwnedRoute().sniff(input(bytes)))
    }
}
