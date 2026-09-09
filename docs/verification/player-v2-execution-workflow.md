# v0.2 execution workflow — consolidated final acceptance

Effective 2026-09-09, by explicit user instruction: defer full testing, independent review and comprehensive verification until all remaining implementation is complete. This project-specific instruction supersedes conflicting per-task/per-phase review and full-gate requirements in the approved plans, SDD briefs and skill defaults. Product requirements and final acceptance criteria are unchanged.

## During implementation

- Apply from Apple Hardening Task 2 through View/Cleanup/Release Task 7. Preserve already accepted work and historical evidence; do not repeat its reviews or gates solely to fit this workflow.
- Implement in dependency order. For each task, run the smallest meaningful checks covering changed behavior and downstream interfaces: affected-language analysis/compilation, focused contract/unit/widget tests, and targeted native lifecycle or policy tests when those mechanisms change. New behavior still requires tests; do not defer writing them.
- Shared Swift changes must compile on both iOS and macOS. Reuse incremental builds and selected test cases; platform compilation is not a full runtime regression. Run native builds serially and preserve each result before Xcode rotates it.
- Resolve known compile errors, failing targeted tests, broken required interfaces and incorrect capability claims before dependent work. Do not advertise strict capabilities whose mechanisms are not implemented. Inspect concrete cross-task risks when they arise, without routinely starting a broad independent review.
- Implementer self-check and a compact report replace the routine per-task independent review gate. Record BASE/HEAD, changed contracts, commands/results, known concerns and deferred checks. Label the checkpoint `implemented; focused checks passed; final acceptance pending`, never `review clean` or `fully verified`.
- Continue to the next task once its dependencies and focused checks are satisfied. Apple Hardening's phase-wide review/full gates are deferred too; View work may follow the implemented and focused-checked hardening interfaces without waiting for separate phase acceptance.
- Keep scoped local commits, existing evidence and recovery ledgers. Consolidate small same-shape changes when appropriate; do not mix conflicting implementation writers. No push, merge, tag or publish is authorized.

## One final acceptance stage

After all remaining code, fixtures, documentation and verification tooling are implemented, select a candidate revision and run the complete plan-required verification matrix. Include Dart analysis/tests, Android JVM and device coverage, iOS/macOS native and integration coverage, independent consumers/package managers, generated-transport drift, artifact/provenance checks, legacy/API cleanup checks, metrics/geometry/strict-policy evidence and publication dry-runs. Preserve the original acceptance criteria, exact executed case identities and skips. Required physical-device, architecture or runtime coverage remains pending if unavailable; substitutes or historical evidence must not be reported as a current pass.

Perform one coordinated independent review covering final spec compliance, code quality and cross-module behavior across the v0.2 change. Partition review by bounded module if necessary, with explicit coverage and one findings list; avoid duplicate broad reviews. Include all deferred concerns/rulings and inherited evidence limits. Reviewers reuse matching-revision test evidence instead of rerunning passing suites without a reason.

Batch findings into cohesive fixes. Rerun affected checks and scoped re-review of the fixes. Reuse unaffected evidence only when relevant source, generated files, dependencies, build configuration and fixtures remain unchanged; record that mapping to the final revision. Cross-cutting fixes with uncertain impact require the wider affected matrix or a full rerun. Final verification is not a promise to run each command only once regardless of subsequent changes.

Close only when required checks and review findings are resolved or explicitly reported as outstanding. Do not mark final acceptance complete with required coverage missing. Retain all SDD recovery/evidence until the five-plan objective and durable decision record are complete.

## Tradeoff and current state

Ruling R15: defer routine per-task independent reviews and repeated phase-wide gates to one final acceptance stage, retaining focused checks and interface validation during implementation — the user explicitly requests lower execution overhead; this reduces repeated context loading/builds but can discover cross-module defects later and increase final rework. No fixed time saving is claimed.

At adoption, latest accepted commit is `65cdfd5e4a7b22812a66582c16988fb07be59876`. Hardening Task 2 has preserved uncommitted work and incomplete focused checks; it has not passed acceptance. Its worker was interrupted by a service usage limit. This workflow update does not resume the worker, redeem credits or establish that capacity has recovered.
