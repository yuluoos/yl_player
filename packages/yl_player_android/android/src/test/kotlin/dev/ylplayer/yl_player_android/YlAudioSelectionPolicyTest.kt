package dev.ylplayer.yl_player_android

import androidx.media3.common.*
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.exoplayer.trackselection.ExoTrackSelection
import androidx.media3.exoplayer.trackselection.MappingTrackSelector
import androidx.media3.exoplayer.source.TrackGroupArray
import androidx.media3.exoplayer.source.MediaSource.MediaPeriodId
import org.mockito.Mockito.*
import kotlin.test.*

class YlAudioSelectionPolicyTest {
    private fun f(id: String? = "rep", role: Int = C.ROLE_FLAG_MAIN, language: String? = "en") = Format.Builder()
        .setId(id).setLanguage(language).setRoleFlags(role).setSampleMimeType("audio/mp4a-latm").setCodecs("mp4a.40.2")
        .setSampleRate(48000).setChannelCount(2).setAverageBitrate(64000).build()
    private fun catalog(vararg groups: TrackGroup, dash: Boolean = true) = YlAudioSelectionPolicy.candidates(
        groups.map { it to (0 until it.length).toList() }, dash)
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


    @Test fun `DASH declared content separates repeated representation ids and follows reordered groups`() = android {
        val a = TrackGroup("10", f()); val b = TrackGroup("20", f())
        val initial = catalog(a, b).map { it.id }
        assertEquals(2, initial.toSet().size)
        assertEquals(initial.reversed(), catalog(b, a).map { it.id })
    }
    @Test fun `DASH representation rename bitrate label and rendition order do not define audio identity`() = android {
        val original = catalog(TrackGroup("10", f(), f("other").buildUpon().setAverageBitrate(96000).build())).single()
        val updated = catalog(TrackGroup("10", f("new").buildUpon().setAverageBitrate(128000).setLabel("changed").build())).single()
        assertEquals(original.id, updated.id)
        assertEquals(1, original.selectedIndex())
        assertEquals(0, updated.selectedIndex())
    }
    @Test fun `unset DASH group positions cannot identify missing metadata and duplicate semantics reject`() = android {
        val main = f(null, language = null); val comment = f(null, C.ROLE_FLAG_COMMENTARY, null)
        val first = catalog(TrackGroup("unset:0", main), TrackGroup("unset:1", comment))
        val next = catalog(TrackGroup("unset:0", comment), TrackGroup("unset:1", main))
        assertEquals(first.map { it.id }.reversed(), next.map { it.id })
        assertEquals(YlFailureKind.POLICY_UNSUPPORTED, assertFailsWith<YlBoundaryException> {
            catalog(TrackGroup("unset:0", main), TrackGroup("unset:1", main))
        }.kind)
    }
    @Test fun `language case normalizes but content role codec rate and channel changes do not match`() = android {
        val original = catalog(TrackGroup("10", f(language = "EN-us"))).single().id
        assertEquals(original, catalog(TrackGroup("10", f(language = "en-US"))).single().id)
        val changes = listOf(f(role = C.ROLE_FLAG_COMMENTARY), f(language = "fr"), f().buildUpon().setCodecs("mp4a.40.5").build(),
            f().buildUpon().setSampleRate(44100).build(), f().buildUpon().setChannelCount(6).build())
        changes.forEach { assertNotEquals(catalog(TrackGroup("10", f())).single().id, catalog(TrackGroup("10", it)).single().id) }
        assertNotEquals(catalog(TrackGroup("10", f())).single().id, catalog(TrackGroup("11", f())).single().id)
    }
    @Test fun `generic content keys are nested length framed not delimiter concatenations`() = android {
        val a = catalog(TrackGroup("ignored", f("a\u0000b")), dash = false).single().id
        val b = catalog(TrackGroup("ignored", f("a"), f("b")), dash = false).single().id
        assertNotEquals(a, b)
    }
    @Test fun `unsupported chosen rendition rejects and actual missing group has track code`() = android {
        val group = TrackGroup("10", f())
        val id = catalog(group).single().id
        val unsupported = YlAudioSelectionPolicy.candidates(listOf(group to emptyList()), true)
        assertEquals(YlFailureKind.POLICY_UNSUPPORTED, assertFailsWith<YlBoundaryException> { YlAudioSelectionPolicy.resolve(unsupported, id) }.kind)
        assertEquals("track.not_found", assertFailsWith<YlBoundaryException> { YlAudioSelectionPolicy.resolve(emptyList(), id) }.kind.code)
    }
    @Test fun `identity allocation is bounded by group format and text limits`() = android {
        assertEquals(128, catalog(*(0 until 128).map { TrackGroup("$it", f()) }.toTypedArray()).size)
        assertEquals(YlFailureKind.RESOURCE_EXHAUSTED, assertFailsWith<YlBoundaryException> { catalog(*(0..128).map { TrackGroup("$it", f()) }.toTypedArray()) }.kind)
        assertFailsWith<YlBoundaryException> { catalog(TrackGroup("10", *Array(4097) { f() })) }
        assertFailsWith<YlBoundaryException> { catalog(TrackGroup("10", f("x".repeat(1025))), dash = false) }
    }
    private fun select(selector: YlFixedVideoTrackSelector, groups: List<TrackGroup>, supports: List<IntArray> = groups.map { IntArray(it.length) { C.FORMAT_HANDLED } }): Array<ExoTrackSelection?> {
        val mapped = mock(MappingTrackSelector.MappedTrackInfo::class.java)
        `when`(mapped.rendererCount).thenReturn(1)
        `when`(mapped.getRendererType(0)).thenReturn(C.TRACK_TYPE_AUDIO)
        val groupArray = TrackGroupArray(*groups.toTypedArray())
        `when`(mapped.getTrackGroups(0)).thenReturn(groupArray)
        `when`(mapped.unmappedTrackGroups).thenReturn(TrackGroupArray.EMPTY)
        val method = DefaultTrackSelector::class.java.getDeclaredMethod("selectTracks",
            MappingTrackSelector.MappedTrackInfo::class.java, Array<Array<IntArray>>::class.java, IntArray::class.java,
            MediaPeriodId::class.java, Timeline::class.java).apply { isAccessible = true }
        @Suppress("UNCHECKED_CAST")
        val result = method.invoke(selector, mapped, arrayOf(supports.toTypedArray()), intArrayOf(0), MediaPeriodId("next"), Timeline.EMPTY)
            as android.util.Pair<*, Array<ExoTrackSelection?>>
        return result.second
    }
    private fun selector(listener: androidx.media3.exoplayer.trackselection.TrackSelector.InvalidationListener = mock(androidx.media3.exoplayer.trackselection.TrackSelector.InvalidationListener::class.java)): YlFixedVideoTrackSelector {
        val params = DefaultTrackSelector.Parameters.Builder().setConstrainAudioChannelCountToDeviceCapabilities(false).build()
        return YlFixedVideoTrackSelector(mock(android.content.Context::class.java), params).also {
            it.init(listener,
                mock(androidx.media3.exoplayer.upstream.BandwidthMeter::class.java))
        }
    }
    @Test fun `real Media3 selection binds next Period before output and never mixes groups`() = android {
        val main = TrackGroup("10", f()); val comment = TrackGroup("20", f(role = C.ROLE_FLAG_COMMENTARY))
        val intent = YlAudioIntent(catalog(comment).single().id, true)
        val selector = selector(); selector.audioIntent = intent
        val recreated = TrackGroup("20", f("changed", C.ROLE_FLAG_COMMENTARY))
        val selected = select(selector, listOf(recreated, main)).single()!!
        assertEquals(recreated, selected.trackGroup); assertEquals(1, selected.length())
        assertEquals(intent, selector.audioIntent)
    }
    @Test fun `real Media3 lookahead missing choice fails before automatic output and preserves error code`() = android {
        val selector = selector(); selector.audioIntent = YlAudioIntent(catalog(TrackGroup("20", f())).single().id, true)
        val error = assertFailsWith<java.lang.reflect.InvocationTargetException> { select(selector, listOf(TrackGroup("10", f()))) }
        val failure = assertIs<androidx.media3.exoplayer.ExoPlaybackException>(error.cause)
        assertEquals(YlFailureKind.TRACK_NOT_FOUND, mediaFailure(failure, dev.ylplayer.yl_player_android.pigeon.AndroidDecoderPolicy.SYSTEM_DEFAULT))
        assertFailsWith<java.lang.reflect.InvocationTargetException> { select(selector, emptyList()) }
    }
    @Test fun `accepted audio intent invalidates real selector even without parameter changes`() = android {
        val listener = mock(androidx.media3.exoplayer.trackselection.TrackSelector.InvalidationListener::class.java)
        val selector = selector(listener)
        val intent = YlAudioIntent(catalog(TrackGroup("10", f())).single().id, true)
        selector.audioIntent = intent
        assertTrue(mockingDetails(listener).invocations.isNotEmpty())
        val calls = mockingDetails(listener).invocations.size
        selector.audioIntent = intent
        assertEquals(calls, mockingDetails(listener).invocations.size)
    }
}
