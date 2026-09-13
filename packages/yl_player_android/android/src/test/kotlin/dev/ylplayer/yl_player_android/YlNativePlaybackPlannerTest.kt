package dev.ylplayer.yl_player_android

import kotlin.test.Test
import kotlin.test.assertEquals

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
    fun `rejects software video above 720p or 30fps`() {
        val planner = YlNativePlaybackPlanner { false }

        assertEquals(
            YlNativeVideoPath.UNSUPPORTED,
            planner.chooseVideoPath(hevcMain10.copy(width = 1920, height = 1080)),
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
}
