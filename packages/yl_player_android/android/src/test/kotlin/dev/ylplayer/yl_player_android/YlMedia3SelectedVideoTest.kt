package dev.ylplayer.yl_player_android

import dev.ylplayer.yl_player_android.pigeon.AndroidTrackKind
import dev.ylplayer.yl_player_android.pigeon.AndroidTrackMessage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class YlMedia3SelectedVideoTest {
    @Test
    fun `ready audio with unselected declared video is a decoder fallback signal`() {
        val snapshot = YlEngineSnapshot(videoTracks = listOf(
            AndroidTrackMessage("v", AndroidTrackKind.VIDEO, codec = "hevc", isSelected = false),
        ))

        val failure = assertFailsWith<YlBoundaryException> { requireSelectedVideo(snapshot) }

        assertEquals(YlFailureKind.DECODER_UNSUPPORTED, failure.kind)
    }

    @Test
    fun `audio only and selected video remain valid`() {
        requireSelectedVideo(YlEngineSnapshot())
        requireSelectedVideo(YlEngineSnapshot(videoTracks = listOf(
            AndroidTrackMessage("v", AndroidTrackKind.VIDEO, isSelected = true),
        )))
    }

    @Test
    fun `ready video with an unselected declared audio track requests audio fallback`() {
        val snapshot = YlEngineSnapshot(
            videoTracks = listOf(
                AndroidTrackMessage("v", AndroidTrackKind.VIDEO, codec = "h264", isSelected = true),
            ),
            audioTracks = listOf(
                AndroidTrackMessage("a", AndroidTrackKind.AUDIO, codec = "ac3", isSelected = false),
            ),
        )

        val failure = assertFailsWith<YlBoundaryException> { requireSelectedVideo(snapshot) }

        assertEquals(YlFailureKind.DECODER_UNSUPPORTED, failure.kind)
    }
}
