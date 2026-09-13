package dev.ylplayer.yl_player_android

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class YlNativePlaybackPlannerTest {
    private val h264 = YlNativeStreamInfo(0, YlNativeStreamKind.VIDEO, YlNativeCodec.H264, 1280, 720, 30.0)
    private val hevcMain10 = YlNativeStreamInfo(0, YlNativeStreamKind.VIDEO, YlNativeCodec.HEVC, 1280, 720, 30.0, profile = 2)

    @Test
    fun `uses hardware after FFmpeg demux when codec configuration is supported`() {
        val planner = YlNativePlaybackPlanner { true }

        assertEquals(YlNativeVideoPath.HARDWARE, planner.chooseVideoPath(h264))
    }

    @Test
    fun `uses software for unsupported h264 or hevc configuration within bounded envelope`() {
        val planner = YlNativePlaybackPlanner { false }

        assertEquals(YlNativeVideoPath.SOFTWARE, planner.chooseVideoPath(hevcMain10))
    }

    @Test
    fun `uses software for 1080p HEVC when device decoders reject its profile level`() {
        val planner = YlNativePlaybackPlanner { false }

        assertEquals(
            YlNativeVideoPath.SOFTWARE,
            planner.chooseVideoPath(
                hevcMain10.copy(width = 1920, height = 1080, profile = 1, level = 186),
            ),
        )
    }

    @Test
    fun `rejects software video above 1080p or 30fps`() {
        val planner = YlNativePlaybackPlanner { false }

        assertEquals(
            YlNativeVideoPath.UNSUPPORTED,
            planner.chooseVideoPath(hevcMain10.copy(width = 2560, height = 1440)),
        )
        assertEquals(
            YlNativeVideoPath.UNSUPPORTED,
            planner.chooseVideoPath(hevcMain10.copy(frameRate = 60.0)),
        )
    }

    @Test
    fun `rejects software codecs outside approved h264 and hevc scope`() {
        val planner = YlNativePlaybackPlanner { false }

        assertEquals(
            YlNativeVideoPath.UNSUPPORTED,
            planner.chooseVideoPath(h264.copy(codec = YlNativeCodec.VP9)),
        )
    }

    @Test
    fun `main10 level 62 remains software when hardware configuration probe rejects its level`() {
        val planner = YlNativePlaybackPlanner { stream -> stream.level < 186 }

        assertEquals(
            YlNativeVideoPath.SOFTWARE,
            planner.chooseVideoPath(hevcMain10.copy(level = 186)),
        )
    }

    @Test
    fun `full video queue waits for presentation time instead of rendering a burst`() {
        assertEquals(
            YlVideoPacingAction.WAIT,
            YlVideoPacingPolicy.action(
                presentationTimeUs = 1_500_000,
                clockUs = 1_000_000,
            ),
        )
        assertEquals(
            YlVideoPacingAction.PRESENT,
            YlVideoPacingPolicy.action(
                presentationTimeUs = 1_010_000,
                clockUs = 1_000_000,
            ),
        )
    }

    @Test
    fun `software video pacing uses decoded frame time instead of reordered packet time`() {
        val rendered = mutableListOf<Long>()
        val frames = YlSoftwareVideoFrames(
            decodeFrameTimestamps = { longArrayOf(56_000) },
            renderNextFrame = {
                rendered += it
                true
            },
        )

        frames.decode(
            YlNativePacket(
                streamIndex = 0,
                data = byteArrayOf(1),
                presentationTimeUs = 156_000,
                decodeTimeUs = 56_000,
                durationUs = 33_000,
                keyFrame = false,
            ),
        )
        frames.renderDue(clockUs = 100_000)

        assertEquals(listOf(56_000L), rendered)
    }

    @Test
    fun `normal speed does not install muting playback parameters`() {
        assertEquals(
            false,
            YlAudioPlaybackRatePolicy.shouldApply(speed = 1f, parametersWereApplied = false),
        )
        assertEquals(
            true,
            YlAudioPlaybackRatePolicy.shouldApply(speed = 1.25f, parametersWereApplied = false),
        )
        assertEquals(
            true,
            YlAudioPlaybackRatePolicy.shouldApply(speed = 1f, parametersWereApplied = true),
        )
    }

    @Test
    fun `non blocking pcm write retains partial data for a later scheduler turn`() {
        val calls = mutableListOf<Pair<Int, Int>>()
        val pending = YlPendingPcmWrite()
        pending.enqueue(byteArrayOf(1, 2, 3, 4))

        val blockedBytes = pending.writeAvailable { _, offset, length ->
            calls += offset to length
            0
        }
        val partialBytes = pending.writeAvailable { _, offset, length ->
            calls += offset to length
            2
        }
        val completedBytes = pending.writeAvailable { _, offset, length ->
            calls += offset to length
            length
        }

        assertEquals(0, blockedBytes)
        assertEquals(2, partialBytes)
        assertEquals(2, completedBytes)
        assertEquals(listOf(0 to 4, 0 to 4, 2 to 2), calls)
        assertFalse(pending.hasData)
    }

    @Test
    fun `pcm flush discards bytes that were not accepted by audio track`() {
        val pending = YlPendingPcmWrite()
        pending.enqueue(byteArrayOf(1, 2, 3))
        pending.writeAvailable { _, _, _ -> 1 }

        pending.clear()

        assertFalse(pending.hasData)
    }

    @Test
    fun `audio clock interpolates between coarse hardware timestamps`() {
        assertEquals(
            115_000L,
            YlAudioClockEstimator.positionUs(
                firstPresentationUs = 0,
                sampleRate = 48_000,
                hardwareFramePosition = 4_800,
                hardwareTimestampNs = 1_000_000_000,
                nowNs = 1_015_000_000,
                speed = 1.0,
                writtenFrames = 24_000,
            ),
        )
    }

    @Test
    fun `audio clock interpolation never advances beyond written pcm`() {
        assertEquals(
            500_000L,
            YlAudioClockEstimator.positionUs(
                firstPresentationUs = 0,
                sampleRate = 48_000,
                hardwareFramePosition = 23_900,
                hardwareTimestampNs = 1_000_000_000,
                nowNs = 1_100_000_000,
                speed = 1.0,
                writtenFrames = 24_000,
            ),
        )
    }
}
