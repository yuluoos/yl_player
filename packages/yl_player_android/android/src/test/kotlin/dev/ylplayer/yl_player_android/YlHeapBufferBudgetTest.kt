package dev.ylplayer.yl_player_android

import kotlin.test.*

class YlHeapBufferBudgetTest {
    @Test fun `heap allowance caps every tier source and mode without increasing existing targets`() {
        for (tier in YlDeviceTier.entries) for (source in YlSourceClass.entries)
            for (mode in listOf("automatic", "stable", "lowLatency")) for (heap in listOf(64, 128, 192, 256, 512, Int.MAX_VALUE)) {
                val request = YlBufferRequest(mode, null, null, null)
                val original = YlPlaybackPolicy.effectiveBufferProfile(tier, source, request)
                val capped = YlPlaybackPolicy.effectiveBufferProfile(tier, source, request, heap)
                assertEquals(minOf(original.targetBufferBytes.toLong(), heap.toLong() * MIB / 8).toInt(), capped.targetBufferBytes)
                assertEquals(original.minBufferMs, capped.minBufferMs)
                assertEquals(original.maxBufferMs, capped.maxBufferMs)
            }
    }

    @Test fun `unknown heap preserves policy and explicit smaller request stays smaller`() {
        val request = YlBufferRequest("stable", null, null, 2 * MIB)
        for (heap in listOf(-1, 0, 64, 128, Int.MAX_VALUE)) {
            assertEquals(2 * MIB, YlPlaybackPolicy.effectiveBufferProfile(
                YlDeviceTier.CONSTRAINED, YlSourceClass.NETWORK_VOD, request, heap).targetBufferBytes)
        }
    }

    @Test fun `pressure and runtime profile updates never restore above heap allowance`() {
        fun profile(mode: String) = YlPlaybackPolicy.effectiveBufferProfile(YlDeviceTier.CONSTRAINED,
            YlSourceClass.NETWORK_VOD, YlBufferRequest(mode, null, null, null), 64)
        val control = YlAdaptiveLoadControl(profile("automatic"))
        assertEquals(8 * MIB, control.targetBufferBytes)
        control.shrinkForMemoryPressure()
        assertEquals(6 * MIB, control.targetBufferBytes)
        control.updateRuntimeProfile(profile("stable"))
        assertEquals(6 * MIB, control.targetBufferBytes)
        control.restoreProfile()
        assertEquals(8 * MIB, control.targetBufferBytes)
    }

    @Test fun `full byte budget permits buffered start without waiting for impossible time target`() {
        val profile = YlBufferProfile(4_000, 15_000, 8 * MIB)
        assertFalse(shouldStartPlayback(1_000, 1.5f, true, profile, 7 * MIB))
        assertTrue(shouldStartPlayback(1_000, 1.5f, true, profile, 8 * MIB))
        assertFalse(shouldStartPlayback(0, 1.5f, true, profile, 8 * MIB))
        assertFalse(shouldContinueLoading(1_000, 8 * MIB, profile, 1.5f))
    }

    @Test fun `core initial and live mode profiles both carry device heap cap`() {
        val device = YlAndroidDeviceProfile(YlDeviceSignals(2L * 1024 * MIB, 64, false, 24),
            YlDeviceTier.CONSTRAINED, 1920, 1080, 60.0, true)
        withCore(coreDeviceProfile = device) { core, _, _ ->
            val control = core.javaClass.getDeclaredField("loadControl").apply { isAccessible = true }.get(core) as YlAdaptiveLoadControl
            assertEquals(8 * MIB, control.targetBufferBytes)
            core.field("sourceClass", YlSourceClass.HLS_LIVE)
            val method = core.javaClass.getDeclaredMethod("profileForLiveMode",
                dev.ylplayer.yl_player_android.pigeon.AndroidLivePlaybackMode::class.java).apply { isAccessible = true }
            for (mode in dev.ylplayer.yl_player_android.pigeon.AndroidLivePlaybackMode.entries) {
                val profile = method.invoke(core, mode) as YlBufferProfile
                assertEquals(8 * MIB, profile.targetBufferBytes)
            }
        }
    }

    private companion object { const val MIB = 1024 * 1024 }
}
