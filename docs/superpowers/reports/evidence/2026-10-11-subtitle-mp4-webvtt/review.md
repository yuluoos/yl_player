# One fresh-context final review — MP4 wvtt

Reviewer: gpt-6-astra/high, read-only, no subagents. Base a66cc3abde06a3e7485cd805d2072d1fa2686564; all11 owned candidate files inspected and compared to isolated snapshot. No second review.

## Strengths and verdict

Structured cue fields prevent blank lines/arrows/duplicate IDs from creating file-level events or replacing the sample clock. Box boundaries, UTF8, duplicate fields, empty sample combinations and per-field/configuration semantics are checked. Atomic publication and real file/HTTP/public session/Flutter placement/cancellation coverage were inspected. Managed transport is unchanged; directed70/70 log inspected (reviewer did not rerun tests).

Verdict: Ready to merge, subject to executor final regression. Critical0, Important0, Minor1.

## Minor deferred: aggregate box accounting

`mp4_webvtt.dart` `_vttBoxes` enforces local child limits but does not increment the scan `_boxes` counter in `mp4_subtitles.dart`. 2000 samples ×64 empty vttc/payl pairs have256000 nested boxes, about2.05MiB, zero retained cues, and can pass despite the earlier documented200000 aggregate box ceiling. Raw sample bytes, sample count and local child limits still bound work; this is not an unbounded allocation finding.

Suggested follow-up: charge sample/config boxes to scan-wide counter and add an empty-payload regression that cannot be masked by the cue limit.

Executor ruling: Minor retained because the4MiB raw-sample and local child budgets still bound processing, with no unbounded behavior or incorrect published subtitles demonstrated. Defer implementation per inline execution's genuine-Minor rule; explicitly clarify actual box accounting in the new contract. Cost: up to the existing raw-byte bound of nested box work instead of the structural walker's200000 ceiling. User-visible limitation remains recorded rather than claiming the stronger bound.

Additional nonblocking recommendation: supported settings table currently asserts acceptance/cue count; add explicit alignment/position fields for each case. Existing runtime geometry verifies position25%,center align:left. Defer this diagnostic improvement; no missing behavior demonstrated.

## Declined-to-judge rulings

Each reviewer exclusion accepted by executor for these reasons; none closes the parent P02:

- Independent producer wvtt interoperability: no independently muxed fixture; hand-calculated sample gives limited encoding evidence. Keep explicit limitation.
- Physical-device/native synchronization: fake media backend; no device claim.
- Native bridge/audio tracks: unchanged; separate scope.
- fMP4/HLS/DASH/complex edits: explicitly unsupported, reject path retained.
- CSS/regions/voice/class/ruby/karaoke/advanced positioning: outside established bounded renderer; explicit rejection.
- Other embedded codecs/encryption/external references: intentionally rejected; future slices.
- HDR/protected overlay/external display: no device evidence; deferred.
- PD-03 video failure policy: unchanged and still open.
- Fresh TLS/native video version consistency: shared transport unchanged; loopback confirms subtitle path only, prior transport regressions retained.
- Whole-process RSS/sustained responsiveness: input accounting is not process performance acceptance; no such claim.
- Parallel long-play/weak-network ABR/readiness changes: expressly excluded; preserve foreign files and index.
- Full suite/artifact hashes/commit: executor owns final log/hash/private-index verification, recorded separately in manifest.
