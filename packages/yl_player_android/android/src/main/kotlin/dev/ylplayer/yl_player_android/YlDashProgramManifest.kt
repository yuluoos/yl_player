package dev.ylplayer.yl_player_android

import androidx.media3.exoplayer.dash.manifest.DashManifest

/** Parsed Media3 resource graph with independent exact programme boundaries.
 * Millisecond fields remain an admission projection, never the clipping authority. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class YlDashProgramManifest(manifest: DashManifest, val program: YlDashProgramTiming) : DashManifest(
    manifest.availabilityStartTimeMs, program.duration.units(1000, ceil = true), manifest.minBufferTimeMs,
    false, manifest.minUpdatePeriodMs, manifest.timeShiftBufferDepthMs, manifest.suggestedPresentationDelayMs,
    manifest.publishTimeMs, manifest.programInformation, manifest.utcTiming, manifest.serviceDescription,
    (0 until manifest.periodCount).map(manifest::getPeriod), manifest.locations,
)
