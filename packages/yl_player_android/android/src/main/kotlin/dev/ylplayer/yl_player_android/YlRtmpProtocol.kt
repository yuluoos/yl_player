package dev.ylplayer.yl_player_android

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/** Typed, code-owned errors; neither remote text nor a nested socket exception is retained. */
internal class YlRtmpException(val kind: YlFailureKind, val transient: Boolean = false) : IOException(kind.publicMessage)
internal fun rtmpInvalid(): Nothing = throw YlRtmpException(YlFailureKind.NETWORK_PROTOCOL_UNSUPPORTED)
internal fun rtmpLimit(): Nothing = throw YlRtmpException(YlFailureKind.RESOURCE_EXHAUSTED)
internal data class YlRtmpMessage(val type: Int, val streamId: Int, val timestamp: Long, val payload: ByteArray)
internal fun InputStream.exact(size: Int): ByteArray = ByteArray(size).also { exactInto(it, 0, size) }
internal fun InputStream.exactInto(bytes: ByteArray, offset: Int, length: Int) {
    var done = 0
    while (done < length) {
        val n = read(bytes, offset + done, length - done)
        if (n < 0) throw java.io.EOFException()
        if (n == 0) continue
        done += n
    }
}
internal fun InputStream.u8(): Int = read().also { if (it < 0) throw java.io.EOFException() }
internal fun InputStream.u24(): Int = (u8() shl 16) or (u8() shl 8) or u8()
internal fun InputStream.u32(): Long = (u8().toLong() shl 24) or (u8().toLong() shl 16) or (u8().toLong() shl 8) or u8().toLong()
internal fun OutputStream.u24(v: Int) { write(v ushr 16); write(v ushr 8); write(v) }
internal fun OutputStream.u32(v: Long) { write((v ushr 24).toInt()); write((v ushr 16).toInt()); write((v ushr 8).toInt()); write(v.toInt()) }

/** No producer queue. At most 32 histories and 8 MiB of partially assembled payload. */
internal class YlRtmpChunkReader(private val input: InputStream) {
    private data class State(var timestamp: Long = 0, var delta: Long = 0, var length: Int = 0,
        var type: Int = 0, var stream: Int = 0, var extended: Boolean = false, var extendedValue: Long = 0,
        var payload: ByteArray? = null, var filled: Int = 0)
    private val states = mutableMapOf<Int, State>()
    private var chunkSize = 128
    var allocatedBytes: Int = 0; private set
    fun setChunkSize(value: Int) { if (value !in 1..65536) rtmpLimit(); chunkSize = value }
    fun abort(id: Int) { states[id]?.let { release(it) } }
    fun clear() { states.clear(); allocatedBytes = 0 }
    private fun release(s: State) { s.payload?.let { allocatedBytes -= it.size }; s.payload = null; s.filled = 0 }
    fun next(): YlRtmpMessage {
        while (true) {
            val basic = input.u8()
            val fmt = basic ushr 6
            val cs = when (val value = basic and 63) { 0 -> 64 + input.u8(); 1 -> 64 + input.u8() + (input.u8() shl 8); else -> value }
            val prior = states[cs]
            if (prior == null && fmt != 0) rtmpInvalid()
            val s = prior ?: State().also { if (states.size >= 32) rtmpLimit(); states[cs] = it }
            val continuation = s.payload != null
            if (continuation && fmt != 3) rtmpInvalid()
            if (fmt != 3) {
                val stamp = input.u24()
                if (fmt < 2) { s.length = input.u24(); s.type = input.u8() }
                if (fmt == 0) {
                    s.stream = input.u8() or (input.u8() shl 8) or (input.u8() shl 16) or (input.u8() shl 24)
                    if (s.stream < 0) rtmpInvalid()
                }
                s.extended = stamp == 0xffffff
                val full = if (s.extended) input.u32() else stamp.toLong()
                s.extendedValue = full
                s.delta = full // fmt3 NEW after fmt0 inherits the absolute value as its delta.
                s.timestamp = if (fmt == 0) full else (s.timestamp + full) and 0xffffffffL
            } else {
                if (s.extended && input.u32() != s.extendedValue) rtmpInvalid()
                if (!continuation) s.timestamp = (s.timestamp + s.delta) and 0xffffffffL
            }
            if (!continuation) {
                if (s.type !in setOf(1,2,3,4,5,6,8,9,18,20)) rtmpInvalid()
                val limit = if (s.type == 8 || s.type == 9) 4 * 1024 * 1024 else 64 * 1024
                if (s.length > limit || allocatedBytes.toLong() + s.length > 8 * 1024 * 1024) rtmpLimit()
                s.payload = ByteArray(s.length); allocatedBytes += s.length; s.filled = 0
            }
            val payload = checkNotNull(s.payload)
            val size = minOf(chunkSize, payload.size - s.filled)
            input.exactInto(payload, s.filled, size); s.filled += size
            if (s.filled == payload.size) {
                val message = YlRtmpMessage(s.type, s.stream, s.timestamp, payload)
                release(s)
                return message
            }
        }
    }
}

internal class YlRtmpChunkWriter(private val output: OutputStream) {
    fun write(message: YlRtmpMessage, chunkStream: Int = if (message.type <= 6) 2 else 3) {
        if (chunkStream !in 2..63 || message.payload.size > 65536) rtmpLimit()
        val ext = message.timestamp >= 0xffffff
        output.write(chunkStream)
        output.u24(if (ext) 0xffffff else message.timestamp.toInt())
        output.u24(message.payload.size); output.write(message.type)
        repeat(4) { output.write(message.streamId ushr (8 * it)) }
        if (ext) output.u32(message.timestamp)
        var offset = 0
        while (offset < message.payload.size) {
            if (offset > 0) { output.write(0xc0 or chunkStream); if (ext) output.u32(message.timestamp) }
            val n = minOf(128, message.payload.size - offset)
            output.write(message.payload, offset, n); offset += n
        }
        output.flush()
    }
}
