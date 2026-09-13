package dev.ylplayer.yl_player_android

import android.content.Context
import android.net.Uri
import dev.ylplayer.yl_player_android.pigeon.AndroidLoadOptionsMessage
import dev.ylplayer.yl_player_android.pigeon.AndroidMediaFormat
import dev.ylplayer.yl_player_android.pigeon.AndroidNetworkPolicyKind
import dev.ylplayer.yl_player_android.pigeon.AndroidSourceKind
import dev.ylplayer.yl_player_android.pigeon.AndroidSourceMessage
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.EOFException
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import okhttp3.Response
import okio.BufferedSource

/** Synchronous custom-AVIO source. JNI calls it only from the owned demux worker. */
internal interface YlNativeByteSource : Closeable {
    fun read(target: ByteBuffer): Int
    fun seek(offset: Long, whence: Int): Long
    fun seekTime(positionUs: Long): Long = -3
    fun cancel()
}

internal object YlNativeByteSourceFactory {
    fun create(
        context: Context,
        source: AndroidSourceMessage,
        options: AndroidLoadOptionsMessage,
        onRetry: (Int, Long) -> Unit,
    ): YlNativeByteSource {
        if (source.kind == AndroidSourceKind.FILE) {
            return YlFileByteSource(File(Uri.parse(source.locator).path ?: source.locator).inputStream().channel)
        }
        if (source.kind == AndroidSourceKind.CONTENT) {
            val descriptor = context.contentResolver.openFileDescriptor(Uri.parse(source.locator), "r")
                ?: throw IOException("Content source is unavailable")
            return YlFileByteSource(FileInputStream(descriptor.fileDescriptor).channel, descriptor)
        }
        val origin = source.locator.toHttpUrl()
        val credentials = YlOriginCredentialPolicy(
            origin,
            source.request?.headers.orEmpty(),
            source.request?.credentials.orEmpty(),
            requireKnownAncestry = source.format == AndroidMediaFormat.HLS || origin.encodedPath.lowercase().endsWith(".m3u8"),
        )
        val network = source.networkPolicy?.takeIf { it.kind == AndroidNetworkPolicyKind.MANAGED }?.let {
            createMedia3Configuration(source, options, defaultNativePlayerOptions()).network
        }
        val http = YlManagedHttpClient(credentials, network, onRetry = onRetry)
        return if (source.format == AndroidMediaFormat.HLS || origin.encodedPath.lowercase().endsWith(".m3u8")) {
            YlHlsByteSource(source.locator, http, credentials)
        } else {
            YlHttpRangeByteSource(source.locator, http, credentials)
        }
    }

    private fun defaultNativePlayerOptions() = dev.ylplayer.yl_player_android.pigeon.AndroidPlayerOptionsMessage(
        dev.ylplayer.yl_player_android.pigeon.AndroidDecoderPolicy.HARDWARE_PREFERRED,
        dev.ylplayer.yl_player_android.pigeon.AndroidAudioPolicy.APP_MANAGED,
        250,
    )
}

private class YlFileByteSource(
    private val channel: FileChannel,
    private val owner: Closeable? = null,
) : YlNativeByteSource {
    private val cancelled = AtomicBoolean()
    override fun read(target: ByteBuffer): Int {
        if (cancelled.get()) return -2
        return channel.read(target).coerceAtLeast(0)
    }
    override fun seek(offset: Long, whence: Int): Long {
        if (cancelled.get()) return -2
        if (whence and 0x10000 != 0) return channel.size()
        val position = when (whence and 0x3) {
            0 -> offset
            1 -> channel.position() + offset
            2 -> channel.size() + offset
            else -> return -3
        }
        channel.position(position.coerceAtLeast(0))
        return channel.position()
    }
    override fun cancel() { cancelled.set(true) }
    override fun close() { cancel(); channel.close(); owner?.close() }
}

private class YlHttpRangeByteSource(
    private val locator: String,
    private val calls: YlManagedHttpClient,
    private val credentials: YlOriginCredentialPolicy,
) : YlNativeByteSource {
    private val cancelled = AtomicBoolean()
    private var position = 0L
    private var length = -1L
    private var response: Response? = null
    private var body: BufferedSource? = null

    override fun read(target: ByteBuffer): Int {
        if (cancelled.get()) return -2
        ensureOpen()
        val requested = minOf(target.remaining(), 64 * 1024)
        val bytes = ByteArray(requested)
        val count = body?.read(bytes, 0, requested) ?: -1
        if (count <= 0) return 0
        target.put(bytes, 0, count)
        position += count
        return count
    }

    override fun seek(offset: Long, whence: Int): Long {
        if (cancelled.get()) return -2
        if (whence and 0x10000 != 0) {
            ensureOpen()
            return length
        }
        val next = when (whence and 0x3) {
            0 -> offset
            1 -> position + offset
            2 -> {
                ensureOpen()
                if (length < 0) return -3
                length + offset
            }
            else -> return -3
        }.coerceAtLeast(0)
        if (next != position) { closeResponse(); position = next }
        return position
    }

    private fun ensureOpen() {
        if (body != null) return
        val url = locator.toHttpUrl()
        val request = credentials.apply(Request.Builder().url(url).apply {
            if (position > 0) header("Range", "bytes=$position-")
        }.build(), inheritedStripped = false)
        val next = calls.newCall(request).execute()
        if (!next.isSuccessful || (position > 0 && next.code != 206)) {
            next.close()
            throw IOException("HTTP byte source rejected range")
        }
        response = next
        body = next.body?.source() ?: run { next.close(); throw EOFException("HTTP response has no body") }
        length = parseTotal(next, position)
    }

    private fun parseTotal(response: Response, start: Long): Long {
        response.header("Content-Range")?.substringAfter('/')?.toLongOrNull()?.let { return it }
        return response.body?.contentLength()?.takeIf { it >= 0 }?.let { start + it } ?: -1
    }

    private fun closeResponse() { body = null; response?.close(); response = null }
    override fun cancel() { cancelled.set(true); calls.cancelAll(); closeResponse() }
    override fun close() { cancel(); calls.close() }
}

/** Concatenates a media playlist into a demuxable TS/fMP4 byte stream and reloads live windows. */
private class YlHlsByteSource(
    private var playlistUri: String,
    private val calls: YlManagedHttpClient,
    private val credentials: YlOriginCredentialPolicy,
) : YlNativeByteSource {
    private val cancelled = AtomicBoolean()
    private var playlist: YlHlsPlaylist? = null
    private var segmentIndex = 0
    private var lastSequence = Long.MIN_VALUE
    private var current = ByteBuffer.allocate(0)
    private var emittedInitialization = false
    private val keys = mutableMapOf<String, ByteArray>()
    private var firstPlaylist = true

    override fun read(target: ByteBuffer): Int {
        if (cancelled.get()) return -2
        var written = 0
        while (target.hasRemaining()) {
            if (!current.hasRemaining() && !advance()) break
            val count = minOf(target.remaining(), current.remaining())
            val limit = current.limit()
            current.limit(current.position() + count)
            target.put(current)
            current.limit(limit)
            written += count
        }
        return written
    }

    override fun seek(offset: Long, whence: Int): Long = -3
    override fun seekTime(positionUs: Long): Long {
        val active = playlist ?: loadPlaylist().also { playlist = it }
        if (active.segments.isEmpty()) return -3
        var elapsed = 0L
        var selected = 0
        active.segments.forEachIndexed { index, segment ->
            if (elapsed <= positionUs) selected = index
            elapsed += segment.durationUs
        }
        if (positionUs == Long.MAX_VALUE || active.isLive) selected = (active.segments.size - 3).coerceAtLeast(0)
        segmentIndex = selected
        lastSequence = active.segments[selected].sequence - 1
        current = ByteBuffer.allocate(0)
        emittedInitialization = false
        return active.segments.take(selected).sumOf { it.durationUs }
    }

    private fun advance(): Boolean {
        var active = playlist ?: loadPlaylist().also {
            playlist = it
            if (firstPlaylist && it.isLive) segmentIndex = (it.segments.size - 3).coerceAtLeast(0)
            firstPlaylist = false
        }
        if (!emittedInitialization) {
            active.initialization?.let { resource ->
                current = ByteBuffer.wrap(fetch(resource.uri, resource.range))
                emittedInitialization = true
                return true
            }
            emittedInitialization = true
        }
        while (segmentIndex < active.segments.size) {
            val segment = active.segments[segmentIndex++]
            if (segment.sequence <= lastSequence) continue
            lastSequence = segment.sequence
            var bytes = fetch(segment.uri, segment.range)
            segment.key?.let { key -> bytes = decrypt(bytes, keys.getOrPut(key.uri) { fetch(key.uri) }, key.iv) }
            current = ByteBuffer.wrap(bytes)
            return true
        }
        if (!active.isLive) return false
        while (!cancelled.get()) {
            Thread.sleep((active.targetDurationUs / 2_000).coerceIn(250, 2_000))
            active = loadPlaylist()
            playlist = active
            segmentIndex = 0
            if (active.segments.any { it.sequence > lastSequence }) return advance()
            if (!active.isLive) return false
        }
        return false
    }

    private fun loadPlaylist(): YlHlsPlaylist {
        val text = fetch(playlistUri).toString(Charsets.UTF_8)
        var parsed = YlHlsPlaylistParser.parse(text, playlistUri)
        if (parsed.variants.isNotEmpty()) {
            val variant = parsed.variants.filter { it.fitsSoftwareEnvelope }.maxByOrNull { it.bandwidth }
                ?: throw YlBoundaryException(YlFailureKind.DECODER_UNSUPPORTED)
            credentials.inherit(playlistUri.toHttpUrl(), variant.uri.toHttpUrl())
            playlistUri = variant.uri
            parsed = YlHlsPlaylistParser.parse(fetch(playlistUri).toString(Charsets.UTF_8), playlistUri)
        }
        parsed.segments.forEach { segment ->
            credentials.inherit(playlistUri.toHttpUrl(), segment.uri.toHttpUrl())
            segment.key?.let { credentials.inherit(playlistUri.toHttpUrl(), it.uri.toHttpUrl()) }
        }
        parsed.initialization?.let { credentials.inherit(playlistUri.toHttpUrl(), it.uri.toHttpUrl()) }
        return parsed
    }

    private fun fetch(uri: String, range: YlByteRange? = null): ByteArray {
        if (cancelled.get()) throw IOException("Cancelled")
        val url = uri.toHttpUrl()
        val request = credentials.apply(Request.Builder().url(url).apply {
            range?.let { header("Range", "bytes=${it.offset}-${it.offset + it.length - 1}") }
        }.build(), credentials.isStripped(url))
        return calls.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("HLS resource failed")
            val body = response.body ?: throw EOFException("HLS resource has no body")
            if (body.contentLength() > MAX_HLS_RESOURCE_BYTES) {
                throw YlBoundaryException(YlFailureKind.SOURCE_INVALID)
            }
            val output = ByteArrayOutputStream()
            body.byteStream().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > MAX_HLS_RESOURCE_BYTES) {
                        throw YlBoundaryException(YlFailureKind.SOURCE_INVALID)
                    }
                    output.write(buffer, 0, count)
                }
            }
            output.toByteArray()
        }
    }

    private fun decrypt(ciphertext: ByteArray, key: ByteArray, iv: ByteArray): ByteArray {
        if (key.size != 16 || ciphertext.size % 16 != 0) throw YlBoundaryException(YlFailureKind.SOURCE_INVALID)
        return runCatching {
            Cipher.getInstance("AES/CBC/PKCS5Padding").apply {
                init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
            }.doFinal(ciphertext)
        }.getOrElse {
            Cipher.getInstance("AES/CBC/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
            }.doFinal(ciphertext)
        }
    }

    override fun cancel() { cancelled.set(true); calls.cancelAll() }
    override fun close() { cancel(); calls.close() }

    companion object {
        private const val MAX_HLS_RESOURCE_BYTES = 32L * 1024 * 1024
    }
}
