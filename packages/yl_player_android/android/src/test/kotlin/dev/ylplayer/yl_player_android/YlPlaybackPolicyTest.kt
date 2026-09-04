package dev.ylplayer.yl_player_android

import kotlin.test.Test
import kotlin.test.assertEquals

class YlPlaybackPolicyTest {
    @Test
    fun `Android 7 1_5GB 32-bit is constrained`() {
        val signals = YlDeviceSignals(
            totalMemoryBytes = 1536L * MIB,
            memoryClassMb = 192,
            is64Bit = false,
            apiLevel = 24,
        )

        assertEquals(YlDeviceTier.CONSTRAINED, YlPlaybackPolicy.classifyDevice(signals))
    }

    @Test
    fun `any constrained boundary wins`() {
        assertEquals(YlDeviceTier.CONSTRAINED, classify(totalMb = 2048, is64Bit = true, api = 35))
        assertEquals(YlDeviceTier.CONSTRAINED, classify(totalMb = 8192, is64Bit = false, api = 35))
        assertEquals(YlDeviceTier.CONSTRAINED, classify(totalMb = 8192, is64Bit = true, api = 27))
    }

    @Test
    fun `capable requires every capable signal`() {
        assertEquals(YlDeviceTier.CAPABLE, classify(totalMb = 4096, is64Bit = true, api = 29))
        assertEquals(YlDeviceTier.STANDARD, classify(totalMb = 3072, is64Bit = true, api = 29))
        assertEquals(YlDeviceTier.STANDARD, classify(totalMb = 4096, is64Bit = true, api = 28))
        assertEquals(
            YlDeviceTier.STANDARD,
            YlPlaybackPolicy.classifyDevice(
                YlDeviceSignals(null, 256, null, 35),
            ),
        )
    }

    @Test
    fun `local sources are classified before URL inspection`() {
        assertEquals(YlSourceClass.LOCAL, classifySource("file", false, "automatic", "file:///a.m3u8"))
        assertEquals(YlSourceClass.LOCAL, classifySource("content", false, "hls", "content://media/1"))
    }

    @Test
    fun `explicit hint wins and query is ignored`() {
        assertEquals(
            YlSourceClass.HLS_LIVE,
            classifySource("network", true, "hls", "https://x/live.flv?next=.m3u8"),
        )
        assertEquals(
            YlSourceClass.HTTP_FLV_LIVE,
            classifySource("network", true, "httpFlv", "https://x/live.m3u8"),
        )
        assertEquals(
            YlSourceClass.NETWORK_VOD,
            classifySource("network", false, "automatic", "https://x/video.mp4?next=.m3u8"),
        )
    }

    @Test
    fun `automatic live suffix and unknown live are deterministic`() {
        assertEquals(
            YlSourceClass.HLS_LIVE,
            classifySource("network", true, "automatic", "https://x/LIVE.M3U8?token=1"),
        )
        assertEquals(
            YlSourceClass.HTTP_FLV_LIVE,
            classifySource("network", true, "automatic", "https://x/LIVE.FLV?token=1"),
        )
        assertEquals(
            YlSourceClass.HLS_LIVE,
            classifySource("network", true, "automatic", "https://x/channel"),
        )
    }

    @Test
    fun `constrained automatic profiles match TVBox ceilings`() {
        assertEquals(profile(2_000, 10_000, 16), effective(YlSourceClass.LOCAL))
        assertEquals(profile(4_000, 15_000, 24), effective(YlSourceClass.NETWORK_VOD))
        assertEquals(profile(6_000, 12_000, 20), effective(YlSourceClass.HLS_LIVE))
        assertEquals(profile(2_000, 5_000, 12), effective(YlSourceClass.HTTP_FLV_LIVE))
    }

    @Test
    fun `constrained requests are clamped but smaller custom values survive`() {
        assertEquals(
            profile(4_000, 15_000, 24),
            YlPlaybackPolicy.effectiveBufferProfile(
                YlDeviceTier.CONSTRAINED,
                YlSourceClass.NETWORK_VOD,
                YlBufferRequest("stable", null, null, null),
            ),
        )
        assertEquals(
            profile(1_000, 5_000, 8),
            YlPlaybackPolicy.effectiveBufferProfile(
                YlDeviceTier.CONSTRAINED,
                YlSourceClass.NETWORK_VOD,
                YlBufferRequest("custom", 1_000, 5_000, 8 * MIB),
            ),
        )
        assertEquals(
            profile(15_000, 15_000, 24),
            YlPlaybackPolicy.effectiveBufferProfile(
                YlDeviceTier.CONSTRAINED,
                YlSourceClass.NETWORK_VOD,
                YlBufferRequest("custom", 30_000, null, null),
            ),
        )
    }

    @Test
    fun `standard and capable modes retain bounded existing behavior`() {
        assertEquals(
            profile(5_000, 20_000, 48),
            YlPlaybackPolicy.effectiveBufferProfile(
                YlDeviceTier.STANDARD,
                YlSourceClass.NETWORK_VOD,
                YlBufferRequest.automatic(),
            ),
        )
        assertEquals(
            profile(15_000, 50_000, 64),
            YlPlaybackPolicy.effectiveBufferProfile(
                YlDeviceTier.STANDARD,
                YlSourceClass.NETWORK_VOD,
                YlBufferRequest("stable", null, null, null),
            ),
        )
        assertEquals(
            profile(15_000, 50_000, 96),
            YlPlaybackPolicy.effectiveBufferProfile(
                YlDeviceTier.CAPABLE,
                YlSourceClass.NETWORK_VOD,
                YlBufferRequest("stable", null, null, null),
            ),
        )
    }

    @Test
    fun `memory signals map to bounded actions`() {
        assertEquals(YlMemoryAction.NONE, YlPlaybackPolicy.memoryAction(YlMemorySignal.NORMAL))
        assertEquals(YlMemoryAction.SHRINK, YlPlaybackPolicy.memoryAction(YlMemorySignal.RUNNING_MODERATE))
        assertEquals(YlMemoryAction.SHRINK, YlPlaybackPolicy.memoryAction(YlMemorySignal.RUNNING_LOW))
        assertEquals(YlMemoryAction.RELEASE, YlPlaybackPolicy.memoryAction(YlMemorySignal.RUNNING_CRITICAL))
        assertEquals(YlMemoryAction.RELEASE, YlPlaybackPolicy.memoryAction(YlMemorySignal.UI_HIDDEN))
        assertEquals(YlMemoryAction.RESTORE, YlPlaybackPolicy.memoryAction(YlMemorySignal.FOREGROUND))
    }

    @Test
    fun `running low target is reduced by exactly 25 percent`() {
        assertEquals(
            profile(4_000, 15_000, 18),
            YlPlaybackPolicy.shrinkForMemoryPressure(profile(4_000, 15_000, 24)),
        )
    }

    private fun classify(totalMb: Long, is64Bit: Boolean, api: Int): YlDeviceTier =
        YlPlaybackPolicy.classifyDevice(YlDeviceSignals(totalMb * MIB, 256, is64Bit, api))

    private fun classifySource(kind: String, live: Boolean, hint: String, uri: String): YlSourceClass =
        YlPlaybackPolicy.classifySource(kind, live, hint, uri)

    private fun effective(sourceClass: YlSourceClass): YlBufferProfile =
        YlPlaybackPolicy.effectiveBufferProfile(
            YlDeviceTier.CONSTRAINED,
            sourceClass,
            YlBufferRequest.automatic(),
        )

    private fun profile(minMs: Int, maxMs: Int, mib: Int) =
        YlBufferProfile(minMs, maxMs, mib * MIB)

    private companion object {
        const val MIB = 1024 * 1024
    }
}
