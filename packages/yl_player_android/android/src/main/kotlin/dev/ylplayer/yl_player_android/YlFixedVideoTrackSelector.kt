package dev.ylplayer.yl_player_android

import android.content.Context
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.exoplayer.ExoPlaybackException
import androidx.media3.exoplayer.RendererCapabilities
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.exoplayer.trackselection.ExoTrackSelection

/** DefaultTrackSelector selects reading-ahead Periods on ExoPlayer's playback thread. A group-only
 * override cannot cover recreated groups, so enforce the immutable quality before ABR definitions
 * are built. Public mode is changed only by Core's current-Period observation, never by lookahead. */
internal class YlFixedVideoTrackSelector : DefaultTrackSelector {
    constructor(context: Context) : super(context)
    constructor(context: Context, parameters: Parameters) : super(context, parameters)
    // Identity and independent limits travel together. Exo's queued parameters may still
    // contain a superseded health ceiling when a valid explicit fixed command arrives.
    @Volatile var fixedIntent: YlFixedVideoIntent? = null

    override fun selectAllTracks(
        definitions: Array<ExoTrackSelection.Definition?>,
        mappedTrackInfo: MappedTrackInfo,
        rendererFormatSupports: Array<Array<IntArray>>,
        rendererMixedMimeTypeAdaptationSupports: IntArray,
        params: Parameters,
    ) {
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
                }
            } catch (error: YlBoundaryException) {
                throw ExoPlaybackException.createForUnexpected(error, PlaybackException.ERROR_CODE_FAILED_RUNTIME_CHECK)
            }
        }
        super.selectAllTracks(definitions, mappedTrackInfo, rendererFormatSupports, rendererMixedMimeTypeAdaptationSupports, params)
    }
}
