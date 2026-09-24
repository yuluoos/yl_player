package dev.ylplayer.yl_player_android

import java.io.ByteArrayOutputStream

/** Checks codecs before decoder exposure; keeps audio/video timestamp histories separate. */
internal class YlRtmpFlvStream {
    companion object { val HEADER = byteArrayOf(70,76,86,1,5,0,0,0,9,0,0,0,0) }
    private var declared = false
    private var videoConfiguration: ByteArray? = null
    private var audioConfiguration: ByteArray? = null
    fun header(): ByteArray {
        if (!videoConfigured) rtmpInvalid()
        declared = true
        return HEADER.copyOf().apply { this[4] = (if (audioConfigured) 5 else 1).toByte() }
    }
    var videoConfigured = false; private set
    var audioConfigured = false; private set
    private var nalLengthSize = 4
    private val times = mutableMapOf<Int, Long>()
    fun accept(message: YlRtmpMessage): ByteArray? {
        val p = message.payload
        if (message.type !in setOf(8,9)) return null
        if (p.isEmpty()) rtmpInvalid()
        var nextNalLength: Int? = null
        val configuration = p.size >= 2 && p[1].toInt() == 0
        if (message.type == 9) {
            if ((p[0].toInt() and 0x80) != 0 || (p[0].toInt() and 15) != 7) throw YlRtmpException(YlFailureKind.CONTAINER_UNSUPPORTED)
            if (p.size < 5 || (p[0].toInt() ushr 4 and 7) !in 1..5) rtmpInvalid()
            when (p[1].toInt() and 255) {
                0 -> nextNalLength = validateAvc(p)
                1 -> {
                    if (!videoConfigured || p.size <= 5 + nalLengthSize) rtmpInvalid()
                    var at = 5
                    while (at < p.size) {
                        if (p.size - at < nalLengthSize) rtmpInvalid()
                        var size = 0L
                        repeat(nalLengthSize) { size = (size shl 8) or (p[at++].toLong() and 255) }
                        if (size == 0L || size > p.size - at) rtmpInvalid()
                        at += size.toInt()
                    }
                }
                2 -> return null
                else -> rtmpInvalid()
            }
        } else {
            if ((p[0].toInt() ushr 4 and 15) != 10) throw YlRtmpException(YlFailureKind.CONTAINER_UNSUPPORTED)
            if (p.size < 3) rtmpInvalid()
            when (p[1].toInt() and 255) {
                0 -> {
                    // AudioSpecificConfig: standard AAC object types (including HE extension).
                    if (p.size < 4) rtmpInvalid()
                    val objectType = p[2].toInt() ushr 3 and 31
                    if (objectType !in setOf(1,2,3,4,5,29)) throw YlRtmpException(YlFailureKind.CONTAINER_UNSUPPORTED)
                }
                1 -> if (!audioConfigured) rtmpInvalid()
                else -> rtmpInvalid()
            }
        }
        val prior = times[message.type]
        if (prior != null && (message.timestamp + 2000 < prior || (prior > 0xffff0000L && message.timestamp < 65536)))
            throw YlRtmpException(YlFailureKind.RTMP_DISCONNECTED, true)
        // Validate codec structure first, then detect a timestamp epoch boundary. A valid
        // config accompanying reset/wrap belongs to a fresh demux epoch. Only a change in a
        // continuous, already declared epoch is an unsupported track-layout transition.
        if (configuration) {
            val previous = if (message.type == 9) videoConfiguration else audioConfiguration
            if (declared && (previous == null || !previous.contentEquals(p)))
                throw YlRtmpException(YlFailureKind.RTMP_TRACK_LAYOUT_CHANGED)
            if (message.type == 9) {
                videoConfiguration = p; videoConfigured = true; nalLengthSize = checkNotNull(nextNalLength)
            } else { audioConfiguration = p; audioConfigured = true }
        }
        times[message.type] = maxOf(prior ?: 0, message.timestamp)
        return ByteArrayOutputStream(p.size + 15).apply {
            write(message.type); u24(p.size); u24(message.timestamp.toInt()); write((message.timestamp ushr 24).toInt())
            u24(0); write(p); u32((p.size + 11).toLong())
        }.toByteArray()
    }
    private fun validateAvc(p: ByteArray): Int {
        if (p.size < 12 || p[5].toInt() != 1) rtmpInvalid()
        val nextNalLength = (p[9].toInt() and 3) + 1
        if (nextNalLength == 3) rtmpInvalid()
        var index = 11
        fun nal() {
            if (index + 2 > p.size) rtmpInvalid()
            val n = (p[index].toInt() and 255 shl 8) or (p[index + 1].toInt() and 255)
            index += 2
            if (n == 0 || n > p.size - index) rtmpInvalid()
            index += n
        }
        val sps = p[10].toInt() and 31
        if (sps == 0) rtmpInvalid()
        repeat(sps) { nal() }
        if (index >= p.size) rtmpInvalid()
        val pps = p[index++].toInt() and 255
        if (pps == 0) rtmpInvalid()
        repeat(pps) { nal() }
        return nextNalLength
    }
}
