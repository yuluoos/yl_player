package dev.ylplayer.yl_player_android

import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.os.Process
import java.io.File
import java.security.MessageDigest

/** Exact model/OS/installed code identity. Missing identity never enables a fallback. */
internal data class YlSoftwareDecodeIdentity(val model: String, val osBuild: String, val decoderBuild: String) {
    companion object {
        fun current(context: Context): YlSoftwareDecodeIdentity? = runCatching {
            val digest = MessageDigest.getInstance("SHA-256")
            val files = listOf(File(context.applicationInfo.sourceDir)) +
                context.applicationInfo.splitSourceDirs.orEmpty().sorted().map(::File) +
                listOf(File(context.applicationInfo.nativeLibraryDir, "libyl_player_ffmpeg.so")).filter(File::isFile)
            for (file in files) file.inputStream().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
            }
            YlSoftwareDecodeIdentity("${Build.MANUFACTURER}/${Build.MODEL}", Build.FINGERPRINT,
                digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) })
        }.getOrNull()
    }
}

/** Internal controlled records only. Production does not contain synthetic limits. */
internal class YlSoftwareDecodeServices(
    private val identity: YlSoftwareDecodeIdentity?,
    private val admission: YlSoftwareDecodeAdmission = YlSoftwareDecodeAdmission(),
    private val pool: YlSoftwareDecodePool = YlSoftwareDecodePool.shared,
    private val threads: Int = 2,
    private val observe: (Long) -> YlSoftwareDecodeObservation,
) {
    fun key(stream: YlNativeStreamInfo): YlSoftwareDecodeKey? {
        val identity = identity ?: return null
        if (stream.codec !in listOf(YlNativeCodec.H264, YlNativeCodec.HEVC) || stream.bitDepth != 8 || stream.chroma != 420 ||
            (stream.colorSpace == 2 && stream.height > 576) || stream.colorRange == 2 || stream.colorSpace !in listOf(2, 5, 6) || stream.colorTransfer !in listOf(1, 2, 6)) return null
        return YlSoftwareDecodeKey(identity.model, identity.osBuild, identity.decoderBuild,
            stream.codec.ordinal, stream.profile, stream.bitDepth, stream.chroma, stream.width, stream.height,
            stream.fpsNumerator, stream.fpsDenominator, threads, 1)
    }
    fun isAdmitted(stream: YlNativeStreamInfo): Boolean = key(stream)?.let(admission::limits) != null
    fun acquire(stream: YlNativeStreamInfo): YlSoftwareDecodeLease {
        val key = key(stream) ?: throw YlBoundaryException(YlFailureKind.DECODER_UNAVAILABLE)
        val limits = admission.limits(key) ?: throw YlBoundaryException(YlFailureKind.DECODER_UNAVAILABLE)
        val budget = YlSoftwareDecodeBudget(limits, pool)
        return try { YlSoftwareDecodeLease(key, limits, budget, observe).also { it.observe() } }
        catch (error: Throwable) { budget.close(); throw error }
    }
    companion object {
        fun production(context: Context): YlSoftwareDecodeServices {
            val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            return YlSoftwareDecodeServices(YlSoftwareDecodeIdentity.current(context)) { wall ->
                // Process cumulative CPU includes native worker threads, at millisecond resolution.
                YlSoftwareDecodeObservation(System.nanoTime(), Process.getElapsedCpuTime() * 1_000_000,
                    wall, if (Build.VERSION.SDK_INT >= 29) power.currentThermalStatus == PowerManager.THERMAL_STATUS_NONE else null)
            }
        }
    }
}

/** One admitted configuration, reused by seek/surface replacement. Period/candidate leases
 * share the pool and never discard measurements made by another live decoder. */
internal class YlSoftwareDecodeLease(
    val key: YlSoftwareDecodeKey, val limits: YlSoftwareDecodeLimits, val budget: YlSoftwareDecodeBudget,
    private val observation: (Long) -> YlSoftwareDecodeObservation,
) : AutoCloseable {
    val observationIntervalMs get() = minOf(250L, limits.windowNs / 4 / 1_000_000).coerceAtLeast(1)
    fun observe(wallNs: Long = 0) = budget.observe { observation(wallNs) }
    fun <T> measured(work: () -> T): T {
        observe(); val start = System.nanoTime()
        val result = work(); observe(System.nanoTime() - start); return result
    }
    override fun close() = budget.close()
}
