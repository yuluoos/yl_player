package dev.ylplayer.yl_player_android

import androidx.media3.common.DataReader
import androidx.media3.common.ParserException
import androidx.media3.extractor.DefaultExtractorInput
import java.io.ByteArrayInputStream
import java.io.File
import kotlin.test.*
import dev.ylplayer.yl_player_android.pigeon.AndroidSourceKind
import dev.ylplayer.yl_player_android.pigeon.AndroidStreamIntent

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
        val extractor = YlProgressiveExtractors.OwnedRoute()
        assertFailsWith<ParserException> { extractor.sniff(input(fixture("ps-avc-mp3.mpg"))) }
    }
    @Test fun `AVI timing and FLV seek use the owned route`() {
        for(name in listOf("avi-avc-mp3.avi","flv-avc-mp3.flv")) {
            assertFailsWith<ParserException> { YlProgressiveExtractors.OwnedRoute().sniff(input(fixture(name))) }
        }
    }
    @Test fun `streaming FLV remains available to the standard extractor`() {
        val bytes = fixture("flv-avc-mp3.flv")
        for (intent in listOf(AndroidStreamIntent.AUTOMATIC, AndroidStreamIntent.LIVE)) {
            assertFalse(YlProgressiveExtractors.OwnedRoute(
                requiresOwnedFlvSeek(AndroidSourceKind.NETWORK, intent)).sniff(input(bytes)))
        }
        androidx.media3.common.util.ParsableByteArray.setShouldEnforceLimitOnLegacyMethods(true)
        try { assertTrue(androidx.media3.extractor.flv.FlvExtractor().sniff(input(bytes))) }
        finally { androidx.media3.common.util.ParsableByteArray.setShouldEnforceLimitOnLegacyMethods(null) }
        for (kind in AndroidSourceKind.values()) {
            assertFailsWith<ParserException> { YlProgressiveExtractors.OwnedRoute(
                requiresOwnedFlvSeek(kind, AndroidStreamIntent.ON_DEMAND)).sniff(input(bytes)) }
        }
    }
    @Test fun `ordinary MP4 remains available to the standard extractors`() {
        val bytes = fixture("mp4-avc-aac.mp4")
        assertFalse(YlProgressiveExtractors.OwnedRoute().sniff(input(bytes)))
        androidx.media3.common.util.ParsableByteArray.setShouldEnforceLimitOnLegacyMethods(true)
        try { assertTrue(androidx.media3.extractor.mp4.Mp4Extractor().sniff(input(bytes))) }
        finally { androidx.media3.common.util.ParsableByteArray.setShouldEnforceLimitOnLegacyMethods(null) }
    }
    @Test fun `pack prefix without valid marker bits is not a PS route`() {
        val bytes = byteArrayOf(0, 0, 1, 0xba.toByte()) + ByteArray(18)
        assertFalse(YlProgressiveExtractors.OwnedRoute().sniff(input(bytes)))
    }
}
