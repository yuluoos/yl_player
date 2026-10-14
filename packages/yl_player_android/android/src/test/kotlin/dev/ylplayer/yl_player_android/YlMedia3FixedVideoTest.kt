package dev.ylplayer.yl_player_android

import androidx.media3.common.*
import androidx.media3.exoplayer.analytics.AnalyticsListener
import dev.ylplayer.yl_player_android.pigeon.*
import org.mockito.Mockito.*
import kotlin.test.*

class YlMedia3FixedVideoTest {
    private fun tracks(id: String, bitrate: Int = 900000) = Tracks(listOf(Tracks.Group(
        TrackGroup("g-$id", Format.Builder().setId(id).setSampleMimeType("video/avc").setCodecs("avc1.64001f")
            .setWidth(1280).setHeight(720).setAverageBitrate(bitrate).setFrameRate(30f).build()),
        false, intArrayOf(C.FORMAT_HANDLED), booleanArrayOf(true))))
    private fun event(): AnalyticsListener.EventTime = AnalyticsListener.EventTime(0, Timeline.EMPTY, 0, null, 0, Timeline.EMPTY, 0, null, 0, 0)

    @Test fun `read ahead input and scheduled future size stay pending until current Period mode changes`() = withCore { core, player, events ->
        val item = MediaItem.Builder().setMediaId("test").build()
        `when`(player.currentMediaItem).thenReturn(item)
        val timeline = mock(Timeline::class.java)
        `when`(timeline.isEmpty).thenReturn(false)
        `when`(timeline.getUidOfPeriod(0)).thenReturn("p0")
        `when`(timeline.getUidOfPeriod(1)).thenReturn("p1")
        `when`(timeline.getIndexOfPeriod("p0")).thenReturn(0)
        `when`(timeline.getIndexOfPeriod("p1")).thenReturn(1)
        `when`(player.currentTimeline).thenReturn(timeline)
        fun periodEvent(event: String, current: String) = AnalyticsListener.EventTime(0, Timeline.EMPTY, 0,
            androidx.media3.exoplayer.source.MediaSource.MediaPeriodId(event), 0, Timeline.EMPTY, 0,
            androidx.media3.exoplayer.source.MediaSource.MediaPeriodId(current), 0, 0)
        val high = tracks("high")
        `when`(player.currentTracks).thenReturn(high)
        `when`(player.videoFormat).thenReturn(high.groups.single().getTrackFormat(0))
        core.onTracksChanged(periodEvent("p0", "p0"), high)
        core.outputFrame(high.groups.single().getTrackFormat(0))
        core.selectVideoTrack("high")
        val lowFormat = high.groups.single().getTrackFormat(0).buildUpon().setId("low")
            .setWidth(640).setHeight(360).setAverageBitrate(200000).build()
        val low = Tracks(listOf(Tracks.Group(TrackGroup("next", lowFormat), false, intArrayOf(C.FORMAT_HANDLED), booleanArrayOf(true))))
        // Device reproduction: low input arrives at3270ms; output release is scheduled later,
        // and its size event arrives at3937ms while playing Period is still p0.
        `when`(player.videoFormat).thenReturn(lowFormat)
        `when`(player.currentPosition).thenReturn(3270)
        core.emitState()
        assertEquals(AndroidSizeMessage(1280.0, 720.0), events.lastSnapshot().geometry!!.encodedSize)
        core.outputFrame(lowFormat, "p1")
        core.emitState()
        assertEquals("high", events.lastSnapshot().videoSelection.fixedTrackId)
        assertEquals(AndroidSizeMessage(1280.0, 720.0), events.lastSnapshot().geometry!!.displaySize)
        core.field("active", true)
        core.seekTo(player.currentPosition) // Media3 can return without renderer reset or another size callback.
        `when`(player.currentPeriodIndex).thenReturn(1)
        `when`(player.currentPosition).thenReturn(4007)
        `when`(player.currentTracks).thenReturn(low)
        core.onTracksChanged(periodEvent("p1", "p1"), low)
        val current = events.lastSnapshot()
        assertEquals("trackUnavailable", current.videoSelection.reason)
        assertEquals(AndroidSizeMessage(640.0, 360.0), current.geometry!!.encodedSize)
        assertEquals(AndroidSizeMessage(640.0, 360.0), current.geometry!!.displaySize)
    }

    @Test fun `same Period explicit quality change publishes output size without waiting for new tracks`() = withCore { core, player, events ->
        val item = MediaItem.Builder().setMediaId("test").build()
        `when`(player.currentMediaItem).thenReturn(item)
        val high = tracks("high")
        val highFormat = high.groups.single().getTrackFormat(0)
        val lowFormat = highFormat.buildUpon().setId("low").setWidth(640).setHeight(360).setAverageBitrate(200000).build()
        val ladder = Tracks(listOf(Tracks.Group(TrackGroup("ladder", lowFormat, highFormat), true,
            intArrayOf(C.FORMAT_HANDLED, C.FORMAT_HANDLED), booleanArrayOf(true, false))))
        `when`(player.currentTracks).thenReturn(ladder)
        `when`(player.videoFormat).thenReturn(lowFormat)
        core.onTracksChanged(event(), ladder)
        core.outputFrame(lowFormat)
        core.selectVideoTrack("high")
        `when`(player.videoFormat).thenReturn(highFormat)
        core.emitState()
        assertEquals(AndroidSizeMessage(640.0, 360.0), events.lastSnapshot().geometry!!.encodedSize)
        core.outputFrame(highFormat)
        assertEquals("high", events.lastSnapshot().videoSelection.fixedTrackId)
        assertEquals(AndroidSizeMessage(1280.0, 720.0), events.lastSnapshot().geometry!!.encodedSize)
    }

    @Test fun `queued earlier output must not borrow the latest input coded format`() = withCore { core, player, events ->
        val item = MediaItem.Builder().setMediaId("test").build()
        `when`(player.currentMediaItem).thenReturn(item)
        val high = tracks("high").groups.single().getTrackFormat(0)
        val laterInput = high.buildUpon().setWidth(640).setHeight(360).build()
        `when`(player.videoFormat).thenReturn(laterInput)
        core.outputFrame(high)
        assertEquals(AndroidSizeMessage(1280.0, 720.0), events.lastSnapshot().geometry!!.encodedSize)
    }

    @Test fun `output coded metadata changes even when cropped VideoSize is unchanged`() = withCore { core, player, events ->
        val item = MediaItem.Builder().setMediaId("test").build()
        `when`(player.currentMediaItem).thenReturn(item)
        val original = Format.Builder().setWidth(1280).setHeight(720).build()
        core.outputFrame(original)
        val output = mock(android.media.MediaFormat::class.java)
        listOf("crop-left", "crop-right", "crop-top", "crop-bottom").forEach { `when`(output.containsKey(it)).thenReturn(true) }
        `when`(output.getInteger("crop-right")).thenReturn(1279)
        `when`(output.getInteger("crop-bottom")).thenReturn(719)
        // Coded padding changes, crop/output dimensions remain exactly 1280x720: no size event.
        core.outputFrame(original.buildUpon().setWidth(1296).setHeight(736).build(), mediaFormat = output)
        val geometry = events.lastSnapshot().geometry!!
        assertEquals(AndroidSizeMessage(1296.0, 736.0), geometry.encodedSize)
        assertEquals(AndroidSizeMessage(1280.0, 720.0), geometry.displaySize)
    }

    @Test fun `finite DASH public clock cannot run beyond programme while AudioTrack drains`() = withCore(coreSource = source().copy(format = AndroidMediaFormat.DASH)) { core, player, events ->
        core.javaClass.getDeclaredField("active").apply { isAccessible = true }.setBoolean(core, true)
        `when`(player.duration).thenReturn(3500)
        `when`(player.currentPosition).thenReturn(3571)
        `when`(player.bufferedPosition).thenReturn(3600)
        core.emitState()
        val timeline = events.lastSnapshot().timeline
        assertEquals(3500, timeline.durationMs)
        assertEquals(3500, timeline.positionMs)
        assertEquals(3500, timeline.bufferedPositionMs)
        // Do not rewrite Media3's native clock or turn this into output timing evidence.
        assertEquals(3571, player.currentPosition)
    }

    @Test fun `actual renderer reset hides old picture before a new output can publish`() = withCore(coreSource = source().copy(format = AndroidMediaFormat.DASH)) { core, _, events ->
        core.outputFrame(Format.Builder().setWidth(320).setHeight(180).build())
        assertNotNull(events.lastSnapshot().geometry)
        core.outputObserver.reset()
        core.emitState()
        assertNull(events.lastSnapshot().geometry)
    }

    @Test fun `DASH output coverage follows actual format and half open period clock`() = withCore { core, player, events ->
        val timeline = mock(Timeline::class.java)
        `when`(timeline.isEmpty).thenReturn(false)
        `when`(timeline.getIndexOfPeriod("p0")).thenReturn(0)
        val period = Timeline.Period()
        `when`(timeline.getPeriod(anyInt(), any(Timeline.Period::class.java))).thenReturn(period)
        `when`(player.currentTimeline).thenReturn(timeline)
        val coverage = YlDashVideoCoverage.merge(listOf(
            YlDashVideoCoverage.Range(YlDashTime.of(1, 2), YlDashTime.of(1)),
            YlDashVideoCoverage.Range(YlDashTime.of(2), YlDashTime.of(3))), YlDashTime.of(4))
        val format = Format.Builder().setWidth(320).setHeight(180).setMetadata(Metadata(coverage, coverage)).build()
        core.outputFrame(format)
        for ((ms, visible) in listOf(0L to false, 499L to false, 500L to true, 999L to true,
            1000L to false, 1999L to false, 2000L to true, 3000L to false)) {
            `when`(player.currentPosition).thenReturn(ms)
            core.emitState()
            assertEquals(visible, events.lastSnapshot().geometry != null, "position=$ms")
        }
        // Reading-ahead/input format cannot overwrite the accepted output coverage.
        val input = format.buildUpon().setMetadata(null).build()
        `when`(player.videoFormat).thenReturn(input)
        core.emitState()
        assertNull(events.lastSnapshot().geometry)
    }

    @Test fun `output generations fence queued frames and deduplicate without losing reset recovery`() {
        val queued = mutableListOf<() -> Unit>()
        val received = mutableListOf<Pair<Any?, AndroidVideoGeometryMessage?>>()
        val observer = YlVideoOutputObserver(queued::add) { uid, geometry, _ -> received.add(uid to geometry) }
        val format = Format.Builder().setWidth(1280).setHeight(720).build()
        // Nonzero renderer clock and submillisecond difference: exact integer stream keys,
        // not division of presentation timestamps or matching track IDs/format dimensions.
        val offset = 1_000_000_001L
        observer.stream(offset + 7, offset, "p0")
        observer.stream(offset + 4_000_008, offset + 4_000_001, "p1")
        observer.outputFormat(format, null)
        repeat(120) { observer.rendered(offset + 7, offset) }
        assertEquals(1, queued.size)
        queued.removeAt(0)()
        assertEquals("p0", received.single().first)
        observer.rendered(offset + 4_000_008, offset + 4_000_001)
        observer.reset(offset + 7, offset, "p0") // genuine seek, prior queued p1 must not publish
        queued.toList().forEach { it() }; queued.clear()
        assertEquals(listOf("p0", null), received.map { it.first })
        observer.rendered(offset + 4_000_008, offset + 4_000_001)
        assertTrue(queued.isEmpty())
        observer.rendered(offset + 7, offset) // same geometry is republished after actual reset
        queued.removeAt(0)()
        assertEquals("p0", received.last().first)
        observer.outputFormat(format.buildUpon().setWidth(640).setHeight(360).build(), null)
        observer.rendered(offset + 7, offset)
        observer.invalidate() // stop/new source before worker receives changed output
        queued.removeAt(0)()
        assertEquals(1280.0, received.last().second!!.encodedSize.width)
    }

    @Test fun `core preserves fixed and catalog across transient emptiness then publishes PD01 and sticky reason`() = withCore { core, player, events ->
        val item = MediaItem.Builder().setMediaId("test").build()
        `when`(player.currentMediaItem).thenReturn(item)
        val first = tracks("high")
        `when`(player.currentTracks).thenReturn(first)
        core.onTracksChanged(event(), first)
        core.selectVideoTrack("high")
        val saved = core.snapshotRestorePoint()
        assertEquals("high", saved.videoSelection.fixedTrackId)
        core.onTracksChanged(event(), Tracks.EMPTY)
        `when`(player.currentTracks).thenReturn(Tracks.EMPTY)
        assertEquals("high", events.lastSnapshot().videoSelection.fixedTrackId)
        assertEquals("high", events.lastSnapshot().videoTracks.single().id)
        assertFailsWith<YlBoundaryException> { core.selectVideoTrack("high") }
        val next = tracks("low", 200000)
        `when`(player.currentTracks).thenReturn(next)
        core.onTracksChanged(event(), next)
        assertNull(events.lastSnapshot().videoSelection.fixedTrackId)
        assertEquals("trackUnavailable", events.lastSnapshot().videoSelection.reason)
        core.emitState()
        assertEquals("trackUnavailable", events.lastSnapshot().videoSelection.reason)
        assertEquals("high", saved.videoSelection.fixedTrackId)
        core.stop()
        assertEquals("initial", events.lastSnapshot().videoSelection.reason)
        assertTrue(events.lastSnapshot().videoTracks.isEmpty())
    }

    @Test fun `lookahead and delayed prior Period callbacks cannot release fixed mode and stop fences old callbacks`() = withCore { core, player, events ->
        val item = MediaItem.Builder().setMediaId("test").build()
        `when`(player.currentMediaItem).thenReturn(item)
        val first = tracks("high")
        `when`(player.currentTracks).thenReturn(first)
        core.onTracksChanged(event(), first); core.selectVideoTrack("high")
        val current = androidx.media3.exoplayer.source.MediaSource.MediaPeriodId("current")
        val future = androidx.media3.exoplayer.source.MediaSource.MediaPeriodId("future")
        val lookahead = AnalyticsListener.EventTime(0, Timeline.EMPTY, 0, future, 0, Timeline.EMPTY, 0, current, 0, 0)
        core.onTracksChanged(lookahead, tracks("low", 200000))
        assertEquals("high", events.lastSnapshot().videoSelection.fixedTrackId)
        val timeline = mock(Timeline::class.java)
        `when`(timeline.isEmpty).thenReturn(false)
        `when`(timeline.getUidOfPeriod(0)).thenReturn("current")
        `when`(player.currentTimeline).thenReturn(timeline)
        val prior = androidx.media3.exoplayer.source.MediaSource.MediaPeriodId("prior")
        val delayed = AnalyticsListener.EventTime(0, Timeline.EMPTY, 0, prior, 0, Timeline.EMPTY, 0, prior, 0, 0)
        core.onTracksChanged(delayed, tracks("old-low", 200000))
        assertEquals("high", events.lastSnapshot().videoSelection.fixedTrackId)
        core.stop()
        core.onTracksChanged(event(), first)
        assertEquals("initial", events.lastSnapshot().videoSelection.reason)
        assertTrue(events.lastSnapshot().videoTracks.isEmpty())
    }

    @Test fun `restore carries semantic fixed intent and rebinds recreated tracks before publication`() = withCore { core, player, events ->
        val item = MediaItem.Builder().setMediaId("test").build()
        `when`(player.currentMediaItem).thenReturn(item)
        val first = tracks("high")
        `when`(player.currentTracks).thenReturn(first)
        core.onTracksChanged(event(), first); core.selectVideoTrack("high")
        val saved = core.snapshotRestorePoint()
        core.restore(saved)
        val recreated = tracks("new-high")
        `when`(player.currentTracks).thenReturn(recreated)
        core.onTracksChanged(event(), recreated)
        assertEquals("new-high", events.lastSnapshot().videoSelection.fixedTrackId)
        assertEquals("user", events.lastSnapshot().videoSelection.reason)
        assertEquals("new-high", events.lastSnapshot().videoTracks.single().id)
        assertEquals(saved.videoSelection.quality, core.snapshotRestorePoint().videoSelection.quality)
    }

    @Test fun `fixed cap conflict leaves policy and restore point unchanged and health cannot downgrade`() = withCore { core, player, events ->
        val item = MediaItem.Builder().setMediaId("test").build()
        `when`(player.currentMediaItem).thenReturn(item)
        val first = tracks("high")
        `when`(player.currentTracks).thenReturn(first)
        core.onTracksChanged(event(), first)
        core.setVideoConstraints(AndroidVideoConstraintsMessage(maxWidth = 1920))
        core.selectVideoTrack("high")
        assertFailsWith<YlBoundaryException> { core.setVideoConstraints(AndroidVideoConstraintsMessage(maxWidth = 640)) }
        assertEquals(1920L, core.snapshotRestorePoint().maxWidth)
        core.field("selectedVideoBitrate", 900000)
        core.field("availableVideoBitrates", listOf(900000, 200000))
        val method = core.javaClass.getDeclaredMethod("applyRecoveryAction", YlRecoveryAction::class.java).apply { isAccessible = true }
        method.invoke(core, YlRecoveryAction.DowngradeOneStep)
        core.emitState()
        assertEquals("high", events.lastSnapshot().videoSelection.fixedTrackId)
        val ceiling = core.javaClass.getDeclaredField("adaptiveBitrateCeiling").apply { isAccessible = true }.get(core)
        assertNull(ceiling)
    }
}
