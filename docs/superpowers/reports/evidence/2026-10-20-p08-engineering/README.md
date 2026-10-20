# P08 engineering validation evidence

Baseline: `ab734051`. This directory records engineering validation, not full
performance or release acceptance. P01–P07 historical physical observations stay
in their reports. No prior failure is replaced by these results.

Implementation mapping:

- A: a strict multi-metric contract preserves complete planned trials, warmups,
  failed/timeout/cancelled/skipped outcomes and cleanup uncertainty. Explicit
  boundary/unit pairs distinguish event receipt, commands, actual output,
  source clocks, buffering, process, GPU, script and media-ledger observations.
  Missing data stays null. The public runner now retains setup failures and
  independently disposes late player creation and all acquired resources.
- B: write-once baseline freezing takes explicit product limits, qualified
  content evidence, minimum sample count, warmup policy and allowed failures.
  Profile/release, fixed device/OS/network/cache/power/thermal/method and
  calibrated output/source clocks are checked where applicable. No numeric
  targets are fabricated. The threshold registry names the remaining profiles.
- C: comparison checks absolute p50/p95/max and an optional p95 regression bound;
  noncomparable new capabilities never produce improvement percentages.
  The public two-player workload measures command/event boundaries and tests
  peer isolation, seek/resume, replacement, stale commands and release. Existing
  native PCM/host-channel optimizations remain evidence-driven and unchanged.
- D: release inventory records current source/report identities, actual local
  commands and unresolved acceptance. Local tool success does not authorize
  publishing or replace remote CI or physical/minimum-OS acceptance.

Observation inputs can attest their own content/calibration evidence; the tools
verify structure and identities, not the truth of a human physical measurement.
A hash or a passing gate is not a physical-output claim. Gate limits and fixture
protocol must be approved/frozen before the optimization being evaluated.

Scope ruling: complete reusable engineering while keeping environment-dependent
acceptance open. Cost: a usable measurement system is delivered without a claim
that P08's numeric SLOs or the entire playback upgrade have passed.

Validation outcomes:

- P08 Python 280/280; example Dart 101/101; focused ownership/reporting/probe 12/12.
- Foundation executed all stages, with template, formatting and command-directory
  fixes validated where they failed. Ten Dart/standalone subruns total 2318 passes.
  One existing Dolby-tool skip is retained, not counted as a pass.
- Final public profile workload 3/3, source unchanged. Four earlier collection
  attempts (including setup failure and the invalid concurrent-peer assumption)
  remain in separate receipts; no successful rows are spliced across builds.
- Nine package publication dry-runs passed with zero warnings. An earlier run
  correctly warned about the not-yet-committed package file; it was not published.
- Android APK, iOS CocoaPods and iOS SwiftPM consumer links passed. Both macOS
  managers failed at the host Flutter/lipo multi-architecture verification. Each
  architecture verifies individually; the combined invocation reports exactly-one-
  input error despite the universal binary containing both. SDKs remain unchanged.
- Combined engineering entry passed; required-readiness exits 1 with four pending
  physical profiles. Remote CI, full presentation/phase capture, numeric targets
  and complete device/long-duration acceptance are not claimed.

The fresh review found two Important defects (profile constraints and native source
coverage), reproduced and fixed. A presentationProven reporting label was elevated
from Minor to a correctness fix and renamed. No deferred minor, no second review.
See `review.md` and `validation.json` for exact evidence identity.
