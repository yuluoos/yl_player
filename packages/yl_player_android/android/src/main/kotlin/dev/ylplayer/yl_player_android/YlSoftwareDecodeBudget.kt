package dev.ylplayer.yl_player_android

/** Cumulative process CPU includes native decoder workers; unknown thermal status fails closed. */
internal data class YlSoftwareDecodeObservation(
    val monotonicNs: Long, val cumulativeCpuNs: Long, val decodeWallNs: Long, val thermalNominal: Boolean?,
)

/** Process-wide aggregate, including candidates and frames retained after a lease closes. */
internal class YlSoftwareDecodePool {
    internal val lock = Any()
    internal val leases = mutableMapOf<Any, YlSoftwareDecodeLimits>()
    internal var bytes = 0L
    internal var frames = 0
    internal val history = ArrayDeque<YlSoftwareDecodeObservation>()
    internal var longestWindow = 0L
    internal var mayRestartAfterIdle = false
    val ownedBytes get() = synchronized(lock) { bytes }
    companion object { val shared = YlSoftwareDecodePool() }
}

/** Close always retires a lease, never its still-owned surfaces. No generation reset can
 * erase process history or release another decoder's allocation. C calls are not preempted. */
@androidx.annotation.Keep
internal class YlSoftwareDecodeBudget(
    private val limits: YlSoftwareDecodeLimits,
    private val pool: YlSoftwareDecodePool = YlSoftwareDecodePool.shared,
) : AutoCloseable {
    private val id = Any()
    private var closed = false
    private var bytes = 0L
    private var frames = 0
    private var nextReceipt = 0L
    private val nativeReceipts = mutableMapOf<Long, Token>()
    init {
        synchronized(pool.lock) {
            if (!limits.valid || pool.bytes > limits.maxOwnedBytes || pool.frames > limits.maxFrames) exhausted()
            if (pool.leases.isEmpty()) pool.mayRestartAfterIdle = true
            pool.longestWindow = maxOf(pool.longestWindow, limits.windowNs)
            pool.leases[id] = limits
        }
    }
    /** A strong ownership receipt. Explicit close is thread-safe and idempotent. */
    internal class Token(private var owner: YlSoftwareDecodeBudget?, private val bytes: Long, private val frames: Int) : AutoCloseable {
        override fun close() { val value = synchronized(this) { owner.also { owner = null } }; value?.release(bytes, frames) }
    }
    fun reserve(bytes: Long, frames: Int): Token = synchronized(pool.lock) {
        if (closed || bytes <= 0 || frames < 0) fail()
        val byteCap = pool.leases.values.minOfOrNull { it.maxOwnedBytes } ?: 0
        val frameCap = pool.leases.values.minOfOrNull { it.maxFrames } ?: 0
        if (bytes > byteCap - pool.bytes || frames > frameCap - pool.frames) fail()
        pool.bytes += bytes; pool.frames += frames; this.bytes += bytes; this.frames += frames
        Token(this, bytes, frames)
    }
    fun reservePacket(bytes: Int): Token = synchronized(pool.lock) {
        if (bytes <= 0 || bytes > limits.maxPacketBytes) fail()
        reserve(bytes.toLong(), 0)
    }
    /** JNI ABI: zero means denied. A positive receipt stays valid after decoder disposal. */
    fun reserveNative(bytes: Long, frames: Int): Long = synchronized(pool.lock) {
        try {
            if (nextReceipt == Long.MAX_VALUE) fail()
            val token = reserve(bytes, frames)
            (++nextReceipt).also { nativeReceipts[it] = token }
        } catch (_: YlBoundaryException) { 0L }
    }
    /** JNI ABI: unknown/already released receipts are harmless. */
    fun releaseNative(receipt: Long) { synchronized(pool.lock) { nativeReceipts.remove(receipt) }?.close() }
    /** Producer runs under the shared lock and must not reenter; captures cannot arrive stale. */
    fun observe(producer: () -> YlSoftwareDecodeObservation) = synchronized(pool.lock) {
        val sample = producer()
        if (closed || sample.monotonicNs < 0 || sample.cumulativeCpuNs < 0 || sample.decodeWallNs < 0 ||
            sample.decodeWallNs > limits.maxDecodeWallNs || sample.thermalNominal != true) fail()
        pool.history.lastOrNull()?.let { prior ->
            if (sample.monotonicNs <= prior.monotonicNs || sample.cumulativeCpuNs < prior.cumulativeCpuNs) fail()
            val gap = sample.monotonicNs - prior.monotonicNs
            if (pool.mayRestartAfterIdle && gap > pool.longestWindow) pool.history.clear()
            else if (gap > limits.windowNs) fail()
        }
        pool.mayRestartAfterIdle = false
        val cutoff = (sample.monotonicNs - pool.longestWindow).coerceAtLeast(0)
        while (pool.history.size > 1 && pool.history[1].monotonicNs <= cutoff) pool.history.removeFirst()
        for (live in pool.leases.values) {
            val boundary = (sample.monotonicNs - live.windowNs).coerceAtLeast(0)
            val first = pool.history.lastOrNull { it.monotonicNs <= boundary } ?: pool.history.firstOrNull()
            if (first != null && sample.cumulativeCpuNs - first.cumulativeCpuNs > live.maxCpuNs) fail()
        }
        if (pool.history.size >= 1024) fail()
        pool.history.addLast(sample)
    }
    override fun close() = synchronized(pool.lock) { closed = true; removeEmpty() }
    private fun release(bytes: Long, frames: Int) = synchronized(pool.lock) {
        this.bytes -= bytes; this.frames -= frames; pool.bytes -= bytes; pool.frames -= frames; removeEmpty()
    }
    private fun removeEmpty() { if (closed && bytes == 0L && frames == 0) pool.leases.remove(id) }
    private fun fail(): Nothing { closed = true; removeEmpty(); exhausted() }
    private fun exhausted(): Nothing = throw YlBoundaryException(YlFailureKind.RESOURCE_EXHAUSTED)
}
