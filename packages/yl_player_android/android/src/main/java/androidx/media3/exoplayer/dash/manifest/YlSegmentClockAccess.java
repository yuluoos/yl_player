package androidx.media3.exoplayer.dash.manifest;

import androidx.media3.common.util.UnstableApi;

/** Read-only adapter pinned to Media3 1.11. Package access preserves the raw
 * rational clock that its public microsecond index otherwise quantizes.
 * Does not copy timelines or change Media3 selection, parsing or scheduling. */
@UnstableApi
public final class YlSegmentClockAccess {
  private YlSegmentClockAccess() {}
  /** Number of explicit entries, or -1 when the declaration has no timeline. */
  public static int count(SegmentBase base) {
    if (!(base instanceof SegmentBase.MultiSegmentBase)) return -1;
    SegmentBase.MultiSegmentBase multi = (SegmentBase.MultiSegmentBase) base;
    return multi.segmentTimeline == null ? -1 : multi.segmentTimeline.size();
  }
  /** Raw timescale; caller validates before division. */
  public static long scale(SegmentBase base) { return base.timescale; }
  /** Raw presentation-time offset in the declared timescale. */
  public static long pto(SegmentBase base) { return base.presentationTimeOffset; }
  /** Raw start of an entry after the caller bounds the index with count. */
  public static long start(SegmentBase base, int index) {
    return ((SegmentBase.MultiSegmentBase) base).segmentTimeline.get(index).startTime;
  }
  /** Raw duration of an entry after the caller bounds the index with count. */
  public static long duration(SegmentBase base, int index) {
    return ((SegmentBase.MultiSegmentBase) base).segmentTimeline.get(index).duration;
  }
}
