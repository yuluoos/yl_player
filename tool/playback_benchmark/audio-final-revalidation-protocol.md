# Audio integration final-version revalidation — 2026-10-08

Base: `cf094a752e4f1bf837cad774719d92efbeff302c`. Verification-only follow-up to Task5: close the explicitly recorded
post-review binary measurement gap. No production/test/measurement implementation changes.
Reuse audio-integration-protocol.md and the exact archived probe/validator scripts.

Before execution, verify every source, binary and fixture hash against the final
645/645 native suite identity. If unchanged, reuse that suite and the iOS arm64
compile result; do not rerun builds or the full suite solely to update commit labels.
Freeze HEAD, both protocol hashes, script hashes and the prior-suite identity.
Use fresh, never-overwritten run directories for every attempt.

Planned runs, sequential: candidate long (56485 buffers, >=1200s valid observation),
legacy resource (2000 buffers/four heap slots), candidate resource (same).
Long: no MSL, no heap/vmmap/builds, one PID/generation, 241+ playing samples,
<=7.5s gaps, 90–110% per-interval clock/frame progress, <=5s cumulative drift,
zero order/interior-zero/sticky errors, exact57840640frames,56484rendered+1played
submissions/callbacks, ledger<=196608B and zero post-dispose/+2s.

Resource collection retains the original frame/order assertions, heap timeouts
and raw outcomes. Four acquired slots do not make a failed XCTest pass. Missing
heap classes remain unknown, not zero. Historical heap-induced tap failures stay
failed; new failures also stay failed. No resource-growth bound is invented.

Archive all commands, identities, environment, raw rows, XCTest exports, heap
outputs, failures and validator results separately from Task5 historical evidence.
Update P08 report/overview with exact final-version outcomes and remaining gaps.
DefaultEnabled, productionAdmission and downstreamBoundProven remain false;
this does not supply physical AV/route, minimumOS/Intel/iOS-runtime proof.
Commit the verification evidence locally; no push or candidate enablement.
