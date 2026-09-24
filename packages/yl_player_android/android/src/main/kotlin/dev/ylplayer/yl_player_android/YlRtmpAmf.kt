package dev.ylplayer.yl_player_android

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/** Deliberately bounded AMF0 subset used by classic connect/createStream/play and metadata. */
internal object YlRtmpAmf {
    fun decode(bytes: ByteArray): List<Any?> {
        if (bytes.size > 65536) rtmpLimit()
        val input = ByteArrayInputStream(bytes)
        var entries = 0
        fun string(length: Int): String {
            if (length > 16384) rtmpLimit()
            if (length < 0 || length > input.available()) rtmpInvalid()
            return try { Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(input.exact(length))).toString() } catch (_: Exception) { rtmpInvalid() }
        }
        fun shortString() = string((input.u8() shl 8) or input.u8())
        fun value(depth: Int): Any? {
            if (depth > 8 || ++entries > 256) rtmpLimit()
            return when (input.u8()) {
                0 -> Double.fromBits(input.u32() shl 32 or input.u32()).also { if (!it.isFinite()) rtmpInvalid() }
                1 -> when (input.u8()) { 0 -> false; 1 -> true; else -> rtmpInvalid() }
                2 -> shortString()
                3, 8 -> {
                    // Marker consumed above; ECMA count is advisory but still must be bounded.
                    // The marker is recovered from the cursor without allocating a second stream.
                    val marker = bytes[bytes.size - input.available() - 1].toInt()
                    if (marker == 8 && input.u32() > 256) rtmpLimit()
                    val map = linkedMapOf<String, Any?>()
                    while (true) {
                        val key = shortString()
                        if (key.isEmpty()) {
                            input.mark(1)
                            if (input.u8() == 9) break
                            input.reset()
                        }
                        if (map.containsKey(key)) rtmpInvalid()
                        map[key] = value(depth + 1)
                    }
                    map
                }
                5, 6 -> null
                10 -> {
                    val count = input.u32()
                    if (count > 256) rtmpLimit()
                    List(count.toInt()) { value(depth + 1) }
                }
                12 -> string(input.u32().also { if (it > 16384) rtmpLimit() }.toInt())
                else -> rtmpInvalid()
            }
        }
        return try { buildList { while (input.available() > 0) add(value(0)) } }
        catch (error: YlRtmpException) { throw error }
        catch (_: Exception) { rtmpInvalid() }
    }
    fun encode(values: List<Any?>): ByteArray {
        val bytes = ByteArrayOutputStream()
        val out = DataOutputStream(bytes)
        fun string(s: String) { val data = s.toByteArray(Charsets.UTF_8); if (data.size > 16384) rtmpLimit(); out.writeShort(data.size); out.write(data) }
        fun value(v: Any?) {
            when (v) {
                null -> out.writeByte(5)
                is String -> { out.writeByte(2); string(v) }
                is Number -> { out.writeByte(0); out.writeDouble(v.toDouble()) }
                is Boolean -> { out.writeByte(1); out.writeByte(if (v) 1 else 0) }
                is Map<*, *> -> { out.writeByte(3); v.forEach { (k,x) -> string(k as String); value(x) }; out.writeShort(0); out.writeByte(9) }
                else -> rtmpInvalid()
            }
        }
        values.forEach(::value)
        if (bytes.size() > 65536) rtmpLimit()
        return bytes.toByteArray()
    }
}
