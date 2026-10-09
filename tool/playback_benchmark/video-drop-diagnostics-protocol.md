# Video drop diagnosis — 2026-10-09

Base06f95a7. Continue the approved P08 next item: identify the reason for the
one drop observed in the prior1201s AAC-preroll long run. That prior failure
remains immutable and cannot be retroactively attributed from five-second rows.

Add opt-in scalar diagnostics at the existing scheduler drop branches without
changing selection, deadlines, capacity, clock, or zero-drop thresholds. Preserve
six reason totals and the last16 drop events, never frame payloads/reservations.
Record event uptime, generation, dropped PTS range/count, queue count, selected
PTS/media position for catch-up, previous valid scheduling call time/position,
and enqueue elapsed time. Flush clears the prior tick but lifetime drop counters
and event history survive just as the existing total does. Diagnostics default
off; the decoded native observation explicitly enables them. Capacity eviction
is an existing compatibility branch currently unreachable with usesBackpressure
always true; do not manufacture a public switch to exercise it.

Tests: actual native RED/GREEN for catch-up content/lifetime, timeout/late/span
rejections, bounded history/reset, default-off behavior, and producer overtaken
while waiting. Full macOS native suite, iOS arm64 simulator build-only for the
shared change; Python diagnostic/report and fixture parity checks. Fresh review.

Freeze source/native/fixture/protocol identities. Run one30s short gate, then
one1200s observation only if the exact same identity passes short. Archive every
failure without retrying to obtain a pass. Capture diagnostics before strict
validation so a failed zero-drop gate still has a cause report. Keep prior
protocol durations, physical-output limitations, and disposal checks intact.

A catch-up event demonstrates that more than one queued frame was due at a
scheduler call. Its wall/media deltas may identify a delayed scheduling window;
they do not alone prove an OS, decoder, display link, main-thread or audio-clock
root cause. Any unobserved cause remains pending. Production admission, candidate
default enablement and downstream bound proof remain false.

Review correction: include the current waiting-enqueue count in the same locked
snapshot and sample it in native observation. The producer-overtaken regression
waits for actual capacity-wait entry, not a guessed50ms delay. Totals/counts/events
are one atomic snapshot, taken before the row uptime; no split-read race.
Diagnostic validator rejects event-reason/count disagreement and backward tick
clocks. Both malformed-record cases demonstrated RED before correction.
