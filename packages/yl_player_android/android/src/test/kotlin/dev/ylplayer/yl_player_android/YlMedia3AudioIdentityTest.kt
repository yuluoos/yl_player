package dev.ylplayer.yl_player_android

import androidx.media3.common.*
import androidx.media3.exoplayer.analytics.AnalyticsListener
import dev.ylplayer.yl_player_android.pigeon.*
import org.mockito.Mockito.*
import kotlin.test.*

class YlMedia3AudioIdentityTest {
    @Test fun `owned gap hides stale video and accepts content commands without publishing silence as an audio track`() = withCore(
        coreSource = AndroidSourceMessage(AndroidSourceKind.NETWORK, "https://example.test/media.mpd", AndroidStreamIntent.ON_DEMAND, AndroidMediaFormat.DASH)
    ) { core, player, events ->
        val item = MediaItem.Builder().setMediaId("test").build()
        `when`(player.currentMediaItem).thenReturn(item)
        val video = Format.Builder().setId("v").setSampleMimeType("video/avc").setCodecs("avc1.64001f")
            .setWidth(320).setHeight(180).setAverageBitrate(100000).build()
        val actual = tracks(sound("main"), video)
        `when`(player.currentTracks).thenReturn(actual); core.onTracksChanged(event(), actual)
        core.outputFrame(video)
        val initial = events.lastSnapshot()
        val id = initial.audioTracks.single().id
        val factory = core.javaClass.getDeclaredField("sourceFactory").apply { isAccessible = true }.get(core)
        val groups = factory.javaClass.getDeclaredField("dashGapGroups").apply { isAccessible = true }.get(factory) as YlDashGapGroups
        val gap = TrackGroup(Format.Builder().setSampleMimeType("audio/raw").setSampleRate(44100).setChannelCount(2).setPcmEncoding(C.ENCODING_PCM_16BIT).build())
        groups.add(gap)
        assertFalse(groups.contains(TrackGroup(gap.getFormat(0))), "Equal untrusted formats cannot impersonate owned timing PCM")
        val silent = Tracks(listOf(Tracks.Group(gap, false, intArrayOf(C.FORMAT_HANDLED), booleanArrayOf(true))))
        `when`(player.currentTracks).thenReturn(silent); core.onTracksChanged(event(), silent)
        assertNull(events.lastSnapshot().geometry)
        assertEquals(initial.audioTracks, events.lastSnapshot().audioTracks)
        core.selectAudioTrack(id)
        assertEquals(id, core.snapshotRestorePoint().selectedAudioTrack)
        assertEquals(YlFailureKind.TRACK_NOT_FOUND, assertFailsWith<YlBoundaryException> { core.selectAudioTrack("absent") }.kind)
        assertTrue(events.filterIsInstance<YlEngineEvent.Failed>().isEmpty())
        `when`(player.currentTracks).thenReturn(actual); core.onTracksChanged(event(), actual)
        assertEquals(initial.geometry, events.lastSnapshot().geometry)
        groups.remove(gap); assertFalse(groups.contains(gap))
    }
    private fun sound(id: String?, language: String = "en", role: Int = C.ROLE_FLAG_MAIN) = Format.Builder()
        .setId(id).setSampleMimeType("audio/mp4a-latm").setCodecs("mp4a.40.2")
        .setLanguage(language).setRoleFlags(role).setSampleRate(48000).setChannelCount(2).setAverageBitrate(64000).build()
    private fun tracks(vararg formats: Format) = Tracks(formats.mapIndexed { index, format ->
        Tracks.Group(TrackGroup("group-$index", format), false, intArrayOf(C.FORMAT_HANDLED), booleanArrayOf(index == 0))
    })
    private fun event() = AnalyticsListener.EventTime(0, Timeline.EMPTY, 0, null, 0, Timeline.EMPTY, 0, null, 0, 0)
    @Test fun `same declared id with different audio roles never collides`() = withCore { core, player, events ->
        val item = MediaItem.Builder().setMediaId("test").build()
        `when`(player.currentMediaItem).thenReturn(item)
        val actual = tracks(sound("duplicate"), sound("duplicate", role = C.ROLE_FLAG_COMMENTARY))
        `when`(player.currentTracks).thenReturn(actual)
        core.onTracksChanged(event(), actual)
        assertEquals(2, events.lastSnapshot().audioTracks.map { it.id }.toSet().size)
    }
    @Test fun `missing format ids follow role when groups reorder`() = withCore { core, player, events ->
        val item = MediaItem.Builder().setMediaId("test").build()
        `when`(player.currentMediaItem).thenReturn(item)
        val main = sound(null); val comment = sound(null, role = C.ROLE_FLAG_COMMENTARY)
        val first = tracks(main, comment)
        `when`(player.currentTracks).thenReturn(first); core.onTracksChanged(event(), first)
        val ids = events.lastSnapshot().audioTracks.map { it.id }
        val next = tracks(comment, main)
        `when`(player.currentTracks).thenReturn(next); core.onTracksChanged(event(), next)
        assertEquals(ids.reversed(), events.lastSnapshot().audioTracks.map { it.id })
    }

    @Test fun `accepted choice survives stale observed selection and invalid command`() = withCore { core, player, events ->
        val item = MediaItem.Builder().setMediaId("test").build(); `when`(player.currentMediaItem).thenReturn(item)
        val actual = tracks(sound("main"), sound("comment", role = C.ROLE_FLAG_COMMENTARY))
        `when`(player.currentTracks).thenReturn(actual); core.onTracksChanged(event(), actual)
        val id = events.lastSnapshot().audioTracks[1].id
        core.selectAudioTrack(id)
        assertEquals(id, core.snapshotRestorePoint().selectedAudioTrack)
        assertTrue(events.lastSnapshot().audioTracks[0].isSelected, "Accepted intent must not pretend that Media3 has observed the choice")
        assertEquals(YlFailureKind.TRACK_NOT_FOUND, assertFailsWith<YlBoundaryException> { core.selectAudioTrack("missing") }.kind)
        assertEquals(id, core.snapshotRestorePoint().selectedAudioTrack)
        core.onTracksChanged(event(), Tracks.EMPTY)
        assertEquals(2, events.lastSnapshot().audioTracks.size)
        `when`(player.currentTracks).thenReturn(Tracks.EMPTY)
        assertFailsWith<YlBoundaryException> { core.selectAudioTrack(id) }
        assertEquals(id, core.snapshotRestorePoint().selectedAudioTrack)
    }
    @Test fun `actual missing audio in nonempty Period reports error instead of replacing choice`() = withCore { core, player, events ->
        val item = MediaItem.Builder().setMediaId("test").build(); `when`(player.currentMediaItem).thenReturn(item)
        val actual = tracks(sound("main")); `when`(player.currentTracks).thenReturn(actual); core.onTracksChanged(event(), actual)
        val id = events.lastSnapshot().audioTracks.single().id; core.selectAudioTrack(id)
        val video = Format.Builder().setSampleMimeType("video/avc").build()
        val next = tracks(video); `when`(player.currentTracks).thenReturn(next); core.onTracksChanged(event(), next)
        assertEquals(YlFailureKind.TRACK_NOT_FOUND, events.filterIsInstance<YlEngineEvent.Failed>().single().kind)
        assertEquals(id, core.snapshotRestorePoint().selectedAudioTrack)
        assertEquals(AndroidPlaybackStatus.FAILED, events.lastSnapshot().status)
    }
    @Test fun `DASH restore rebinds declared content despite representation names and array order`() = withCore(
        coreSource = AndroidSourceMessage(AndroidSourceKind.NETWORK, "https://example.test/media.mpd", AndroidStreamIntent.ON_DEMAND, AndroidMediaFormat.DASH)
    ) { core, player, events ->
        val item = MediaItem.Builder().setMediaId("test").build(); `when`(player.currentMediaItem).thenReturn(item)
        fun dash(vararg pairs: Pair<String, Format>) = Tracks(pairs.map { (id, f) -> Tracks.Group(TrackGroup(id, f), false, intArrayOf(C.FORMAT_HANDLED), booleanArrayOf(false)) })
        val first = dash("10" to sound("a"), "20" to sound("b", role = C.ROLE_FLAG_COMMENTARY))
        `when`(player.currentTracks).thenReturn(first); core.onTracksChanged(event(), first)
        val id = events.lastSnapshot().audioTracks[1].id; core.selectAudioTrack(id)
        val saved = core.snapshotRestorePoint(); core.restore(saved)
        val next = dash("20" to sound("renamed-b", role = C.ROLE_FLAG_COMMENTARY), "10" to sound("renamed-a"))
        `when`(player.currentTracks).thenReturn(next); core.onTracksChanged(event(), next)
        assertEquals(id, events.lastSnapshot().audioTracks[0].id)
        assertEquals(id, core.snapshotRestorePoint().selectedAudioTrack)
        assertTrue(events.filterIsInstance<YlEngineEvent.Failed>().isEmpty())
        core.stop(); core.onTracksChanged(event(), first)
        assertNull(core.snapshotRestorePoint().selectedAudioTrack)
        assertTrue(events.lastSnapshot().audioTracks.isEmpty())
        assertEquals(YlFailureKind.SESSION_STALE, assertFailsWith<YlBoundaryException> { core.selectAudioTrack(id) }.kind)
    }
    @Test fun `lookahead and late Period catalogs never replace public audio directory`() = withCore { core, player, events ->
        val item = MediaItem.Builder().setMediaId("test").build(); `when`(player.currentMediaItem).thenReturn(item)
        val first = tracks(sound("main")); `when`(player.currentTracks).thenReturn(first); core.onTracksChanged(event(), first)
        val id = events.lastSnapshot().audioTracks.single().id; core.selectAudioTrack(id)
        val current = androidx.media3.exoplayer.source.MediaSource.MediaPeriodId("current")
        val next = androidx.media3.exoplayer.source.MediaSource.MediaPeriodId("future")
        val ahead = AnalyticsListener.EventTime(0, Timeline.EMPTY, 0, next, 0, Timeline.EMPTY, 0, current, 0, 0)
        core.onTracksChanged(ahead, tracks(sound("other")))
        assertEquals(id, events.lastSnapshot().audioTracks.single().id)
        val timeline = mock(Timeline::class.java); `when`(timeline.isEmpty).thenReturn(false)
        `when`(timeline.getUidOfPeriod(0)).thenReturn("current"); `when`(player.currentTimeline).thenReturn(timeline)
        core.onTracksChanged(AnalyticsListener.EventTime(0, Timeline.EMPTY, 0, next, 0, Timeline.EMPTY, 0, next, 0, 0), tracks(sound("other")))
        assertEquals(id, events.lastSnapshot().audioTracks.single().id)
    }
}
