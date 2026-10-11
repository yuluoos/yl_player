# One fresh-context final review — MP4 stpp

Reviewer gpt-6-astra/high, read-only; no subagents, mutation or second review. Reviewed14owned code/test/fixture paths against896e471/ede8e48 and spec/plan focus. Confirmed directed64/64 log and scoped diff check; did not rerun tests. Concurrent suite remains executor responsibility.

## Findings and verdict

Critical0, Important0, Minor0. Ready to merge subject to executor regression. No actionable defect found.

Strengths: composition-time/sample/edit mapping uses integer arithmetic; sample-local region identities prevent cross-document geometry collision; decoded runs bypass markup reinterpretation; raw XML/empty/clipped document budgets remain accounted; bounded XML/sample/cue/run limits and atomic publication; realfile/HTTP/Flutter geometry/lifecycle tests.

## Declined-to-judge rulings

Executor accepts all exclusions for these reasons, without closing whole P02:

- Cross-Period identity: nonfragmented MP4 TrackIDs only; adaptive Period behavior outside slice.
- Full TTML/IMSC/advanced typography/timed spans/auxiliary images: existing bounded subset intentionally rejects, rejection paths reviewed.
- Font storms/ASS/bitmap performance: unchanged implementations; stpp resource rejection and text budgets reviewed, no broad performance claim.
- HDR/DRM/external-display/native-device rendering: fake video backend and Flutter tests, no device acceptance.
- PD-03 video termination/recovery: unresolved; existing state preservation on discovery failure continues.
- Positive independent-producer interoperability: not established; FFmpegfixture is negative compatibility evidence only.
- Parallel long-play/weak-network ABR: expressly excluded; foreign candidate and commit paths preserved.

Executor post-review adjustment: add braces for one formatter-exposed lint info; no semantic change. Final suite/analyzer and artifact/candidate/commit hashes are executor-owned manifest evidence.
