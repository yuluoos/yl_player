package dev.ylplayer.yl_player_android

import androidx.media3.common.ParserException
import androidx.media3.extractor.*

/** Detect PS before a raw-audio extractor can mistake its embedded MP3 for the
 * entire programme. The ordinary container failure activates the owned demux;
 * all probing uses the existing managed DataSource and credentials. */
internal class YlProgressiveExtractors : ExtractorsFactory {
    override fun createExtractors(): Array<Extractor> =
        arrayOf<Extractor>(PsOwnedRoute()) + DefaultExtractorsFactory().createExtractors()

    internal class PsOwnedRoute : Extractor {
        override fun sniff(input: ExtractorInput): Boolean {
            if (isProgramStreamPack(input)) throw ParserException.createForUnsupportedContainerFeature("MPEG-PS requires the owned video demux route.")
            return false
        }
        override fun init(output: ExtractorOutput) = error("PS routing probe cannot be selected")
        override fun read(input: ExtractorInput, seekPosition: PositionHolder): Int = error("PS routing probe cannot read samples")
        override fun seek(position: Long, timeUs: Long) = Unit
        override fun release() = Unit

        /** Complete MPEG-1/2 pack markers and MPEG-2 stuffing, using at most21 bytes. */
        private fun isProgramStreamPack(input: ExtractorInput): Boolean {
            val bytes = ByteArray(21)
            fun at(index: Int) = bytes[index].toInt() and 255
            return try {
                if (!input.peekFully(bytes, 0, 12, true)) return false
                if (at(0) != 0 || at(1) != 0 || at(2) != 1 || at(3) != 0xba) return false
                if (at(4) and 0xf1 == 0x21) return at(6) and 1 == 1 && at(8) and 1 == 1 &&
                    at(9) and 0x80 == 0x80 && at(11) and 1 == 1
                if (!input.peekFully(bytes, 12, 2, true)) return false
                if (at(4) and 0xc4 != 0x44 || at(6) and 4 != 4 || at(8) and 4 != 4 ||
                    at(9) and 1 != 1 || at(12) and 3 != 3 || at(13) and 0xf8 != 0xf8) return false
                val stuffing = at(13) and 7
                if (!input.peekFully(bytes, 14, stuffing, true)) return false
                (14 until 14 + stuffing).all { at(it) == 255 }
            } catch (_: java.io.EOFException) { false }
        }
    }
}
