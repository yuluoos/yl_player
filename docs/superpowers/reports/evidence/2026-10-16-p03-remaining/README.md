# P03 remaining engineering — 2026-10-16

This continuation implements the remaining feasible strict-policy paths and their dependencies under the approved P03 design. The user confirmed no additional physical devices or qualified measurement records. Full P03/device qualification is not claimed.

## Engineering delivered

- Owned MP4/MOV VOD samples for managed, bounded or hardware-required requests, using the existing managed byte source, decoder evidence and shared allocation ledger. TS/PS/AVI use their existing owned output chain under these policies. Ordinary MP4/MOV still default to AVPlayer; strict HLS/live exclusions remain.
- Matroska Opus CELT/SILK/hybrid and Vorbis strict-policy playback, and bounded VP9. Missing source packet durations reserve the converter's hard maximum output duration in the queue only; raw packet timing remains unchanged and actual decoded PCM defines presentation timing.
- Inspected wrong-name MOV uses owned samples on systems below the MIME-override API; newer systems use the MOV MIME type. Deployment targets are unchanged.
- A real full-matrix failure exposed late pause/play changing completed back to playing while its completion flag stayed set. Native regression reproduced both state failures. The fix preserves a drained generation until explicit seek/rebuild; native and public tests verify replay after seek.

## Verification and scope

- macOS affected native:108/108, zero failures/skips. Includes11 actual strict format/codec combinations with pixels, channel/tone PCM, three seeks and eventual real ledger release; existing PCM boundary and track-switch controls also pass.
- iOS Simulator common route/budget/Vorbis/EOF tests:39/39, zero failures/skips. This is not physical video output evidence.
- Public Flutter codec-policy suite:13/13; subsequent public EOF regression:1/1. Example unit tests:96/96. Static analysis of five public-test files and public-surface guard pass.
- Media evidence tooling:61/61; software measurement/admission tooling:21/21. Production software profiles remain unadmitted without matching sustained thermal and independent product verification.
- `macos-matrix/` is the pre-EOF-fix frozen product:44 attempted,36/40 required accepted. The original local WebM/Vorbis timeout and its unfinished native trace remain. `macos-vorbis-replay/` passes on that same old product but does not replace the failure or increase the matrix count.
- `macos-matrix-final/` records the separate final frozen product and its complete44-cell result:37/40 required accepted; only local AVPlayer played-sample proof and AV1 file/HTTP hardware availability remain. Each matrix retains its own product identity, raw rows, framework results and original failures. The required denominator stays40; two diagnostic and two damaged inputs are never promoted to support.
- The framework-failure negative must retain a valid raw managed-MP4 row yet reject overall acceptance. The wrong-product-identity negative must reject before playback. Both pre-fix and final-product negative directories remain separate.

`records.json.gz` losslessly retains every matrix child's plan, status, raw rows and process result. Per-child logs and unfinished diagnostics are also retained; redundant copies of the same rows are omitted. `execution/` preserves RED runs, build/harness failures, final test summaries and source snapshots. Product identities bind the actual built/runtime bytes; these controlled snapshots do not establish release, physical synchronization or thermal qualifications.

The broad historical fixture checker still fails on a preexisting skip-source contract mismatch; its identity parser also cannot resolve the existing `DEBUG && YL_BOUND_AV` condition. Five modified test files match both platform mirrors and actual PBX membership. Canonical raw method counts are788 iOS/833 macOS; an existing extra macOS mirror method remains untouched. These counts are discovery metadata, not executed-case counts.

## Review and decisions

The fresh independent review found no Critical/Important issue in the initial patch. The later runtime-discovered EOF repair is verified by the parent with deterministic RED→GREEN and affected suites; it is not represented as a second review. See [review record](final-review.md) and [execution ledger](execution/ledger.md).

Decisions: reuse owned samples only for strict progressive policies; retain default AVPlayer and its honest played-sample evidence gap; preserve unavailable physical/minimum-OS/Intel/thermal qualifications; keep unrelated traffic work and long-play/weak-network ABR outside this commit; repair the demonstrated EOF dependency without relaxing clocks or timeouts. Cost: controlled engineering proof does not establish every device/output profile, and post-EOF controls deliberately require seek/rebuild to start new media work.

One deferred Minor: the existing public Vorbis error still says zero CodecDelay despite bounded nonzero-delay support. This does not affect admission or playback.

Run `python3 -B docs/superpowers/reports/evidence/2026-10-16-p03-remaining/verify.py` from the repository to verify archive hashes and independently replay the retained raw rows. Cached acceptance flags are not the replay authority.
