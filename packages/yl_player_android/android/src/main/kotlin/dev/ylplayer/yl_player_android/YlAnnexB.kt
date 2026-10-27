package dev.ylplayer.yl_player_android

/** Canonicalize Annex-B start codes at the Android codec boundary. All NAL
 * payloads, including repeated parameter sets and SEI, remain byte-identical. */
internal fun canonicalAnnexB(data: ByteArray): ByteArray {
    var shortPrefixes: ArrayList<Int>? = null
    var index = 2
    while (index < data.size) {
        // A byte other than 0/1 cannot end a prefix, or be either of the two
        // zeroes before its end. Skip those impossible endings in one step.
        if (data[index].toInt() and 0xfe != 0) {
            index += 3
        } else if (data[index] == 1.toByte() && data[index - 1] == 0.toByte() && data[index - 2] == 0.toByte()) {
            if (index == 2 || data[index - 3] != 0.toByte()) {
                (shortPrefixes ?: ArrayList<Int>().also { shortPrefixes = it }).add(index - 2)
            }
            index += 3
        } else {
            index++
        }
    }
    val prefixes = shortPrefixes ?: return data
    val result = ByteArray(Math.addExact(data.size, prefixes.size))
    var payloadStart = 0
    var output = 0
    for (prefix in prefixes) {
        data.copyInto(result, output, payloadStart, prefix)
        output += prefix - payloadStart
        result[output++] = 0
        payloadStart = prefix
    }
    data.copyInto(result, output, payloadStart, data.size)
    return result
}
