# R2 repeated lifecycle resources — frozen before native measurements

Base 1cc539e. Four independent serial processes: legacy/seek, candidate/seek,
legacy/load-close, candidate/load-close. Each performs exactly six full passes
of the checked-in 4.021s mkv-avc-aac.mkv; no generated long fixture, physical
output or statistical latency claim. Normal callbacks are transparent and their
counts unobserved. No retained old callback injection in this resource workload.

Seek: one host/session/output, initial play then five seek0/play operations.
After each real natural EOF check completed/first-frame counts, actual modes,
video publication, pending=false, ownedBytes=0. Pause the native node solely
for post-drain sampling, retaining the graph. This intervention is declared and
is not production EOF behavior. No direct test stop is added.

Load-close: six independent host Load/play/EOF/close lifetimes within one process;
release test factory/host references before sampling; one shared texture registry
and a bounded scalar event sink survive to observe late publication. Closed
textures are unregistered, so this sink does not retain retired graphs. Each host
loads once; this does not claim same-host replacement-Load evidence. Count six
completed sessions and six first frames, and check no stale graph remains.

Both modes emit baseline, cycle1, cycle2, cycle3, cycle4, cycle5, cycle6,
disposed, disposedLater rows. Heap only at baseline, cycle1, cycle3, cycle6,
disposed. Every row follows >=2s settlement, inactive native playback and zero
pending audio. Seek retains one stopped-playing graph at cycle checkpoints;
load-close retains none and ledger must be0. Final disposed and disposedLater
must have no graph, no test-owned retired factory, ledger0 and unchanged totals.
Events and actual submissions are counted on receipt under a lock; snapshots
are read after settlement, with before/after stability assertions; native callback counts
are null. Observation rows remain bounded by the fixed nine-row protocol.

Function gates: completed count=cycle, actual per-pass mode eligible (candidate
one playedBack plus rendered>1; legacy playedBack>1/rendered0), correct active
anchor on seek, clock/progress and real video frames, one first frame/session,
no failures, disposal. No total-heap growth threshold or slope-to-infinity claim.
Report all-zone heap, selected types with absent=null, configured-relative bytes
and cycle6-cycle1 separately; increased bytes remain increased, not noise waived.
Resource observations do not certify continuity, exact retainers or total bounds.

Native smoke uses two rounds per mode/arm without heap. Formal freezes six rounds
and source/binary/material/protocol hashes. Native method180s, parent240s, heap8s,
ACK30s, recorder settle5s, EOF10s and progress5s. Missing/failed heap still ACKs to
release owned process; result fails. Preserve every failure. At most one unchanged
complete four-cell repeat if an external heap fails; no retries for function
failure, no deadline relaxation. Candidate stays off. Archive commands, raw rows,
raw heaps, results, XCTest attachments and identity; verify same build across cells.

## Completion observation semantics (2026-10-20)

The native `onState` callback publishes complete state snapshots. Several
snapshots may retain `completed` while other fields or public revisions change.
Resource probes count **transitions into completed**, keyed by session and the
preceding status, rather than treating each snapshot as a new EOF. A replay
through a non-completed state and completion in a new session each count again.
All publications continue to be counted; first-frame/failure/retry/submission,
ledger, graph and late-event checks retain their existing assertions. A synthetic
regression covers repeated snapshots, replay and new sessions. This correction
neither proves a system memory bound nor rewrites historical capture values.
