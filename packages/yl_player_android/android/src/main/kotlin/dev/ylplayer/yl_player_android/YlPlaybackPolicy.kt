package dev.ylplayer.yl_player_android

import java.net.URI
import kotlin.math.min

internal enum class YlDeviceTier(val wireName: String) {
    CONSTRAINED("constrained"),
    STANDARD("standard"),
    CAPABLE("capable"),
}

internal data class YlDeviceSignals(
    val totalMemoryBytes: Long?,
    val memoryClassMb: Int,
    val is64Bit: Boolean?,
    val apiLevel: Int,
)

internal enum class YlSourceClass {
    LOCAL,
    NETWORK_VOD,
    HLS_LIVE,
    HTTP_FLV_LIVE,
}

internal data class YlBufferRequest(
    val mode: String,
    val minBufferMs: Int?,
    val maxBufferMs: Int?,
    val maxBufferBytes: Int?,
) {
    companion object {
        fun automatic() = YlBufferRequest("automatic", null, null, null)
    }
}

/** Buffer targets are scheduling goals, never an enforced hard allocation ceiling. */
internal data class YlBufferProfile(
    val minBufferMs: Int,
    val maxBufferMs: Int,
    val targetBufferBytes: Int,
)

internal enum class YlMemorySignal {
    NORMAL,
    RUNNING_MODERATE,
    RUNNING_LOW,
    RUNNING_CRITICAL,
    UI_HIDDEN,
    FOREGROUND,
}

internal enum class YlMemoryAction { NONE, SHRINK, RELEASE, RESTORE }

internal object YlPlaybackPolicy {
    private const val MIB = 1024 * 1024
    private const val TWO_GIB = 2L * 1024 * MIB
    private const val FOUR_GIB = 4L * 1024 * MIB

    fun classifyDevice(signals: YlDeviceSignals): YlDeviceTier {
        if (
            signals.totalMemoryBytes?.let { it <= TWO_GIB } == true ||
            signals.is64Bit == false ||
            signals.apiLevel in 24..27
        ) {
            return YlDeviceTier.CONSTRAINED
        }
        if (
            signals.totalMemoryBytes?.let { it >= FOUR_GIB } == true &&
            signals.is64Bit == true &&
            signals.apiLevel >= 29
        ) {
            return YlDeviceTier.CAPABLE
        }
        return YlDeviceTier.STANDARD
    }

    fun classifySource(
        kind: String,
        isLive: Boolean,
        formatHint: String,
        uri: String,
    ): YlSourceClass {
        if (kind == "file" || kind == "content") return YlSourceClass.LOCAL
        when (formatHint) {
            "hls" -> return YlSourceClass.HLS_LIVE
            "httpFlv", "flv" -> return YlSourceClass.HTTP_FLV_LIVE
        }
        val path = runCatching { URI(uri).path.orEmpty().lowercase() }.getOrDefault("")
        if (path.endsWith(".m3u8")) return YlSourceClass.HLS_LIVE
        if (isLive && path.endsWith(".flv")) return YlSourceClass.HTTP_FLV_LIVE
        return if (isLive) YlSourceClass.HLS_LIVE else YlSourceClass.NETWORK_VOD
    }

    fun effectiveBufferProfile(
        tier: YlDeviceTier,
        sourceClass: YlSourceClass,
        request: YlBufferRequest,
    ): YlBufferProfile {
        val ceiling = if (tier == YlDeviceTier.CONSTRAINED) {
            constrainedProfile(sourceClass)
        } else {
            val requested = requestedBase(tier, request.mode)
            val byteCap = if (tier == YlDeviceTier.STANDARD) 64 * MIB else 96 * MIB
            requested.copy(targetBufferBytes = min(requested.targetBufferBytes, byteCap))
        }
        val requested = if (tier == YlDeviceTier.CONSTRAINED && request.mode == "automatic") {
            ceiling
        } else {
            requestedBase(tier, request.mode)
        }
        val rawMax = request.maxBufferMs ?: requested.maxBufferMs
        val effectiveMax = min(rawMax, ceiling.maxBufferMs).coerceAtLeast(0)
        val rawMin = request.minBufferMs ?: if (tier == YlDeviceTier.CONSTRAINED) {
            min(requested.minBufferMs, ceiling.minBufferMs)
        } else {
            requested.minBufferMs
        }
        val effectiveMin = min(rawMin, effectiveMax).coerceAtLeast(0)
        val rawBytes = request.maxBufferBytes ?: requested.targetBufferBytes
        val effectiveBytes = min(rawBytes, ceiling.targetBufferBytes).coerceAtLeast(1)
        return YlBufferProfile(effectiveMin, effectiveMax, effectiveBytes)
    }

    fun shrinkForMemoryPressure(profile: YlBufferProfile): YlBufferProfile =
        profile.copy(targetBufferBytes = profile.targetBufferBytes / 4 * 3)

    fun memoryAction(signal: YlMemorySignal): YlMemoryAction = when (signal) {
        YlMemorySignal.NORMAL -> YlMemoryAction.NONE
        YlMemorySignal.RUNNING_MODERATE,
        YlMemorySignal.RUNNING_LOW,
        -> YlMemoryAction.SHRINK
        YlMemorySignal.RUNNING_CRITICAL,
        YlMemorySignal.UI_HIDDEN,
        -> YlMemoryAction.RELEASE
        YlMemorySignal.FOREGROUND -> YlMemoryAction.RESTORE
    }

    private fun constrainedProfile(sourceClass: YlSourceClass): YlBufferProfile = when (sourceClass) {
        YlSourceClass.LOCAL -> YlBufferProfile(2_000, 10_000, 16 * MIB)
        YlSourceClass.NETWORK_VOD -> YlBufferProfile(4_000, 15_000, 24 * MIB)
        YlSourceClass.HLS_LIVE -> YlBufferProfile(6_000, 12_000, 20 * MIB)
        YlSourceClass.HTTP_FLV_LIVE -> YlBufferProfile(2_000, 5_000, 12 * MIB)
    }

    private fun requestedBase(tier: YlDeviceTier, mode: String): YlBufferProfile = when (mode) {
        "lowLatency" -> YlBufferProfile(1_000, 5_000, 24 * MIB)
        "stable" -> YlBufferProfile(
            15_000,
            50_000,
            if (tier == YlDeviceTier.STANDARD) 64 * MIB else 96 * MIB,
        )
        else -> YlBufferProfile(5_000, 20_000, 48 * MIB)
    }
}
