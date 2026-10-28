package dev.ylplayer.yl_player_android

import kotlin.test.*

class YlPlaybackSpeedDiagnosticsTest {
    private val sample = YlPlaybackSpeedSample(0, 1.5f, true, 9_000, 1024, 2048, false, 0, 0, 0)

    @Test fun `symptoms report media and playout buffer separately without source data`() {
        val lines = mutableListOf<String>()
        YlPlaybackSpeedDiagnostics(lines::add).record(sample.copy(droppedFrames = 2, audioUnderruns = 1))
        assertEquals(listOf("speedHealth speed=1.5 bufferedMediaMs=9000 bufferedPlayoutMs=6000 allocatorBytes=1024 targetBytes=2048 tunnelingRequested=false rebufferCount=0 droppedFrames=2 audioUnderruns=1 loading=false supplyEvidence=notLoading transferBitsPerSecond=unknown bufferTrend=unknown consumedMediaMs=unknown"), lines)
    }

    @Test fun `repeated symptoms are limited to one report every ten seconds without losing pending counts`() {
        val lines = mutableListOf<String>()
        val diagnostics = YlPlaybackSpeedDiagnostics(lines::add)
        diagnostics.record(sample.copy(droppedFrames = 1))
        diagnostics.record(sample.copy(nowMs = 1, droppedFrames = 2))
        diagnostics.record(sample.copy(nowMs = 9_999, droppedFrames = 3))
        assertEquals(1, lines.size)
        diagnostics.record(sample.copy(nowMs = 10_000, droppedFrames = 3))
        assertEquals(2, lines.size)
        assertTrue(lines.last().contains("droppedFrames=3"))
        diagnostics.record(sample.copy(nowMs = 30_000, droppedFrames = 3))
        assertEquals(2, lines.size)
    }

    @Test fun `normal speed and paused playback establish baseline without reporting historical symptoms`() {
        val lines = mutableListOf<String>()
        val diagnostics = YlPlaybackSpeedDiagnostics(lines::add)
        diagnostics.record(sample.copy(speed = 1f, droppedFrames = 10))
        diagnostics.record(sample.copy(droppedFrames = 10))
        diagnostics.record(sample.copy(playing = false, droppedFrames = 11))
        diagnostics.record(sample.copy(droppedFrames = 11))
        assertTrue(lines.isEmpty())
        diagnostics.record(sample.copy(droppedFrames = 12))
        assertEquals(1, lines.size)
    }

    @Test fun `healthy and invalid speed samples never log`() {
        val lines = mutableListOf<String>()
        val diagnostics = YlPlaybackSpeedDiagnostics(lines::add)
        diagnostics.record(sample)
        diagnostics.record(sample.copy(speed = Float.NaN, rebufferCount = 1))
        diagnostics.record(sample.copy(speed = Float.POSITIVE_INFINITY, rebufferCount = 2))
        assertTrue(lines.isEmpty())
    }

    @Test fun `new session clears throttling and counter baselines`() {
        val lines = mutableListOf<String>()
        val diagnostics = YlPlaybackSpeedDiagnostics(lines::add)
        diagnostics.record(sample.copy(nowMs = 1_000, rebufferCount = 3))
        diagnostics.reset()
        diagnostics.record(sample.copy(nowMs = 1_001, rebufferCount = 1))
        assertEquals(2, lines.size)
    }

    @Test fun `logging failures cannot interrupt playback or defeat rate limiting`() {
        var writes = 0
        val diagnostics = YlPlaybackSpeedDiagnostics { writes++; error("unavailable log sink") }
        diagnostics.record(sample.copy(audioUnderruns = 1))
        diagnostics.record(sample.copy(nowMs = 1, audioUnderruns = 2))
        assertEquals(1, writes)
    }

    @Test fun `byte saturation takes precedence over a slow measured transfer`() {
        val lines = mutableListOf<String>()
        val diagnostics = YlPlaybackSpeedDiagnostics(lines::add)
        diagnostics.transfer(0, 1_000, 100_000)
        diagnostics.record(sample.copy(bufferedMediaMs = 500, allocatedBytes = 2048,
            loading = true, videoBitrate = 2_000_000, rebufferCount = 1))
        assertTrue(lines.single().contains("supplyEvidence=byteBudgetReached"))
        assertTrue(lines.single().contains("transferBitsPerSecond=800000"))
    }

    @Test fun `recent measured transfer can indicate insufficient video supply only while loading with short buffer`() {
        val lines = mutableListOf<String>()
        val diagnostics = YlPlaybackSpeedDiagnostics(lines::add)
        diagnostics.transfer(0, 1_000, 100_000)
        diagnostics.record(sample.copy(nowMs = 10_000, bufferedMediaMs = 500,
            loading = true, videoBitrate = 2_000_000, rebufferCount = 1))
        assertTrue(lines.single().contains("supplyEvidence=belowVideoDemand"))
        diagnostics.record(sample.copy(nowMs = 20_000, bufferedMediaMs = 500,
            loading = true, videoBitrate = 2_000_000, rebufferCount = 2))
        assertTrue(lines.last().contains("supplyEvidence=unknown transferBitsPerSecond=unknown"))
    }

    @Test fun `missing short invalid and future transfer samples do not claim network capacity`() {
        for ((now, duration, bytes) in listOf(Triple(0L, 0, 1_000L), Triple(0L, 249, 1_000L),
            Triple(0L, 1_000, 0L), Triple(0L, 1_000, -1L), Triple(100L, 1_000, 1_000L))) {
            val lines = mutableListOf<String>()
            val diagnostics = YlPlaybackSpeedDiagnostics(lines::add)
            diagnostics.transfer(now, duration, bytes)
            diagnostics.record(sample.copy(bufferedMediaMs = 100, loading = true, rebufferCount = 1))
            assertTrue(lines.single().contains("supplyEvidence=unknown transferBitsPerSecond=unknown"))
        }
    }

    @Test fun `continuous observations report buffer consumption without counting speed changes or seeks`() {
        val lines = mutableListOf<String>()
        val diagnostics = YlPlaybackSpeedDiagnostics(lines::add)
        diagnostics.record(sample)
        diagnostics.record(sample.copy(nowMs = 1_000, mediaPositionMs = 1_500,
            bufferedMediaMs = 8_000, audioUnderruns = 1))
        assertTrue(lines.last().contains("bufferTrend=shrinking consumedMediaMs=1500"))
        diagnostics.record(sample.copy(nowMs = 11_000, mediaPositionMs = 999_000,
            bufferedMediaMs = 1_000, audioUnderruns = 2))
        assertTrue(lines.last().contains("bufferTrend=unknown consumedMediaMs=unknown"))
        diagnostics.record(sample.copy(nowMs = 21_000, mediaPositionMs = 1_000_000,
            speed = 2f, audioUnderruns = 3))
        assertTrue(lines.last().contains("bufferTrend=unknown consumedMediaMs=unknown"))
    }

    @Test fun `pause seek and reset invalidate supply evidence`() {
        for (clear in listOf<(YlPlaybackSpeedDiagnostics) -> Unit>(
            { it.discontinuity() }, { it.reset() }, { it.record(sample.copy(playing = false)) })) {
            val lines = mutableListOf<String>()
            val diagnostics = YlPlaybackSpeedDiagnostics(lines::add)
            diagnostics.transfer(0, 1_000, 100_000)
            clear(diagnostics)
            diagnostics.record(sample.copy(loading = true, rebufferCount = 1))
            assertTrue(lines.single().contains("transferBitsPerSecond=unknown"))
        }
    }
}
