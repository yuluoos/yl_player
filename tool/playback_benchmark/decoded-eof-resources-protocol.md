# Decoded EOF resource comparison

Freeze source, native binaries, collector/protocol and the existing 4.021s AVC/AAC
Matroska fixture. Run legacy then candidate in independent test processes, muted
native output, MallocStackLogging disabled. Use the real typed Host, file demux,
decoders, AVAudioEngine and first-frame publication. Do not enable production.

Checkpoints are configured (loaded, autoplay false), completed (observation only),
drained (after natural completion, explicitly pause the audio renderer while
retaining its graph), disposed (Host close), and disposedLater (at least 2s later).
Only configured/drained/disposed request heap. The test deliberately retains its
Host/factory/renderer references through the final observation, so disposed means
native graph detach and ledger release, not deallocation of the test harness.

The collector checks the exact owned executable before each heap. Keep the
existing 8s heap deadline, complete table/summary totals and PID validation,
30s ACK, 180s native and 240s parent deadlines. Preserve failed raw output; ACK
failure solely to permit cleanup. Missing ACK throws and closes the Host; it
must never continue into playback after a timeout. Never retry a failed capture with relaxed limits.
No heap, pause or reset during playback. Completion must precede pause and heap.
Require one completed/first-frame publication, no failures, no pending audio or
owned bytes at completion, all native callbacks delivered, and unchanged callback
counts after close. Candidate requires one playedBack and multiple rendered
callbacks; legacy requires only playedBack callbacks. Require ledger zero and
stopped output immediately and >=2s after close. The completed record captures
native state before the explicit resource-measurement pause.

Report raw heap totals and per-arm changes from configured, drained and disposed,
plus RSS/footprint snapshots. These are one pair of post-EOF samples, not a length
matrix, live retention slope, statistical comparison, physical audibility or a
global downstream resource bound. Playback continuity uses its separate evidence.
Keep defaultEnabled, productionAdmission and downstreamBoundProven false.
