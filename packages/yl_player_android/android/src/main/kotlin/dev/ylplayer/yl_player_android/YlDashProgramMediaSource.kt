package dev.ylplayer.yl_player_android

import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Timeline
import androidx.media3.common.TrackGroup
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.TransferListener
import androidx.media3.exoplayer.dash.DashMediaSource
import androidx.media3.exoplayer.dash.manifest.DashManifest
import androidx.media3.exoplayer.dash.manifest.Period
import androidx.media3.exoplayer.source.*
import androidx.media3.exoplayer.upstream.Allocator
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.Loader
import androidx.media3.exoplayer.upstream.ParsingLoadable
import java.io.IOException
import java.util.IdentityHashMap

/** One managed root load, then immutable sideloaded Periods. Each real Period is
 * clipped at the exact programme boundary; declared gaps consume real bounded
 * PCM silence. Media3 still owns decoding, selection, buffering and media I/O. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class YlDashProgramMediaSource(
    private val item: MediaItem,
    private val dataSources: DataSource.Factory,
    private val parser: YlDashManifestParser,
    private val policy: LoadErrorHandlingPolicy,
    private val gapGroups: YlDashGapGroups,
) : CompositeMediaSource<Unit>(), Loader.Callback<ParsingLoadable<DashManifest>> {
    private var loader: Loader? = null
    private var child: MediaSource? = null
    private var failure: IOException? = null
    private var released = false
    override fun getMediaItem() = item
    override fun prepareSourceInternal(mediaTransferListener: TransferListener?) {
        super.prepareSourceInternal(mediaTransferListener)
        released = false; failure = null
        val source = dataSources.createDataSource()
        mediaTransferListener?.let(source::addTransferListener)
        val loadable = ParsingLoadable(source, requireNotNull(item.localConfiguration).uri, C.DATA_TYPE_MANIFEST, parser)
        loader = Loader("YlDashProgram").also { it.startLoading(loadable, this, policy.getMinimumLoadableRetryCount(C.DATA_TYPE_MANIFEST)) }
    }
    private fun loadInfo(loadable: ParsingLoadable<DashManifest>, elapsed: Long, duration: Long) =
        LoadEventInfo.Builder(loadable.loadTaskId, loadable.dataSpec, elapsed)
            .setUri(loadable.uri).setResponseHeaders(loadable.responseHeaders)
            .setLoadDurationMs(duration).setBytesLoaded(loadable.bytesLoaded()).build()
    override fun onLoadStarted(loadable: ParsingLoadable<DashManifest>, elapsedRealtimeMs: Long, loadDurationMs: Long, retryCount: Int) {
        createEventDispatcher(null).loadStarted(loadInfo(loadable, elapsedRealtimeMs, loadDurationMs), C.DATA_TYPE_MANIFEST)
    }
    override fun onLoadCompleted(loadable: ParsingLoadable<DashManifest>, elapsedRealtimeMs: Long, loadDurationMs: Long) {
        if (released) return
        policy.onLoadTaskConcluded(loadable.loadTaskId)
        createEventDispatcher(null).loadCompleted(loadInfo(loadable, elapsedRealtimeMs, loadDurationMs), C.DATA_TYPE_MANIFEST)
        try {
            val manifest = loadable.result as YlDashProgramManifest
            val builder = ConcatenatingMediaSource2.Builder().setMediaItem(item)
            var cursor = YlDashTime.ZERO
            for ((index, window) in manifest.program.windows.withIndex()) {
                if (window.start > cursor) {
                    builder.add(YlDashGapSource(SilenceMediaSource.Factory()
                        .setDurationUs(window.start.units(1_000_000, true) - cursor.units(1_000_000, true)).createMediaSource(), gapGroups))
                }
                val original = manifest.getPeriod(index)
                val duration = window.end - window.start
                // Source time is relative to this Period. Resource URLs and PTO
                // remain the original graph; no child manifest or media rewrite.
                val single = DashManifest(manifest.availabilityStartTimeMs, duration.units(1000, true), manifest.minBufferTimeMs,
                    false, manifest.minUpdatePeriodMs, manifest.timeShiftBufferDepthMs,
                    manifest.suggestedPresentationDelayMs, manifest.publishTimeMs, manifest.programInformation,
                    manifest.utcTiming, manifest.serviceDescription,
                    listOf(Period(original.id, 0, original.adaptationSets, original.eventStreams, original.assetIdentifier)), manifest.locations)
                val dash = DashMediaSource.Factory(dataSources).setLoadErrorHandlingPolicy(policy).createMediaSource(single, item)
                // Project absolute endpoints once, so fractional Periods do not
                // accumulate one rounding error per transition.
                val durationUs = window.end.units(1_000_000, true) - window.start.units(1_000_000, true)
                builder.add(ClippingMediaSource.Builder(dash).setEndPositionUs(durationUs).build())
                cursor = window.end
            }
            child = builder.build().also { prepareChildSource(Unit, it) }
        } catch (error: RuntimeException) {
            failure = IOException("Unsupported DASH programme.", YlBoundaryException(YlFailureKind.CONTAINER_UNSUPPORTED))
        }
    }
    override fun onLoadCanceled(loadable: ParsingLoadable<DashManifest>, elapsedRealtimeMs: Long, loadDurationMs: Long, released: Boolean) {
        policy.onLoadTaskConcluded(loadable.loadTaskId)
        createEventDispatcher(null).loadCanceled(loadInfo(loadable, elapsedRealtimeMs, loadDurationMs), C.DATA_TYPE_MANIFEST)
    }
    override fun onLoadError(loadable: ParsingLoadable<DashManifest>, elapsedRealtimeMs: Long, loadDurationMs: Long, error: IOException, errorCount: Int): Loader.LoadErrorAction {
        val info = loadInfo(loadable, elapsedRealtimeMs, loadDurationMs)
        val delay = policy.getRetryDelayMsFor(LoadErrorHandlingPolicy.LoadErrorInfo(info, MediaLoadData(C.DATA_TYPE_MANIFEST), error, errorCount))
        val action = if (delay == C.TIME_UNSET) Loader.DONT_RETRY_FATAL else Loader.createRetryAction(false, delay)
        createEventDispatcher(null).loadError(info, C.DATA_TYPE_MANIFEST, error, !action.isRetry)
        if (!action.isRetry) policy.onLoadTaskConcluded(loadable.loadTaskId)
        return action
    }
    override fun maybeThrowSourceInfoRefreshError() {
        failure?.let { throw it }; loader?.maybeThrowError(); super.maybeThrowSourceInfoRefreshError()
    }
    override fun onChildSourceInfoRefreshed(childSourceId: Unit, mediaSource: MediaSource, newTimeline: Timeline) = refreshSourceInfo(newTimeline)
    override fun createPeriod(id: MediaSource.MediaPeriodId, allocator: Allocator, startPositionUs: Long): MediaPeriod = requireNotNull(child).createPeriod(id, allocator, startPositionUs)
    override fun releasePeriod(mediaPeriod: MediaPeriod) = requireNotNull(child).releasePeriod(mediaPeriod)
    override fun releaseSourceInternal() {
        released = true; loader?.release(); loader = null
        super.releaseSourceInternal(); child = null; failure = null
    }
}

/** Identity-only registry: an untrusted manifest cannot imitate a programme gap
 * by declaring a magic ID, MIME type or label. Entries live only with their Period. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class YlDashGapGroups {
    private val groups = IdentityHashMap<TrackGroup, Int>()
    @Synchronized fun add(group: TrackGroup) { groups[group] = (groups[group] ?: 0) + 1 }
    @Synchronized fun remove(group: TrackGroup) { val count = groups[group] ?: return; if (count == 1) groups.remove(group) else groups[group] = count - 1 }
    @Synchronized fun contains(group: TrackGroup) = groups.containsKey(group)
}

/** Wrap the platform's bounded SilenceMediaSource without replacing its PCM
 * generator. Mark its track identity before selectors or callbacks can see it. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
private class YlDashGapSource(source: MediaSource, private val groups: YlDashGapGroups) : WrappingMediaSource(source) {
    private class GapPeriod(val delegate: MediaPeriod, val groups: YlDashGapGroups) : MediaPeriod by delegate {
        var registered = emptyList<TrackGroup>()
        override fun prepare(callback: MediaPeriod.Callback, positionUs: Long) {
            delegate.prepare(object : MediaPeriod.Callback {
                override fun onPrepared(mediaPeriod: MediaPeriod) {
                    registered = (0 until delegate.trackGroups.length).map { delegate.trackGroups[it] }
                    registered.forEach(groups::add)
                    callback.onPrepared(this@GapPeriod)
                }
                override fun onContinueLoadingRequested(source: MediaPeriod) = callback.onContinueLoadingRequested(this@GapPeriod)
            }, positionUs)
        }
    }
    override fun createPeriod(id: MediaSource.MediaPeriodId, allocator: Allocator, startPositionUs: Long): MediaPeriod = GapPeriod(super.createPeriod(id, allocator, startPositionUs), groups)
    override fun releasePeriod(mediaPeriod: MediaPeriod) {
        val period = mediaPeriod as GapPeriod
        period.registered.forEach(groups::remove)
        super.releasePeriod(period.delegate)
    }
}
