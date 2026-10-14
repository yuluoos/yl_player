package dev.ylplayer.yl_player_android

import android.content.Context
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.exoplayer.ExoPlaybackException
import androidx.media3.exoplayer.RendererCapabilities
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.exoplayer.trackselection.ExoTrackSelection

/** Audio content intent and fixed video quality are enforced on reading-ahead Periods.
 * DefaultTrackSelector runs on ExoPlayer's playback thread. A group-only
 * override cannot cover recreated groups, so enforce the immutable quality before ABR definitions
 * are built. Public mode is changed only by Core's current-Period observation, never by lookahead. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class YlFixedVideoTrackSelector : DefaultTrackSelector {
    constructor(context: Context) : super(context)
    constructor(context: Context, parameters: Parameters) : super(context, parameters)
    // Identity and independent limits travel together. Exo's queued parameters may still
    // contain a superseded health ceiling when a valid explicit fixed command arrives.
    @Volatile var audioIntent: YlAudioIntent? = null
        set(value) {
            if (field == value) return
            field = value
            invalidate(/* parameters */ null)
        }
    var dashVideoFamily: YlDashVideoFamilyPolicy? = null
        set(value) {
            field?.onAccepted = null
            field = value
            value?.onAccepted = { invalidate(/* parameters */ null) }
        }
    @Volatile var fixedIntent: YlFixedVideoIntent? = null
    /** Owned gap PCM is timing, not a replacement content choice. */
    var isDashGapGroup: (androidx.media3.common.TrackGroup) -> Boolean = { false }

    override fun selectAllTracks(
        definitions: Array<ExoTrackSelection.Definition?>,
        mappedTrackInfo: MappedTrackInfo,
        rendererFormatSupports: Array<Array<IntArray>>,
        rendererMixedMimeTypeAdaptationSupports: IntArray,
        params: Parameters,
    ) {
        val groups = (0 until mappedTrackInfo.rendererCount).flatMap { renderer ->
            val available = mappedTrackInfo.getTrackGroups(renderer)
            (0 until available.length).map { available[it] }
        }
        if (groups.isNotEmpty() && groups.all(isDashGapGroup)) {
            super.selectAllTracks(definitions, mappedTrackInfo, rendererFormatSupports, rendererMixedMimeTypeAdaptationSupports, params)
            return
        }
        audioIntent?.let { audio ->
            try {
                val groups = mutableListOf<Pair<androidx.media3.common.TrackGroup, List<Int>>>()
                val owners = mutableListOf<Int>()
                for (renderer in 0 until mappedTrackInfo.rendererCount) {
                    if (mappedTrackInfo.getRendererType(renderer) != C.TRACK_TYPE_AUDIO) continue
                    val audioGroups = mappedTrackInfo.getTrackGroups(renderer)
                    for (index in 0 until audioGroups.length) {
                        val group = audioGroups[index]
                        groups += group to (0 until group.length).filter {
                            RendererCapabilities.getFormatSupport(rendererFormatSupports[renderer][index][it]) == C.FORMAT_HANDLED
                        }
                        owners += renderer
                    }
                }
                val unmapped = mappedTrackInfo.unmappedTrackGroups
                for (index in 0 until unmapped.length) if (unmapped[index].type == C.TRACK_TYPE_AUDIO) {
                    groups += unmapped[index] to emptyList<Int>(); owners += -1
                }
                val catalog = YlAudioSelectionPolicy.candidates(groups, audio.dash)
                val chosen = YlAudioSelectionPolicy.resolve(catalog, audio.id)
                for (renderer in definitions.indices) {
                    if (mappedTrackInfo.getRendererType(renderer) == C.TRACK_TYPE_AUDIO) definitions[renderer] = null
                }
                definitions[owners[catalog.indexOf(chosen)]] = ExoTrackSelection.Definition(chosen.group, chosen.selectedIndex())
            } catch (error: YlBoundaryException) {
                throw ExoPlaybackException.createForUnexpected(error, PlaybackException.ERROR_CODE_FAILED_RUNTIME_CHECK)
            }
        }
        var fixedRenderer: Int? = null
        val intent = fixedIntent
        if (intent != null) {
            try {
                val catalog = mutableListOf<Pair<Int, YlVideoCandidate>>()
                for (renderer in 0 until mappedTrackInfo.rendererCount) {
                    if (mappedTrackInfo.getRendererType(renderer) != C.TRACK_TYPE_VIDEO) continue
                    val groups = mappedTrackInfo.getTrackGroups(renderer)
                    for (groupIndex in 0 until groups.length) {
                        val group = groups[groupIndex]
                        for (index in 0 until group.length) catalog += renderer to YlVideoCandidate(
                            group.getFormat(index).id ?: "video-$groupIndex-$index", group, index,
                            RendererCapabilities.getFormatSupport(rendererFormatSupports[renderer][groupIndex][index]) == C.FORMAT_HANDLED)
                    }
                }
                val unmapped = mappedTrackInfo.unmappedTrackGroups
                for (groupIndex in 0 until unmapped.length) {
                    val group = unmapped[groupIndex]
                    if (group.type == C.TRACK_TYPE_VIDEO) for (index in 0 until group.length)
                        catalog += -1 to YlVideoCandidate(group.getFormat(index).id ?: "unmapped-$index", group, index, false)
                }
                val chosen = YlVideoSelectionPolicy.resolve(intent.quality, catalog.map { it.second }, intent.constraints, intent.envelope)
                if (chosen != null) {
                    for (renderer in definitions.indices) {
                        if (mappedTrackInfo.getRendererType(renderer) == C.TRACK_TYPE_VIDEO) definitions[renderer] = null
                    }
                    val renderer = catalog.single { it.second === chosen }.first
                    definitions[renderer] = ExoTrackSelection.Definition(chosen.group, chosen.index)
                    fixedRenderer = renderer
                }
            } catch (error: YlBoundaryException) {
                throw ExoPlaybackException.createForUnexpected(error, PlaybackException.ERROR_CODE_FAILED_RUNTIME_CHECK)
            }
        }
        super.selectAllTracks(definitions, mappedTrackInfo, rendererFormatSupports, rendererMixedMimeTypeAdaptationSupports, params)
        dashVideoFamily?.let { family ->
            try {
                val videoRenderers = definitions.indices.filter { mappedTrackInfo.getRendererType(it) == C.TRACK_TYPE_VIDEO }
                if (family.accepted == null) videoRenderers.firstNotNullOfOrNull { definitions[it] }?.let {
                    family.accept(it.group.getFormat(it.tracks[0]))
                }
                val filtered = Array(mappedTrackInfo.rendererCount) { renderer ->
                    Array(mappedTrackInfo.getTrackGroups(renderer).length) { group -> rendererFormatSupports[renderer][group].clone() }
                }
                var hasVideo = false
                for (renderer in videoRenderers) {
                    val available = mappedTrackInfo.getTrackGroups(renderer)
                    for (group in 0 until available.length) for (track in 0 until available[group].length) {
                        hasVideo = true
                        if (!family.compatible(available[group].getFormat(track))) {
                            filtered[renderer][group][track] = RendererCapabilities.create(C.FORMAT_UNSUPPORTED_SUBTYPE)
                        }
                    }
                    // Keep a resolved fixed choice; automatic fallback uses the same selector
                    // and ABR policy, with only incompatible formats marked unsupported.
                    if (renderer == fixedRenderer) definitions[renderer]?.let { def ->
                        def.tracks.forEach { family.accept(def.group.getFormat(it)) }
                    } else definitions[renderer] = null
                }
                super.selectAllTracks(definitions, mappedTrackInfo, filtered, rendererMixedMimeTypeAdaptationSupports,
                    params.buildUpon().setExceedRendererCapabilitiesIfNecessary(false).build())
                if (hasVideo && videoRenderers.none { definitions[it] != null }) throw YlBoundaryException(YlFailureKind.POLICY_UNSUPPORTED)
                videoRenderers.forEach { renderer -> definitions[renderer]?.let { def ->
                    def.tracks.forEach { family.accept(def.group.getFormat(it)) }
                } }
            } catch (error: YlBoundaryException) {
                throw ExoPlaybackException.createForUnexpected(error, PlaybackException.ERROR_CODE_FAILED_RUNTIME_CHECK)
            }
        }
    }
}
