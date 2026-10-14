package dev.ylplayer.yl_player_android

import androidx.media3.common.*
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import org.mockito.Mockito.*
import androidx.media3.exoplayer.trackselection.ExoTrackSelection
import androidx.media3.exoplayer.trackselection.MappingTrackSelector
import androidx.media3.exoplayer.source.TrackGroupArray
import kotlin.test.*

class YlVideoSelectionPolicyTest {
    private val caps = AndroidQualityConstraint()
    private val envelope = YlVideoEnvelope(1920, 1080, 60.0)
    private fun format(id: String, bitrate: Int = 900000, codec: String = "avc1.64001f") = Format.Builder()
        .setId(id).setSampleMimeType("video/avc").setCodecs(codec).setWidth(1280).setHeight(720)
        .setAverageBitrate(bitrate).setFrameRate(30f).build()
    private fun tracks(vararg formats: Format, supported: Int = C.FORMAT_HANDLED) = Tracks(listOf(
        Tracks.Group(TrackGroup("period-group", *formats), true, IntArray(formats.size) { supported }, BooleanArray(formats.size))))
    private fun android(action: () -> Unit) {
        mockStatic(android.text.TextUtils::class.java) { invocation ->
            if (invocation.method.name == "isEmpty") (invocation.arguments[0] as? CharSequence).isNullOrEmpty() else invocation.callRealMethod()
        }.use {
            mockConstruction(android.util.SparseArray::class.java).use {
                mockConstruction(android.util.SparseBooleanArray::class.java) { value, _ ->
                    `when`(value.clone()).thenReturn(value)
                }.use {
                    mockStatic(android.util.Pair::class.java).use { pairs ->
                        pairs.`when`<android.util.Pair<Any?, Any?>> { android.util.Pair.create<Any?, Any?>(any(), any()) }.thenAnswer { invocation ->
                            mock(android.util.Pair::class.java).also { pair ->
                                android.util.Pair::class.java.getField("first").set(pair, invocation.getArgument<Any?>(0))
                                android.util.Pair::class.java.getField("second").set(pair, invocation.getArgument<Any?>(1))
                            }
                        }
                        mockStatic(android.os.SystemClock::class.java).use { action() }
                    }
                }
            }
        }
    }

    @Test fun `fixed override contains exactly requested track and survives changed IDs and order`() = android {
        val first = tracks(format("low", 200000), format("high"))
        val selected = YlVideoSelectionPolicy.select(first, "high", caps, envelope)
        val parameters = YlVideoSelectionPolicy.parameters(DefaultTrackSelector.Parameters.Builder().build(), first, selected)
        assertEquals(listOf(1), parameters.overrides.values.single().trackIndices)
        val next = tracks(format("new-high"), format("new-low", 200000))
        val rebound = YlVideoSelectionPolicy.reconcile(next, selected, caps, envelope)
        assertEquals("new-high", rebound.fixedTrackId)
        assertEquals(listOf(0), YlVideoSelectionPolicy.parameters(parameters, next, rebound).overrides.values.single().trackIndices)
        assertEquals("high", selected.fixedTrackId) // immutable captured restore state
    }

    @Test fun `absence returns auto and clears override while transient empty groups retain fixed intent`() = android {
        val first = tracks(format("high"), format("low", 200000))
        val selected = YlVideoSelectionPolicy.select(first, "high", caps, envelope)
        assertEquals(selected, YlVideoSelectionPolicy.reconcile(Tracks.EMPTY, selected, caps, envelope))
        assertFailsWith<YlBoundaryException> { YlVideoSelectionPolicy.select(Tracks.EMPTY, "high", caps, envelope) }
        val next = tracks(format("low-next", 200000))
        val auto = YlVideoSelectionPolicy.reconcile(next, selected, caps, envelope)
        assertNull(auto.fixedTrackId)
        assertEquals("trackUnavailable", auto.reason)
        val previous = YlVideoSelectionPolicy.parameters(DefaultTrackSelector.Parameters.Builder().build(), first, selected)
        assertTrue(YlVideoSelectionPolicy.parameters(previous, next, auto).overrides.isEmpty())
        assertEquals(auto, YlVideoSelectionPolicy.reconcile(next, auto, caps, envelope))
    }

    @Test fun `same resolution is not identity and duplicate semantic identity is rejected`() = android {
        val fixed = YlVideoSelectionPolicy.select(tracks(format("high")), "high", caps, envelope)
        for (changed in listOf(format("high", 899999), format("high", codec = "avc1.4d401f"))) {
            assertEquals("trackUnavailable", YlVideoSelectionPolicy.reconcile(tracks(changed), fixed, caps, envelope).reason)
        }
        assertFailsWith<YlBoundaryException> {
            YlVideoSelectionPolicy.reconcile(tracks(format("a"), format("b")), fixed, caps, envelope)
        }
        assertFailsWith<YlBoundaryException> { YlVideoSelectionPolicy.select(tracks(format("a"), format("a", 200000)), "a", caps, envelope) }
        assertFailsWith<YlBoundaryException> { YlVideoSelectionPolicy.reconcile(tracks(format("duplicate-id"), format("duplicate-id", 200000)), fixed, caps, envelope) }
    }

    @Test fun `unsupported decoder cap conflict unknown constrained metadata and HDR fail safely`() = android {
        val high = format("high")
        val fixed = YlVideoSelectionPolicy.select(tracks(high), "high", caps, envelope)
        for (bad in listOf(AndroidQualityConstraint(maxWidth = 640), AndroidQualityConstraint(maxHeight = 360), AndroidQualityConstraint(maxBitrate = 200000))) {
            assertFailsWith<YlBoundaryException> { YlVideoSelectionPolicy.validate(fixed.quality!!, bad, envelope) }
        }
        assertFailsWith<YlBoundaryException> { YlVideoSelectionPolicy.select(tracks(high, supported = C.FORMAT_EXCEEDS_CAPABILITIES), "high", caps, envelope) }
        assertFailsWith<YlBoundaryException> { YlVideoSelectionPolicy.select(tracks(high.buildUpon().setFrameRate(Format.NO_VALUE.toFloat()).build()), "high", caps, envelope) }
        assertFailsWith<YlBoundaryException> { YlVideoSelectionPolicy.select(tracks(high.buildUpon().setColorInfo(ColorInfo.Builder().setColorTransfer(C.COLOR_TRANSFER_ST2084).build()).build()), "high", caps, envelope) }
        assertFailsWith<YlBoundaryException> { YlVideoSelectionPolicy.select(tracks(high.buildUpon().setSampleMimeType("video/hevc").setCodecs("hvc1.2.4.L93").build()), "high", caps, envelope) }
    }

    @Test fun `selection boundary fixes recreated group before next Period prebuffer without changing public intent`() = android {
        val initial = tracks(format("low", 200000), format("high"))
        val fixed = YlVideoSelectionPolicy.select(initial, "high", caps, envelope)
        val params = DefaultTrackSelector.Parameters.Builder().build().buildUpon()
            // The application has accepted fixed quality while Exo's queued parameters still
            // contain a prior health cap. Selection must use one coherent accepted policy.
            .setMaxVideoBitrate(200000)
            .setConstrainAudioChannelCountToDeviceCapabilities(false).build()
        val withOldOverride = YlVideoSelectionPolicy.parameters(params, initial, fixed)
        val selector = YlFixedVideoTrackSelector(mock(android.content.Context::class.java), withOldOverride)
        selector.fixedIntent = YlFixedVideoIntent(fixed.quality!!, caps, envelope)
        selector.init(mock(androidx.media3.exoplayer.trackselection.TrackSelector.InvalidationListener::class.java),
            mock(androidx.media3.exoplayer.upstream.BandwidthMeter::class.java))
        val next = TrackGroup("different-period", format("new-high"), format("new-low", 200000))
        val mapped = mock(MappingTrackSelector.MappedTrackInfo::class.java)
        `when`(mapped.rendererCount).thenReturn(1)
        `when`(mapped.getRendererType(0)).thenReturn(C.TRACK_TYPE_VIDEO)
        `when`(mapped.getTrackGroups(0)).thenReturn(TrackGroupArray(next))
        `when`(mapped.unmappedTrackGroups).thenReturn(TrackGroupArray.EMPTY)
        val method = DefaultTrackSelector::class.java.getDeclaredMethod("selectTracks",
            MappingTrackSelector.MappedTrackInfo::class.java, Array<Array<IntArray>>::class.java, IntArray::class.java,
            androidx.media3.exoplayer.source.MediaSource.MediaPeriodId::class.java, Timeline::class.java).apply { isAccessible = true }
        @Suppress("UNCHECKED_CAST")
        val result = method.invoke(selector, mapped,
            arrayOf(arrayOf(intArrayOf(C.FORMAT_HANDLED, C.FORMAT_HANDLED))), intArrayOf(0),
            androidx.media3.exoplayer.source.MediaSource.MediaPeriodId("next-period"), Timeline.EMPTY)
            as android.util.Pair<*, Array<ExoTrackSelection?>>
        val selected = result.second.single()!!
        assertEquals(1, selected.length())
        assertEquals(0, selected.getIndexInTrackGroup(0))
        assertEquals(next, selected.trackGroup)
        assertEquals("high", fixed.fixedTrackId)
    }

    @Test fun `explicit high bitdepth AVC metadata is incompatible even when codec profile claims SDR`() = android {
        val high = format("high").buildUpon().setColorInfo(ColorInfo.Builder()
            .setColorTransfer(C.COLOR_TRANSFER_SDR).setLumaBitdepth(10).setChromaBitdepth(10).build()).build()
        assertFailsWith<YlBoundaryException> { YlVideoSelectionPolicy.select(tracks(high), "high", caps, envelope) }
    }

    @Test fun `auto explicit choice and reset have separate stable reasons`() = android {
        assertEquals("initial", YlFixedVideoState().reason)
        assertEquals("user", YlVideoSelectionPolicy.select(Tracks.EMPTY, null, caps, envelope).reason)
    }
    @Test fun `SDR HEVC fixed quality preserves identity across recreated Period groups`() = android {
        val hevc = format("hevc").buildUpon().setSampleMimeType("video/hevc").setCodecs("hvc1.1.6.L93").build()
        val selected = YlVideoSelectionPolicy.select(tracks(hevc), "hevc", caps, envelope)
        val recreated = hevc.buildUpon().setId("next-hevc").build()
        assertEquals("next-hevc", YlVideoSelectionPolicy.reconcile(tracks(recreated), selected, caps, envelope).fixedTrackId)
        assertFailsWith<YlBoundaryException> { YlVideoSelectionPolicy.select(tracks(hevc, supported = C.FORMAT_EXCEEDS_CAPABILITIES), "hevc", caps, envelope) }
    }

    @Test fun `missing AVC fixed quality can fall back to supported SDR HEVC while preserving independent caps`() = android {
        val selected = YlVideoSelectionPolicy.select(tracks(format("avc")), "avc", caps, envelope)
        val hevc = format("hevc").buildUpon().setSampleMimeType("video/hevc").setCodecs("hvc1.1.6.L93").build()
        val recovered = YlVideoSelectionPolicy.reconcile(tracks(hevc), selected, caps, envelope)
        assertNull(recovered.fixedTrackId)
        assertEquals("trackUnavailable", recovered.reason)
        assertFailsWith<YlBoundaryException> { YlVideoSelectionPolicy.select(tracks(hevc), "hevc", AndroidQualityConstraint(maxWidth = 640), envelope) }
    }

    private fun choose(selector: YlFixedVideoTrackSelector, vararg groups: TrackGroup): ExoTrackSelection {
        val mapped = mock(MappingTrackSelector.MappedTrackInfo::class.java)
        `when`(mapped.rendererCount).thenReturn(1)
        `when`(mapped.getRendererType(0)).thenReturn(C.TRACK_TYPE_VIDEO)
        `when`(mapped.getTrackGroups(0)).thenReturn(TrackGroupArray(*groups))
        `when`(mapped.unmappedTrackGroups).thenReturn(TrackGroupArray.EMPTY)
        val method = DefaultTrackSelector::class.java.getDeclaredMethod("selectTracks",
            MappingTrackSelector.MappedTrackInfo::class.java, Array<Array<IntArray>>::class.java, IntArray::class.java,
            androidx.media3.exoplayer.source.MediaSource.MediaPeriodId::class.java, Timeline::class.java).apply { isAccessible = true }
        @Suppress("UNCHECKED_CAST")
        val result = method.invoke(selector, mapped,
            // Media3 retains unused null entries in its Java backing arrays. Only
            // mapped renderer/group counts describe valid capability entries.
            arrayOf((groups.map { IntArray(it.length) { C.FORMAT_HANDLED } } + listOf<IntArray?>(null)).toTypedArray()), intArrayOf(0),
            androidx.media3.exoplayer.source.MediaSource.MediaPeriodId("period"), Timeline.EMPTY) as android.util.Pair<*, Array<ExoTrackSelection?>>
        return result.second.single()!!
    }

    @Test fun `DASH automatic selection stays in accepted SDR family across Period and restore`() = android {
        val selector = YlFixedVideoTrackSelector(mock(android.content.Context::class.java),
            DefaultTrackSelector.Parameters.Builder().setConstrainAudioChannelCountToDeviceCapabilities(false).build())
        selector.dashVideoFamily = YlDashVideoFamilyPolicy()
        selector.init(mock(androidx.media3.exoplayer.trackselection.TrackSelector.InvalidationListener::class.java),
            mock(androidx.media3.exoplayer.upstream.BandwidthMeter::class.java))
        choose(selector, TrackGroup("first", format("avc").buildUpon()
            .setColorInfo(ColorInfo.Builder().setColorTransfer(C.COLOR_TRANSFER_SDR).build()).build()))
        val accepted = selector.dashVideoFamily!!.accepted
        val hdr = format("hdr", 1800000).buildUpon().setSampleMimeType("video/hevc").setCodecs("hvc1.2.4.L93")
            .setColorInfo(ColorInfo.Builder().setColorTransfer(C.COLOR_TRANSFER_ST2084).build()).build()
        val sdr = format("sdr", 200000).buildUpon().setSampleMimeType("video/hevc").setCodecs("hvc1.1.6.L93").build()
        assertEquals("sdr", choose(selector, TrackGroup("hdr", hdr), TrackGroup("sdr", sdr)).selectedFormat.id)
        selector.dashVideoFamily = YlDashVideoFamilyPolicy(accepted)
        val error = assertFailsWith<java.lang.reflect.InvocationTargetException> { choose(selector, TrackGroup("only-hdr", hdr)) }
        assertTrue(error.cause is androidx.media3.exoplayer.ExoPlaybackException)
        assertEquals(accepted, selector.dashVideoFamily!!.accepted)
    }

    @Test fun `DASH actual decoder color cannot contradict accepted manifest family`() = android {
        val policy = YlDashVideoFamilyPolicy()
        policy.verifyOutput(format("avc"), C.COLOR_TRANSFER_SDR)
        val changed = format("hidden-hdr").buildUpon().setColorInfo(ColorInfo.Builder()
            .setColorTransfer(C.COLOR_TRANSFER_ST2084).build()).build()
        assertFailsWith<YlBoundaryException> { policy.verifyOutput(changed, C.COLOR_TRANSFER_ST2084) }
        policy.verifyOutput(format("sdr"), C.COLOR_TRANSFER_SDR)
    }

    @Test fun `DASH Dolby family retains profile and transfer and rejects unproven FEL path`() = android {
        fun dolby(profile: String, transfer: Int) = format("dv").buildUpon().setSampleMimeType("video/dolby-vision")
            .setCodecs("dvhe.$profile.06").setColorInfo(ColorInfo.Builder().setColorTransfer(transfer).build()).build()
        val policy = YlDashVideoFamilyPolicy()
        policy.accept(dolby("08", C.COLOR_TRANSFER_ST2084))
        assertFalse(policy.compatible(dolby("08", C.COLOR_TRANSFER_HLG)))
        assertFalse(policy.compatible(dolby("05", C.COLOR_TRANSFER_ST2084)))
        assertFailsWith<YlBoundaryException> { YlDashVideoFamilyPolicy().accept(dolby("07", C.COLOR_TRANSFER_ST2084)) }
        assertFailsWith<YlBoundaryException> { policy.restore("sdr") }
    }

}
