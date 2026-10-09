# Decoded continuity probe — 2026-10-09

Base01b3af3. Bounded test-only continuation of P08. Reuse current isolated
codex/fel-integration branch and existing owned1260s AVC/AAC fixture; no product
or public switch changes. Candidate explicitly enabled only inside XCTest.

Plan: (1) add a scalar observation wrapper around real scheduler/output and a
strict offline validator; (2) validate a30s short gate; only if it passes, run one
candidate>=1200s continuous observation; (3) fresh review, archive all failures
and identities, update P08 and commit locally. No measurement retries to erase
failure. A short-gate failure blocks the long arm and must be reported as such.

Actual local demux, AAC converter, system audio output, hardware-required VT,
production media clock, frame scheduler and system display cadence are used.
The texture sink counts publication; it is not a physical screen. Audio mixer is
muted and fixture AAC is silent. Record renderer media time, scheduler selection
position/PTS, published frames, candidate state, completion modes, ownership and
sticky failures. No heap/MSL/pause/seek/reload, one session/generation/renderer.

Warmup<=10s to audio>=2s and>=24 video frames. Sample every5s, gap<=7.5s,
90–110% audio/media progress, cumulative clock drift<=5s over>=1200s (short>=30s).
Each selected frame must have valid strictly increasing PTS; max selection lag
(position minus PTS)<=100ms (internal two-frame-plus-scheduling gate at24fps,
not a physical AV SLO). Snapshot media/audio difference<=100ms, native playback
and candidate mode must stay active; no dropped frames or sticky failure.
Video must advance each sample; per-frame counters detect order/lag between ticks.

Short30s and long1200s both stop before fixtureEOF, so final playback completion
is not asserted. Explicit disposal plus2s observation must show ledger0, no pending
audio. Record counts but do not demand callbacks for stopped queued buffers.
Keep existing EOF evidence separate. Test hardtimeout1380s, parent1500s;
shorttimeout90s/parent180s. Stream JSONL and retain prefix on failure.

Freeze source/native/fixture/protocol identities before each formal run; match after.
Only audio XCTest class/tool/fixture checks are required for this test-only change.
Prior fullnative/iOS/long results retain their original identities, no renewed claim.
DefaultEnabled/productionAdmission/downstreamBoundProven remainfalse.

Ruling: internal scheduler selection is observable without a production hook;
calling it physical presentation would overstate evidence, so record that boundary.
Ruling: long run is conditional on short gate; failing that gate completes this
investigation with an explicit blocked long arm, not a successful long-play claim.

Review revision before diagnostic second short run: v1 short XCTest passed but
strict collector failed. Inspection found every actual output was playedBack
although submissionAnchor flag stayedtrue. Gate actual modes: rendered submissions
and callbacks must increase and playedBack remain0 beforeEOF. Never treat anchor
flag as candidate mode proof. Record first3submittedPCM metadata without payload.
FirstAAC packet hasPTS-21000us; test whether actual firstPCM retains it, which
would trigger existing negativePTS compatibility fallback. No production fix here.

Correct observation boundaries: count the separate direct startup publication
explicitly (<=1, unchanged during observation); require scheduled+direct totals.
Selection position is the media clock passed to scheduler at the last selected
frame, not current clock. Record age<=100ms and compare with fresh audio time.
Zero dropped frames applies to active playback; shutdown drop changes remain raw
but are not playback failures. Retain v1 protocol/results, do not overwrite them.
CLI now requires --short-evidence for long: prior complete/exit0/short,
matching frozen identity, and raw short rows passing the current validator.
Full audio class reruns once after native observation changes; Python gate
regressions only rerun after subsequent Python-only corrections.
