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

## Task 4 bounded route evidence boundary

The Apple managed fallback uses one Player-owned payload ledger across load and
recovery owners. A bounded load requires a working set for a presented frame and
its replacement plus compressed, audio, and network safety. The assigned budget
covers retained ring/rewind bytes, packet and conversion copies, submitted samples,
queued/published frames, scheduled PCM and conservative receive/parser workspaces;
OS/TLS/decoder/GPU internals, metadata and empty ring spare capacity are excluded.
Metrics report that ledger's assigned reservations, including live I/O workspace
admission. They are not a process-memory measurement. Other routes leave managed
buffer metrics absent.

R18: package-controlled HLS and bounded fallback cannot overlap. The same ledger
rejects preparation with `policy.unsupported` while an incompatible HLS owner or
payload-send completion, or a bounded scope, remains alive. Cancellation alone
is not proof of release; rejection preserves accepted playback. This temporary
transition restriction does not promise bounded AVPlayer or add a retry/downgrade.

R19: the new actual H264 hardware fixture may skip only on a Simulator when its
inspected subtype is H264 and `VTIsHardwareDecodeSupported` explicitly returns
false, with a retained capability attachment. Its controlled-VT counterpart must
execute. Physical iOS hardware playback remains final-acceptance work; a Simulator
skip or controlled output is not hardware evidence.

Bounded duration admission measures the current media epoch's retained compressed
samples, queued frames and PCM timestamp span. Packet, decoded output and audio
copies share their time interval while retaining independent byte receipts. Seek
starts a new time epoch without releasing old bytes. Admission pauses with room
for the largest observed packet/forward timestamp advance, then validates every
new interval against the exact maximum. Reordering within that span is supported;
a previously unseen larger interval that cannot fit is rejected, not allowed to
exceed the maximum. Missing AAC-LC packet duration can be derived only from a
complete, matching AudioSpecificConfig frame length and sample rate. Other unknown
durations/timestamps, arithmetic overflow and unsatisfiable reorder windows return
`policy.unsupported`. Compatible assessment therefore describes an enforceable
route subject to inspected media and runtime timing, not guaranteed success for
arbitrary unknown timing. EOF or actual producer capacity can start a nonempty
buffer below the minimum; the maximum remains enforced.

The supported H264/AAC Matroska fixture is checked with a 16 MiB byte limit and
100/2000 ms duration request. A separate real HTTP + controlled-VT case also
completes under 100/500 ms, and a 10000/12000 ms case proves EOF below the minimum
still starts and drains. The narrower case needs release-driven producer pauses
forecast from demux's greatest observed PTS as well as the retained queue span;
presenting a high-PTS frame does not erase the next-read frontier while older
audio remains queued. Compressed input time is retired when the audio converter
consumes it, while any remaining bookkeeping Data keeps its byte receipt.

AAC-LC duration resolution follows the AudioSpecificConfig object/rate/channel
layout and GASpecificConfig frame-length bit, not the converter's historical
1024-frame default. Primary implementation references are FFmpeg's
[MPEG-4 audio configuration parser](https://github.com/FFmpeg/FFmpeg/blob/n8.0/libavcodec/mpeg4audio.c)
and [AAC decoder GASpecificConfig / sample count](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/aac/aacdec.c).
Only the ordinary complete LC header, matching rate and known frame length is
resolved; unsupported objects/escape values, missing bits or unsupported core
coder/extension options do not acquire a guessed duration.
