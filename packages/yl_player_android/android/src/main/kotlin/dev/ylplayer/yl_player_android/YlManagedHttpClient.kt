package dev.ylplayer.yl_player_android

import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ProtocolException
import java.net.SocketTimeoutException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import okhttp3.*
import okio.Buffer
import okio.BufferedSource
import okio.Source
import okio.Timeout
import okio.buffer

internal interface YlNetworkClock {
    fun monotonicMs(): Long
    fun wallTimeMs(): Long
    fun schedule(delayMs: Long, action: () -> Unit): Closeable
}

internal object YlSystemNetworkClock : YlNetworkClock {
    private val timers = Executors.newSingleThreadScheduledExecutor { task -> Thread(task, "yl-http-deadline").apply { isDaemon = true } }
    override fun monotonicMs() = System.nanoTime() / 1_000_000
    override fun wallTimeMs() = System.currentTimeMillis()
    override fun schedule(delayMs: Long, action: () -> Unit): Closeable {
        val future = timers.schedule(action, delayMs, TimeUnit.MILLISECONDS)
        return Closeable { future.cancel(false) }
    }
}

/** Call.Factory consumed directly by Media3's OkHttpDataSource. Each Call is one resource
 * budget, including response-body resumes. No socket/callback waits occur on the engine Looper.
 * Platform-default keeps OkHttp transport defaults and Media3 loader scheduling; provenance
 * enforcement applies to both policies. Managed owns all retries, redirects and hop deadlines. */
internal class YlManagedHttpClient(
    private val credentials: YlOriginCredentialPolicy,
    private val network: NetworkConfiguration?,
    private val clock: YlNetworkClock = YlSystemNetworkClock,
    private val onRetry: (Int, Long) -> Unit = { _, _ -> },
    transport: OkHttpClient = OkHttpClient(),
) : Call.Factory {
    private val client = transport.newBuilder().followRedirects(false).followSslRedirects(false).apply {
        if (network != null) {
            retryOnConnectionFailure(false)
            // A single cancellable deadline covers DNS/connect/TLS/server header wait. Neither
            // the socket connect nor read timer can expire sooner during header acquisition.
            connectTimeout(0, TimeUnit.MILLISECONDS).readTimeout(0, TimeUnit.MILLISECONDS).callTimeout(0, TimeUnit.MILLISECONDS)
            addNetworkInterceptor { chain ->
                val response = chain.proceed(chain.request())
                response.body?.source()?.timeout()?.timeout(network.readTimeoutMs.toLong(), TimeUnit.MILLISECONDS)
                // OkHttp's 503/421 follow-ups are independent of retryOnConnectionFailure.
                // Hide only these transport-internal follow-up codes until the real hop returns.
                if (response.code in listOf(408, 503, 421)) {
                    chain.request().tag(HopStatus::class.java)?.code = response.code
                    response.newBuilder().code(599).build()
                } else response
            }
        }
    }.build()
    private val retries = network?.let { YlManagedRetryPolicy(it, clock::wallTimeMs) }
    private val redirects = YlManagedRedirectInterceptor(network?.maxRedirects ?: 20, credentials)
    private class HopStatus { var code: Int? = null }
    private val calls = java.util.concurrent.ConcurrentHashMap.newKeySet<ResourceCall>()
    override fun newCall(request: Request): Call = ResourceCall(request).also { calls.add(it) }
    fun cancelAll() { calls.toList().forEach { it.cancel() }; calls.clear() }
    fun close() { cancelAll(); client.connectionPool.evictAll(); client.dispatcher.executorService.shutdown() }

    private inner class ResourceCall(private val original: Request) : Call {
        private val executed = AtomicBoolean()
        private val lock = Any()
        @Volatile private var cancelled = false
        private var current: Call? = null
        private var pending: CompletableFuture<*>? = null
        private var retryCount = 0
        private var redirectCount = 0
        private var stripped = credentials.isStripped(original.url)
        private var lastRequest = original
        override fun request() = original
        override fun isExecuted() = executed.get()
        override fun isCanceled() = cancelled
        override fun timeout() = Timeout.NONE // Explicitly no overall timeout contract.
        public override fun clone(): Call = ResourceCall(original)
        override fun cancel() {
            synchronized(lock) {
                cancelled = true
                current?.cancel()
                calls.remove(this)
                pending?.completeExceptionally(InterruptedIOException("Cancelled"))
            }
        }
        override fun execute(): Response {
            check(executed.compareAndSet(false, true))
            return executeResource()
        }
        override fun enqueue(responseCallback: Callback) {
            check(executed.compareAndSet(false, true))
            workers.execute {
                val result = try { executeResource() } catch (error: IOException) {
                    responseCallback.onFailure(this, error); return@execute
                }
                responseCallback.onResponse(this, result)
            }
        }
        private fun checkCancelled() {
            if (cancelled || Thread.currentThread().isInterrupted) { cancel(); throw InterruptedIOException("Cancelled") }
        }
        private fun executeResource(): Response {
            val request = if (network == null) original else original.newBuilder().header("Accept-Encoding", "identity").build()
            val response = acquire(request)
            val body = response.body ?: return response
            return try { response.newBuilder().body(resumable(response, body)).build() }
            catch (error: IOException) { response.close(); calls.remove(this); throw error }
        }
        private fun acquire(initial: Request): Response {
            var request = initial
            while (true) {
                checkCancelled()
                request = credentials.apply(request, stripped)
                stripped = stripped || credentials.isStripped(request.url)
                lastRequest = request
                val response = try { hop(request) } catch (error: IOException) {
                    scheduleRetry(request.method, error = error) ?: throw error
                    continue
                }
                val follow = try { redirects.follow(response, redirectCount) } catch (error: IOException) { response.close(); throw error }
                if (follow != null) {
                    redirectCount++
                    stripped = stripped || credentials.isStripped(follow.url)
                    response.close(); request = follow; continue
                }
                val delay = retries?.delay(request.method, retryCount + 1, response.code, response.header("Retry-After"))
                if (delay != null) { response.close(); waitForRetry(delay); continue }
                return response
            }
        }
        private fun hop(request: Request): Response {
            val status = HopStatus()
            val call = client.newCall(request.newBuilder().tag(HopStatus::class.java, status).build())
            val result = CompletableFuture<Response>()
            synchronized(lock) { checkCancelled(); current = call; pending = result }
            val began = clock.monotonicMs()
            val deadline = network?.let {
                clock.schedule((it.connectTimeoutMs.toLong() - (clock.monotonicMs() - began)).coerceAtLeast(0)) {
                    // Completion wins exactly once. Late headers are closed by the callback.
                    if (result.completeExceptionally(SocketTimeoutException("Response header deadline"))) call.cancel()
                }
            }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) { result.completeExceptionally(e) }
                override fun onResponse(call: Call, response: Response) {
                    val delivered = status.code?.let { response.newBuilder().code(it).build() } ?: response
                    if (!result.complete(delivered)) delivered.close()
                }
            })
            return try { await(result) } finally {
                deadline?.close()
                synchronized(lock) { if (pending === result) pending = null }
            }
        }
        private fun <T> await(result: CompletableFuture<T>): T = try { result.get() } catch (_: InterruptedException) {
            Thread.currentThread().interrupt(); cancel(); throw InterruptedIOException("Cancelled")
        } catch (error: ExecutionException) { throw (error.cause as? IOException ?: IOException("Transport failure")) }
        private fun scheduleRetry(method: String, error: IOException): Unit? {
            checkCancelled()
            val delay = retries?.delay(method, retryCount + 1, error = error) ?: return null
            waitForRetry(delay)
            return Unit
        }
        private fun waitForRetry(delay: Long) {
            val result = CompletableFuture<Unit>()
            val scheduled: Closeable
            synchronized(lock) {
                checkCancelled()
                pending = result
                val began = clock.monotonicMs()
                scheduled = clock.schedule((delay - (clock.monotonicMs() - began)).coerceAtLeast(0)) { result.complete(Unit) }
                retryCount++
                onRetry(retryCount, delay)
            }
            try { await(result); checkCancelled() } finally {
                scheduled.close()
                synchronized(lock) { if (pending === result) pending = null }
            }
        }
        private fun resumable(initial: Response, body: ResponseBody): ResponseBody {
            val initialRange = contentRange(initial)
            val start = if (initial.code == 206) initialRange?.first ?: throw ProtocolException("Invalid byte range") else 0L
            val requestedStart = initial.request.header("Range")?.let { Regex("bytes=(\\d+)-.*").matchEntire(it)?.groupValues?.get(1)?.toLongOrNull() } ?: 0L
            if (initial.code == 206 && (start != requestedStart || (body.contentLength() >= 0 && body.contentLength() != initialRange!!.second - start + 1))) throw ProtocolException("Invalid byte range")
            val total = initialRange?.third ?: body.contentLength().takeIf { it >= 0 }
            val etag = initial.header("ETag")?.takeIf { it.startsWith('"') && it.endsWith('"') && !it.startsWith("W/") }
            var response = initial
            var input = body.source()
            var delivered = 0L
            val length = body.contentLength()
            val source = object : Source {
                override fun timeout() = input.timeout()
                override fun close() { cancel(); response.close(); calls.remove(this@ResourceCall) }
                override fun read(sink: Buffer, byteCount: Long): Long {
                    while (true) {
                        checkCancelled()
                        try {
                            val count = input.read(sink, byteCount)
                            if (count == -1L && length >= 0 && delivered < length) throw EOFException("Incomplete body")
                            if (count > 0) delivered += count
                            return count
                        } catch (error: IOException) {
                            checkCancelled()
                            // A strong entity validator and exact range response are required once
                            // bytes have escaped this body. Never buffer the whole representation.
                            if (delivered > 0 && (etag == null || total == null || initial.header("Content-Encoding") !in listOf(null, "identity"))) throw ProtocolException("Unsafe byte resume")
                            if (network == null || !initial.isSuccessful) throw error
                            // OkHttp reports premature fixed-length EOF as ProtocolException.
                            // Only this body/framing context is transient; source/range validation
                            // and malformed chunk framing remain terminal ProtocolExceptions.
                            val transportError = if (error is ProtocolException && length >= 0 && delivered < length && response.header("Transfer-Encoding") == null)
                                EOFException("Incomplete body").apply { initCause(error) } else error
                            scheduleRetry(lastRequest.method, transportError) ?: throw error
                            response.close()
                            val offset = start + delivered
                            val request = if (delivered == 0L) lastRequest else lastRequest.newBuilder()
                                .header("Range", "bytes=$offset-${initialRange?.second ?: ""}")
                                .header("If-Range", etag!!).header("Accept-Encoding", "identity").build()
                            response = acquire(request)
                            if (delivered > 0) {
                                val range = contentRange(response)
                                if (response.code != 206 || response.header("ETag") != etag || range?.first != offset || range.third != total ||
                                    (initialRange != null && range.second != initialRange.second) ||
                                    (response.body?.contentLength()?.let { it >= 0 && it != range.second - offset + 1 } == true) || response.header("Content-Encoding") !in listOf(null, "identity")) {
                                    response.close(); throw ProtocolException("Unsafe byte resume")
                                }
                            } else if (response.code != initial.code || response.header("ETag") != initial.header("ETag") ||
                                response.header("Content-Encoding") != initial.header("Content-Encoding") ||
                                response.header("Content-Type") != initial.header("Content-Type") ||
                                response.header("Content-Range") != initial.header("Content-Range") || response.body?.contentLength() != length) {
                                response.close(); throw ProtocolException("Body retry representation changed")
                            }
                            input = response.body?.source() ?: throw ProtocolException("Missing response body")
                        }
                    }
                }
            }.buffer()
            return object : ResponseBody() {
                override fun contentType() = body.contentType()
                override fun contentLength() = length
                override fun source(): BufferedSource = source
            }
        }
    }
    private fun contentRange(response: Response): Triple<Long, Long, Long>? {
        val parts = Regex("bytes (\\d+)-(\\d+)/(\\d+)").matchEntire(response.header("Content-Range") ?: return null)?.groupValues ?: return null
        val start = parts[1].toLongOrNull() ?: return null
        val end = parts[2].toLongOrNull() ?: return null
        val total = parts[3].toLongOrNull() ?: return null
        if (start > end || end >= total) return null
        return Triple(start, end, total)
    }
    companion object {
        private val workers = Executors.newCachedThreadPool { task -> Thread(task, "yl-http-resource").apply { isDaemon = true } }
    }
}
