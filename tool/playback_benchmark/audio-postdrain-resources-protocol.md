# Post-EOF audio resource protocol — 2026-10-09

Base: 78af5d6. Test/measurement-only; production unchanged and candidate default off.
Question: does moving heap completely outside audio production preserve marker
integrity while still observing completed callback-shell retention at two lengths?
This is NOT a repair or qualification of live heap sampling.

The first hypothesis, pause then wait100ms for stable tap markers before heap,
failed in a no-heap64-buffer test: legacy66058/candidate65698 frames versus65536,
with order errors. Preserve that attempt and source snapshot; do not ship that
mode or disregard its failures. No assertion tolerance is introduced.

Freeze source/test/tool/protocol/native hashes and actual OS/audio/power before
one run per arm, sequential: legacy1000, candidate1000, legacy2000, candidate2000.
Use the real renderer/system output with synthetic48kHz stereo1024-frame PCM,
existing channel0 player tap and muted mixer. No pause/reset/heap during playback.
Only configured(before play), drained(actual final callbacks + zero ownership),
and disposed(after native detach) can request heap. The resumed/mid checkpoints
are forbidden. Record a second disposed sample at least2s later.

Every arm requires exact count*1024 frames, zero order errors and interior zeros,
no native playback stop/error, peak owned/ledger<=196608B, drained/disposed ownership0.
Candidate must submit/receive count-1 rendered and1 playedBack; legacy count playedBack.
Three heap snapshots per arm must return0 within8s, identify the exact owned PID,
and contain a heap table with numeric entries. Empty/truncated/wrong-PID output,
nonzero exit, partial timeout, missing phases or acknowledgements fail and remain.
Acknowledge failed probes only to allow cleanup; acknowledgements are not success.
Never extend heap8s to make a failure pass or automatically retry a failed arm.

Retain process deadline240s, XCTest180s, each checkpoint ACK<=30s, original playback
media-duration+10s limit. Native test checks intact frame sequence even when heap
fails. Run audio XCTest class plus new collector/validator and fixture checks.
No production/shared-iOS change, so no redundant iOS build or20min repeat.

Report all four arms and12 planned snapshots, including failed hypotheses and
negative tests. Archive sources and raw logs/rows/heap/xcresult exports with SHA256.
Different completed lengths show post-EOF retention only; do not infer a live heap
bound, physical AV correctness, minimumOS/device coverage or a memory plateau.
ProductionAdmission/defaultEnabled/downstreamBoundProven all remain false.
