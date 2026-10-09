# Decoded callback wrapper intervention

Use the existing frozen decoded-60.mkv (60.229s, AVC/AAC, 2813 audio packets).
Four sequential independent processes: legacy wrapped, legacy transparent,
candidate wrapped, candidate transparent. Freeze the same source/binary/fixture
identity for all four. Do not compare a new transparent build to old wrapped data.
No production changes or candidate admission. Use the existing configured,
completed, drained, disposed and >=2s disposedLater phases. Heap only at
configured/drained/disposed, with the original 8s deadline; preserve 5s recorder
settling, 30s collector ACK, 180s native and 240s parent deadlines.

Only the test IntegrationOutput's completion forwarding changes. Wrapped mode
keeps the existing counting closures. Transparent mode forwards the supplied
completion (legacy) or callback struct (candidate) directly to the same production
YlSystemAudioOutput. Keep submission counts, bounded first-three PCM metadata,
engine failure probe, progress acknowledgement cleanup and the rest of the graph
identical. Transparent mode must not execute the test callback counters; the
native test checks those internal instrumentation counters remain untouched.

Transparent rows explicitly mark callbackObservation=unobserved and serialize
both callback counts as null. Do not fabricate zero native callbacks or substitute
submission counts for observations. Require actual submission modes (legacy all
playedBack; candidate 2812 rendered plus one playedBack), first frame and single
natural completion, audio owned bytes0/pendingfalse, no public failure/fallback,
unchanged submissions after close, stopped output and ledger0 after close and
>=2s later. These state checks provide EOF/drain evidence, not independently
observed native callback counts. Wrapped mode retains the existing strict equality
between submitted and observed native callback counts. Default no-collector native
regression exercises both wrapping settings on both arms with the short fixture.

Validate all four cells and equal 2813 submissions. Parse all twelve heap tables
with PID, complete table and raw hash/size checks, retaining missing labels as
null. Report raw and baseline-adjusted whole-process heap contrasts plus named
LifecycleCompletion, dispatch_source_t, Closure context and Block observations.
Single independent process per cell means exact byte cost/statistical effect and
precise native retaining owner are not established. Generic labels include other
frameworks. Retain failed runs without relaxed limits or overwritten evidence.
Production/global bound and admission flags remain false.
