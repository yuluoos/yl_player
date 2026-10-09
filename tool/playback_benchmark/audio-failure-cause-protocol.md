# Audio failure cause attribution — 2026-10-09

Base4df1aa5. Continue the approved P08 next item: distinguish configuration
invalidation from native start failure after the870.888s decoded probe stopped.
Do not change production audio recovery, scheduling or error codes in this item.
Candidate enablement and production/downstream-bound admission remainfalse.

Recover narrowly scoped unified logs for the prior owned process43219 in the
02:01:45–02:02:20 local window. Preserve selected audio lifecycle messages with
addresses/device identifiers removed, plus original log SHA256 and query scope.
Never include unrelated process logs or publish device identifiers in evidence.

Evidence already found: HAL default-output device change, native device change,
engine IO transport interruption, approximately4s later configuration-change
engine stop, then configuration notification. This materially narrows the prior
failure without another blind20min rerun. It does not identify who initiated the
route change, prove the older one-drop run's cause, or validate device recovery.

Test-only IntegrationOutput wraps actual invalidation and play throw boundaries.
Keep at most32 scalar events with sequence/time, cumulative counts, and safe
renderer error reason/message/diagnostic. Only fixed package-owned messages and
allowlisted NSError domains/numeric codes may be captured; no raw descriptions,
userInfo, paths or object payloads. Record engineRunning and raw node clock in
normal decoded observations. Preserve existing native output/renderer behavior.

Tests: strengthen real graph-notification and disposed-native-adapter start
failure regression, plus history-bound/redaction regression. Show actualRED
before filling the recorder. Add Python failure-report coverage; fresh static
review, final full macOS native and fixture parity/discovery validation. No shared
production or iOS test changes, so do not repeat an iOS build or claim new iOS
runtime coverage. Frozen30s decoded short probe verifies collector wiring.
Do not run another long arm in this diagnosis item: prior failure and recovered
system evidence remain the basis for attribution, and long acceptance staysopen.

The native notification regression posts only the process-local AVAudioEngine
notification; no system output device is changed. Actual route-change recovery,
source reload/resume and user-visible recovery policy remain separate work.

Review corrections: synchronous startup throws now write startupFailure and
post-cleanup disposed observations before rethrowing, preserving failed prefixes
without treating them as valid playback. Regression first failed on missing
prefix. Audio cause validation requires a preceding matching event, including
legitimate evicted-prefix counts; reversed-order configuration/start causes
both demonstratedRED, then passed with the corrected gate.
