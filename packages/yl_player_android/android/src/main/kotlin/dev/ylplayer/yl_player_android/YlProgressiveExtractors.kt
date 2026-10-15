package dev.ylplayer.yl_player_android

import androidx.media3.common.ParserException
import androidx.media3.extractor.*
import dev.ylplayer.yl_player_android.pigeon.AndroidSourceKind
import dev.ylplayer.yl_player_android.pigeon.AndroidStreamIntent

/** Only finite, explicitly requested FLV needs the new seek route. Automatic
 * network sources retain the established streaming extractor. */
internal fun requiresOwnedFlvSeek(kind: AndroidSourceKind, intent: AndroidStreamIntent): Boolean =
    kind != AndroidSourceKind.NETWORK || intent == AndroidStreamIntent.ON_DEMAND

/** Route formats whose default extractor cannot preserve seek or video timing.
 * PS must not be mistaken for raw MP3; AVI needs verified presentation timing
 * and FLV needs indexed seeking. The owned demux uses the same managed source. */
internal class YlProgressiveExtractors(private val routeFlvForSeek: Boolean = true) : ExtractorsFactory {
    override fun createExtractors(): Array<Extractor> =
        arrayOf<Extractor>(OwnedRoute(routeFlvForSeek)) + DefaultExtractorsFactory().createExtractors()

    internal class OwnedRoute(private val routeFlvForSeek: Boolean = true) : Extractor {
        override fun sniff(input: ExtractorInput): Boolean {
            val header = ByteArray(12)
            val owned = try {
                input.peekFully(header, 0, header.size, true) && (
                    (header.copyOfRange(0,4).contentEquals("RIFF".toByteArray()) &&
                        header.copyOfRange(8,12).contentEquals("AVI ".toByteArray())) ||
                    (routeFlvForSeek && header[0] == 70.toByte() && header[1] == 76.toByte() && header[2] == 86.toByte() &&
                        header[3] == 1.toByte() && (header[4].toInt() and 0xfa) == 0))
            } catch (_: java.io.EOFException) { false }
            input.resetPeekPosition()
            if (owned || isProgramStreamPack(input)) throw ParserException.createForUnsupportedContainerFeature("Container requires the owned seek and video demux route.")
            return false
        }
        override fun init(output: ExtractorOutput) = error("Owned routing probe cannot be selected")
        override fun read(input: ExtractorInput, seekPosition: PositionHolder): Int = error("Owned routing probe cannot read samples")
        override fun seek(position: Long, timeUs: Long) = Unit
        override fun release() = Unit

        /** Complete MPEG-1/2 pack markers and MPEG-2 stuffing, using at most 21 bytes. */
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
