package dev.ylplayer.yl_player_android

/** Canonicalize Annex-B start codes at the Android codec boundary. All NAL
 * payloads, including repeated parameter sets and SEI, remain byte-identical. */
internal fun canonicalAnnexB(data: ByteArray): ByteArray {
    fun prefix(index: Int): Int {
        if (index + 2 >= data.size || data[index] != 0.toByte() || data[index+1] != 0.toByte()) return 0
        if (data[index+2] == 1.toByte()) return 3
        if (index + 3 < data.size && data[index+2] == 0.toByte() && data[index+3] == 1.toByte()) return 4
        return 0
    }
    var index = 0
    var added = 0
    while (index < data.size) {
        val length = prefix(index)
        if (length == 3) added++
        index += if (length == 0) 1 else length
    }
    if (added == 0) return data
    val result = ByteArray(Math.addExact(data.size, added))
    index = 0
    var output = 0
    while (index < data.size) {
        val length = prefix(index)
        if (length == 3) result[output++] = 0
        val count = if (length == 0) 1 else length
        data.copyInto(result, output, index, index + count)
        index += count; output += count
    }
    return result
}
