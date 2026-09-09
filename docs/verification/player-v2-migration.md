# Player v0.2 Dart API and SPI migration evidence

Status: the prior Task 9 checkpoint was accepted at implementation commit
`fcd2056d3274afcd1cfe765fb5e1a260b64bf90b`. The subsequent whole-phase review
found four Important boundary defects; the final fix wave below is implemented
and validated, awaiting the parent's scoped rereview. This is not full v0.2
release approval. The application API and handwritten
SPI now expose the v0.2 model. The temporary channel compatibility adapter is
isolated behind `yl_player_legacy_transport.dart`, outside the application barrel.

## Workspace and preserved baseline

Development branch: `codex/player-v0.2`, based on `5974434`.

Previously reviewed implementation: atomic cutover `72bc790`, boundary fixes
`2a047d9`, and command-registration retention fix `fcd2056`. Independent review
approved Tasks 6–8 after the final fix with no open Critical or Important finding.

The original `main` checkout remains at the reviewed baseline. The local linked
worktree is `.worktrees/player-v0.2`; resolve all commands from its repository
root. No publish, push, merge or release tag has been performed.

The baseline includes the original channel/macOS changes in `1b239e0` and
`49f59cf`, plus the reviewed queue, audio, display and plan corrections in
`5974434`. Their prior verification is recorded in
[review optimization evidence](2026-09-07-player-v2-review-optimization.md).

## Dart API and SPI checkpoints

| Task | Status | Commit / evidence |
| --- | --- | --- |
| 0 — migration versions | Complete, independently reviewed | `4247898`; five packages and all ten local dependency edges use `0.2.0-dev.1` / `^0.2.0-dev.1`. |
| 1 — safe values | Complete, independently reviewed | `eeb6011` plus `aec1f01`; all review findings resolved. |
| 2 — sources and policies | Complete, independently reviewed | `b12d727`; additive internal models and validation. |
| 3 — state and events | Complete, independently reviewed | `e561f41`; 17 focused tests and 94 platform-interface tests passed. |
| 4 — SPI and conformance | Complete, independently reviewed | `cca816c` plus `477b2b0`; 36 focused tests and analysis pass after fixes. |
| 5 — native Stop | Complete, independently reviewed | `6fb48ad` plus `807669e`; real resource/clock race regressions and native gates pass. |
| 6–8 — atomic API cutover | Complete, independently reviewed | `72bc790` plus `2a047d9` and `fcd2056`; all original Important findings and the retention follow-up are resolved. |
| 9 — phase acceptance | Complete in this checkpoint | Exact forbidden-surface scans, format, analysis, diff checks and the coverage inspection below pass at `fcd2056`. |

## Prior Task 9 acceptance

### Required behavior coverage

The following inspection was performed against `fcd2056`. Existing focused and
foundation tests are cited as evidence; unchanged suites were not rerun merely to
populate this document.

| Requirement | Code and test evidence |
| --- | --- |
| Explicit creation | `YlPlayerController.create` validates options, creates through `YlPlayerPlatform`, validates SPI/capabilities/state, attaches both streams and owns cleanup (`player_controller.dart:11`). `player_controller_test.dart:7` exercises explicit creation and attachment. |
| Load commit | The SPI says `load` returns only after the commit/state barrier (`platform_player.dart:29`, `platform_load_result.dart:3`). The legacy adapter tests both reply/state arrival orders and refuses either half alone (`channel_player_test.dart:259`, `:388`, `:494`). |
| Ready | A committed session has a distinct `ready` future (`playback_session.dart:8`); controller state advances it only on Ready/Playing or authoritative load-to-ready evidence (`player_controller.dart:179`). `playback_session_test.dart:169` proves commit does not imply Ready. |
| First Frame | A committed session has a distinct `firstFrame` future (`playback_session.dart:9`), completed only by a current-session `YlFirstFrameEvent` (`player_controller.dart:203`). `playback_session_test.dart:169` and `:207` cover normal and early-event ordering. |
| Stale sessions | Every session command checks the current, non-stopped session before reaching the backend (`player_controller.dart:85`, `playback_session.dart:10`). Replacement and Stop rejection are covered at `playback_session_test.dart:169`, `:296`, and `:304`. |
| Stop | `YlPlayerController.stop` cancels pending Load, awaits native Stop, then invalidates the matching handle without inventing idle state (`player_controller.dart:227`). Delayed-idle, rejected-Stop, late-event and late-reply boundaries are covered at `playback_session_test.dart:304`, `:327`, and `:341`; adapter authority is covered at `channel_player_test.dart:667`. |
| State revisions | Controller state accepts only strictly newer revisions (`player_controller.dart:170`); equal/older state and disposed callbacks are covered by `player_controller_test.dart:20`. The adapter drops older native generations at `channel_player.dart:352`. |
| Event correlation | Controller events must match the authoritative current session and exclude a stopped session (`player_controller.dart:203`). The adapter correlation regression is `channel_player_test.dart:615`; early older same-session First Frame coverage is `playback_session_test.dart:207`. |
| Strict-policy rejection | The temporary adapter assesses unsupported strict requirements as incompatible and returns `policy.unsupported` before opening (`channel_player.dart:91`). `channel_player_test.dart:376`, `:512`, and `:552` cover audio ownership, cancellation ordering and strict network/decoder/buffer rejection. |
| Safe diagnostics | `YlSafeDiagnostics` removes URI, header, credential, path, query, line-break and stack-frame shapes and bounds output (`safe_diagnostics.dart:1`). `failure_test.dart:121` through `:355` and `channel_player_test.dart:642` cover public and translated native failures. |
| Structural equality | Value models implement field-based equality and matching hashes. Representative regressions cover failures/session IDs (`failure_test.dart:5`), state and immutable collections (`state_models_test.dart:39`, `:74`, `:655`), policies/options (`source_and_policy_test.dart:607`), and SPI identities/results (`v2_player_platform_test.dart:39`). |
| Third-party conformance | The public `testing.dart` entry exports `YlPlatformConformance` and its fixture contract (`platform_conformance.dart:46`, `:90`). `platform_conformance_test.dart:8` runs the complete observable suite against a fake implementation; its negative fixtures verify that missing lifecycle, policy, ordering, safety and cleanup guarantees are detected. Transport reply ordering and unobserved milestone errors remain in the adapter/controller suites because they are not generically SPI-observable. |

The application barrel boundary also has a negative analyzer regression:
`public_api_test.dart:29` verifies that importing `package:yl_player/yl_player.dart`
cannot resolve `YlPlayerPlatform`, while the v0.2 application values are exported.

### Exact Task 9 checks

Commands ran from the worktree root with Flutter/Dart from
`/Users/yy2021_8689/flutter/bin`.

| Command | Outcome |
| --- | --- |
| `rg -n 'YlPlayerConfiguration|YlBufferMode|YlFormatHint|YlPlayerError|YlTracksChangedEvent|YlFallbackEvent|isHardwareDecoding|platformDiagnostic' packages --glob '*.dart'` | Exit 0 with exactly three quoted wire-fixture hits: `channel_codec_test.dart:24` (`isHardwareDecoding`), `channel_codec_test.dart:38` (`platformDiagnostic`), and `channel_player_test.dart:651` (`platformDiagnostic`). These exact inputs test unknown legacy decoder evidence and unsafe native-diagnostic redaction. They are not declarations, exports or production references. No broader test-directory exception applies. |
| `rg -n 'MethodChannel|EventChannel|createYlLegacyChannelPlayer' packages/yl_player/lib packages/yl_player_platform_interface/lib/yl_player_platform_interface.dart` | Exit 1 with no output, the expected no-match result. The app library and default SPI barrel expose no channel implementation. |
| `rg -n '[T]ODO|[F]IXME|[T]BD|[X]XX' docs/superpowers/plans/2026-09-06-player-v2-dart-api-and-spi.md` | Exit 1 with no output, the expected no-match result. |
| `dart format --output=none --set-exit-if-changed packages` | Exit 0: 77 files, 0 changed. |
| `flutter analyze` | Exit 0: no issues. Dependency resolution reported seven newer versions outside current constraints; this is advisory output. |
| `git diff --check` | Exit 0 with no output. |
| `git status --short` | Before the documentation commit, only `M docs/verification/player-v2-migration.md`, the transferred intentional Task 9 edit. No baseline change was lost and no package file changed during acceptance. |

### Historical gate evidence retained from Tasks 6–8

The final foundation command at `fcd2056`,
`PATH=/Users/yy2021_8689/flutter/bin:$PATH sh tool/check_foundation.sh`, exited 0
in `/private/tmp/yl-v2-r2-foundation.log`: 169 Dart tests passed
(135 platform interface + 24 app + 2 app example + 2 Android + 1 Android
example + 2 iOS + 1 iOS example + 2 macOS), analysis reported no issues,
format checked 77 files with 0 changes, and both FFmpeg contracts passed. The
latest focused adapter/controller command passed 48 tests in
`/private/tmp/yl-v2-r2-dart-green.log`. The rejected temporary listener
instrumentation is not counted as a behavioral RED; the old retention defect was
established from the exact old adapter and installed Dart SDK listener behavior,
then the final actual pending-registration invariant was tested directly.

No unchanged full native suite was rerun for Task 9. The atomic cutover's latest
complete native evidence remains Android 73 JVM tests; iOS 214 XCTest passes,
3 explicit hardware-unavailable skips and 10 integration passes; and macOS 83
XCTest passes, 9 integration passes, universal/link/minimum-macOS/entitlement
checks and a Rosetta smoke pass. Round 1 subsequently changed only the two Apple
HLS proxy parsers: each exact-query parser XCTest passed once, and each platform's
three real HLS cases passed with Ready, First Frame, standard/custom credential,
ordinary-header and origin-stripping assertions. Those scoped latest results are
`/private/tmp/yl-v2-r1-{ios,macos}-parser-summary.json`,
`/private/tmp/yl-v2-r1-ios-hls-final.log`, and
`/private/tmp/yl-v2-r1-macos-hls-final2.log`. Round 2 changed Dart only, so the
Apple evidence remains applicable without pretending a later full native rerun.

The macOS HLS runs needed a process-bound display-awake assertion after identical
code failed First Frame with the display asleep; it was released after each run
and no production display workaround was added. Simulator/JVM/Rosetta evidence
does not establish physical iOS playback, Android device playback, Intel-native
execution, endurance or profiling. The three iOS skips are hardware decoder
limitations; integration cases that accept decoder-unavailable are not positive
playback proof.

## Final phase review fix wave

Base: `42e45e150b28e1bd770847f84f1ce3c0ae5d3e8b`. Implementation commit:
`f7c0f4412ef28cc04a1769894269f918393dfafd`. Parent rereview covers the entire
wave together, including rulings 18 and 19.

- macOS active fallback replacement samples the default audio-backed clock
  outside `stateLock`, with a generation check before saving the position. The
  real owner replacement regression reached the old lock cycle; its stack sample
  is `/private/tmp/yl-v2-phase-replacement-deadlock-sample.txt`. The fixed test
  commits a new generation/load token while keeping the texture and fallback active.
- macOS initial routing, AV validation and rollback classification share one
  source descriptor that includes separate credentials. A real slot, AV backend
  and encrypted HLS server prove authenticated master/media/key/segment requests,
  actual decoded video and unchanged public identity after candidate activation
  fails following quiescence. The test follows production
  `takeRollbackRequiresExternalActivation()` and the actual prepared-HLS methods;
  it does not cover the owner's asynchronous recovery scheduling.
- Late native Create replies retain an ownership continuation after the caller
  times out. A returned identity receives one bounded best-effort disposal;
  malformed creation and cleanup nonreply preserve the original failure. Late
  native and cleanup errors are consumed. Cleanup cannot force an unresponsive
  native process to release resources.
- Direct SPI Stop fences the captured session after acceptance, before native
  idle arrives, and suppresses stale milestone/retry/failure events. Rejected
  Stop and an older reply after newer Load preserve the healthy identity.
  Conformance checks rejection immediately and waits for real idle within its
  existing deadline; it never invents an idle snapshot.
- The confirmed analogous iOS HLS rollback defect is included under ruling 19.
  iOS keeps preparation before quiescence and retains the real controlled asset,
  loader and play intent only during synchronous replacement. Successful commit,
  failed restoration, Stop, disposal and ordinary deactivation finalize retained
  resources. The real slot regression restores video, speed, volume, playing and
  paused intent, and unchanged generation. Real loader cancellation is checked at
  every terminal boundary. iOS reuses the controlled loader/cache; unlike macOS,
  this does not claim a new origin fetch for every resource after rollback. No
  macOS lock or asynchronous recovery architecture was copied to iOS.

### Final affected validation

Commands start at the linked worktree root using
`YL_REPO_ROOT=$(git rev-parse --show-toplevel)` and `cd "$YL_REPO_ROOT"`.
Flutter/Dart use `/Users/yy2021_8689/flutter/bin`. Apple commands run serially
from `packages/yl_player/example` after the platform's Flutter `--config-only`
build. Actual playback is wrapped with
`python3 /private/tmp/yl-v2-r1-run-awake.py <command>`; each temporary,
process-bound display assertion was released. No global display settings changed.

| Command / scope | Final result and evidence |
| --- | --- |
| `PATH=/Users/yy2021_8689/flutter/bin:$PATH sh tool/check_foundation.sh` | Exit 0; 178 Dart tests (144 SPI, 24 app, 10 package/example tests), clean analysis, 77 files with no formatting changes, both FFmpeg contracts. `/private/tmp/yl-v2-phase-foundation2.log`. The first invocation stopped at two test brace lints, then those were corrected. |
| `xcodebuild test -quiet -workspace macos/Runner.xcworkspace -scheme Runner -destination platform=macOS -parallel-testing-enabled NO -only-testing:RunnerTests -resultBundlePath /private/tmp/yl-v2-phase-macos-final.xcresult` | Exit 0; 86 passed, zero failed/skipped. Matching `-summary.json` and `.log` retain results. |
| `flutter test integration_test/macos_hls_headers_playback_test.dart integration_test/macos_mkv_playback_test.dart -d macos` | HLS 3 passed. Command exit 1 because the second app launch failed before any MKV case executed. `/private/tmp/yl-v2-phase-macos-playback-final.log`. This combined command is not reported as passing. |
| `flutter test integration_test/macos_mkv_playback_test.dart -d macos` | Exit 0; 2 passed, actual First Frame/decoder/seek/geometry/track assertions. `/private/tmp/yl-v2-phase-macos-mkv-final.log`. Covers the unexecuted file; unchanged HLS was not repeated. |
| `xcodebuild test -quiet -workspace ios/Runner.xcworkspace -scheme Runner -destination 'platform=iOS Simulator,id=431A3ACD-A229-4F82-AC46-9B9481AC0ADE' -parallel-testing-enabled NO -only-testing:RunnerTests -resultBundlePath /private/tmp/yl-v2-phase-ios-final2.xcresult` | Exit 0; 218 passed, 3 existing hardware skips, zero failed. `/private/tmp/yl-v2-phase-ios-final2-summary.json` and `.log`. Final run contains no temporary diagnostics. |
| `flutter test integration_test/ios_hls_headers_playback_test.dart -d 431A3ACD-A229-4F82-AC46-9B9481AC0ADE` | Exit 0; 3 passed. `/private/tmp/yl-v2-phase-ios-hls-final.log`. Original standard/custom credential, ordinary-header and sticky cross-origin stripping assertions remain intact on both Apple platforms. |

Test stability limitation: the first full iOS native command exited 65 with
217 passes, 3 existing skips and one failure in the new HLS test's initial
preflight, before quiescence/rollback. It returned HTTP 403 although the fixture
only emits 200 or 401. Original evidence remains in
`/private/tmp/yl-v2-phase-ios-final.xcresult`, its `.log`, and
`/private/tmp/yl-v2-phase-ios-final-hls-activities.json`. Inspection found no
registered global URLProtocol in the named tests. A full-order catch-only
diagnostic rerun passed (218/3), so diagnostics never identified the response
origin; they were removed before the final clean full rerun above. The cause
remains unknown. Passing reruns are not a root-cause repair; no speculative
production retry, global isolation change or weakened authentication was added.

Corrected Dart RED was 70 passes/4 expected failures; final focused Dart was
94 passes. Initial invalid cleanup-Future instrumentation is excluded from RED,
as is the prior round-2 altered-observer experiment noted above. Native REDs
include the sampled macOS lock cycle and real initial-success/restored-video
failure on both platforms. iOS playing-intent verification additionally exposed
and fixed missing playback restart after restored asset installation.

Android JVM 73, prior release universal/link/minimum-macOS/entitlement checks,
and Rosetta evidence above are historical and were not rerun for these changes.
No new release-artifact validation, physical iOS/Android/Intel-native playback,
endurance, profiling or universal native strict-policy support is claimed.
The existing example Pause/Stop UI issue remains deferred. The local full
command and coverage ledger is
`.superpowers/sdd/2026-09-06-player-v2-dart-api-and-spi/phase-fix-report.md`.

### Task 0 validation

Commands ran before and after the version change:

```sh
flutter pub get
flutter analyze
flutter test packages/yl_player_platform_interface/test
flutter test packages/yl_player/test
(cd packages/yl_player/example && flutter test test)
flutter test packages/yl_player_android/test
flutter test packages/yl_player_android/example/test
flutter test packages/yl_player_ios/test
flutter test packages/yl_player_ios/example/test
flutter test packages/yl_player_macos/test
git diff --check
```

All commands passed. Eight Dart suites contain 71 tests in total. The resolver
left `pubspec.lock` unchanged because workspace member versions are not recorded
there. The three examples remain non-publishable. No dependency override was
added. Existing package-update and Flutter CocoaPods/SPM migration advisories
remain advisory output.

### Task 1 initial validation

Missing-type tests failed before production code existed. After implementation,
11 focused tests and all 50 platform-interface tests passed; root analysis and
diff checks passed. Runtime equality and hostile failure-field negative controls
were also verified. These initial results apply to `eeb6011`. Review fixes in `aec1f01` add
credential assignment, generic URI, HTTP token-name and structured metadata
regressions. The final focused suite has 16 passing tests; all 55 platform-
interface tests and root analysis pass. Scoped independent re-review approved
both spec compliance and quality with no open findings.

## Cross-task findings to resolve before public cutover

- Task 3 resolved the assessment-ID grammar conflict: exact camelCase core IDs
  and bounded ASCII extensions are validated and covered by tests.
- The legacy native audio behavior cannot honor v2's default `appManaged`
  merely by changing a Dart option. Native configuration must prevent automatic
  shared-session/focus mutations before that default is exposed.
- Rebuilding an Apple fallback backend during reactivation must preserve the
  committed public session identity. A temporary transport generation must not
  stale a still-current session handle.

Diagnostics syntax references used in review:
[HTTP token grammar](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.6.2)
and [URI schemes](https://www.rfc-editor.org/rfc/rfc3986.html#section-3.1).

## Remaining evidence

Android typed transport, Apple consolidation/hardening, final view/cleanup,
independent consumer builds, code generation drift checks and publication dry
runs remain pending. No physical-device, Intel-native, endurance or profiling
claim is implied by the Dart checks above.

Environment preflight found a booted iPhone 17 on the iOS 26.5 Simulator runtime
and Android SDK API 36. Availability is not a passing native test result.

## Native baseline in the migration worktree

These checks ran before native v2 changes, to establish a reproducible starting
point for the native migration. They are not final v2 platform acceptance.

| Command | Result |
| --- | --- |
| Android example: `./gradlew testDebugUnitTest --stacktrace` | Passed; XML reports 69 tests, zero failures/errors/skips. |
| `sh tool/check_native_macos.sh --unit-only` | Passed; XCTest result bundle reports 71 passed, zero failed/skipped. |
| `sh tool/check_native_ios.sh` | Passed; XCTest reports 199 passed, zero failed, two skipped; five integration suites pass with 9 cases. |

The fresh worktree needed ignored Gradle wrapper script/JAR files, copied from
the original checkout. No Gradle version, native source or tracked build setting
was changed. Existing AGP/Kotlin, CocoaPods and Swift compiler advisory output
remains recorded in the command logs.

The two iOS XCTest skips are
`YlFallbackBackendTests/testNetworkFlvReconnectsWholePipelineFromByteZeroAfterEOF`
and `YlFallbackBackendTests/testRejectedQualityConstraintKeepsActiveFallbackUsable`:
the Simulator runtime does not expose hardware H.264 decoding. MKV/FLV integration
cases explicitly accept `decoder.video_hardware_unavailable`; those passing
results do not prove fallback playback or throughput on physical iOS hardware.

Logs are `/private/tmp/yl-player-v2-android-baseline.log`,
`/private/tmp/yl-player-v2-macos-baseline.log` and
`/private/tmp/yl-player-v2-ios-baseline.log`. Exact native test counts were read
from Gradle XML and XCTest result bundles, rather than inferred from truncated
quiet-build text output.

## Task 2 validation

`b12d727` adds source/request/policy models and release validators behind the
internal v2 barrel. Focused tests: 22 passed; platform-interface suite: 77 passed;
package and root analysis: no issues. Independent review approved spec compliance
and quality without findings. v1 production barrels and models remain unchanged.

Exact policies require whole milliseconds and signed32 timeout/count/byte bounds;
media positions retain nonnegative signed64 transport semantics. Credential
classification is conservative for custom names, reserved transport headers and
case-insensitive duplicates are rejected, and validation errors never echo
rejected source/request input. Empty userinfo separators normalized away by Dart
`Uri` cannot be detected at a Uri-typed boundary; observable userinfo is rejected.

## Task 3 validation

`e561f41` adds immutable state, capabilities, assessment, geometry, timeline,
tracks, metrics and four session-correlated events. Focused tests: 17 passed;
platform-interface suite: 94 passed; root analysis and diff checks passed.
Independent review approved spec compliance and quality without findings.

Const values require explicit release validation at controller/native publication
boundaries. Controller revision chronology, native duration overflow checks and
negative live-offset normalization remain requirements of the upcoming adapters
and controller; these value-model tests do not claim those integrations exist.

## Task 4 validation

`cca816c` adds the v2 handwritten SPI, token-verified registration and the public
`testing.dart` conformance entry. Initial focused tests: 31 passed; full platform-
interface suite: 125 passed; root analysis passed. Review found three runner gaps
covering current-source seekability, omitted credentials and short-header false
positives. `477b2b0` adds failing regressions and fixes; all 36 focused tests and
root analysis pass. The full package suite was not repeated for this scoped fix. Scoped independent
re-review approved all three fixes with no new findings.

Each conformance case has isolated resources, a deadline and bounded cleanup,
including late creation/errors. Generic conformance requires declared successful
source/policy evidence but permits honest unsupported strict policies; advertised
managed native routes must separately prove their known strict-success cases.
Secrecy checks use distinctive metadata canaries of at least 16 characters plus
unsafe-shape checks; they are finite fixture evidence, not universal data-flow
proof. Native transport ordering and controller milestone tests remain required.

## Task 5 validation

`6fb48ad` implements native Stop with cancellation and generation guards, idle
reset, preserved player/texture identity and fresh reload. iOS fresh-open audio
reactivation is tested separately from inert lifecycle activation after Stop.

Initial implementation gates: Android 70 JVM tests; macOS 75 XCTest tests; iOS 203 XCTest passes,
zero failures and two existing hardware skips, plus nine integration cases
(2 HLS, 2 local MKV, 3 network MKV, 1 HTTP-FLV, 1 authenticated HLS). Android JVM
evidence does not prove device playback. Simulator fallback limitations recorded
in the baseline still apply.

An unchanged macOS display-timer assertion failed on an earlier run and passed
two subsequent combined serial runs; it was not weakened. Earlier overlapping
Apple builds also encountered dependency/install errors, including a missing
Runner.app. Shared build contention is a hypothesis rather than a confirmed root
cause. Final Apple scripts ran serially and exited successfully. Final result
summaries are `/private/tmp/yl-player-v2-stop-macos-final-summary.json` and
`/private/tmp/yl-player-v2-stop-ios-final-summary.json`.

Independent Task 5 review identified two gaps despite the passing gates:
Stop could race with an already-running fallback seek and allow late decoder/
clock mutation, and AV seek after Stop could repopulate idle position.
`807669e` reproduces both problems, including a real clock advancing after Stop,
then serializes resource commits with teardown and validates generation/token
inside executing main-thread clock closures. Late decoder candidates are disposed.
Stopped AV source commands leave idle unchanged.

The deterministic construction barrier covers both generation invalidation alone
and explicit command cancellation. The worker queue can be drained by main-thread
Stop without a new synchronous worker-to-main dependency; clock/restart/event
main closures are invoked outside worker serialization. External synchronous
VideoToolbox construction cannot be preempted, but its late result cannot commit.

Fix-round gates ran serially: `sh tool/check_native_macos.sh --unit-only` passed
77 XCTest cases; `sh tool/check_native_ios.sh` passed 205 XCTest cases, with zero
failures and the same two hardware skips, plus all nine integration cases. Both
scripts exited zero. Result summaries are
`/private/tmp/yl-player-stop-r1-macos-final-summary.json` and
`/private/tmp/yl-player-stop-r1-ios-final-summary.json`. Android source did not
change in this round, so its passing 70-test gate was not repeated. Scoped
independent re-review approved both fixes and the queue ordering, with no new
Important/Critical findings. Root `flutter analyze` also passed after the fix.

## Appendix: chronological phase rulings

This is the durable extraction of the Task 9 rulings and the final phase review
follow-ups: 19 rulings in total. Ledger line references preserve chronology; each
entry records its reason and the cost or risk accepted if the ruling is wrong.

1. **Ledger line 6 — local worktree ignore.** Use a self-ignoring
   `.worktrees/.gitignore` for the local worktree container. This avoids a
   setup-only commit on `main` while keeping all worktree contents ignored. Cost:
   the local ignore is environment state that must be maintained and removed
   independently when the container is retired.

2. **Ledger line 34 — SPI-observable conformance only.** The conformance runner
   may test only SPI-observable guarantees through declared fixture hooks;
   reply-order and unused milestone Future behavior must also be tested in the
   transport/controller suites where observable. Unsupported fixture APIs must not
   be invented silently. Cost if wrong: generic conformance may miss a guarantee,
   so separate transport/controller suites must retain ordering and
   unobserved-Future tests.

3. **Ledger line 46 — assessment identifier grammar.** The lowercase-only
   extension-ID regex conflicted with exact camelCase Apple wire IDs such as
   `network.platformDefault`. Preserve specified core IDs and permit camelCase in
   validated segments while requiring a lowercase initial, separators, bounded
   length and redacted strings. Reason: the specification requires stable validated
   IDs, not lowercase-only IDs. Cost: the extension grammar permits additional safe
   ASCII strings.

4. **Ledger line 55 — managed network defaults.** Managed-constructor defaults
   were unspecified, so retain existing defaults only for the explicitly selected
   managed constructor: 10-second connect, 15-second read, 3 retries, 500 ms base,
   8-second maximum delay and 5 redirects. `platformDefault` leaves unused fields
   null. Cost: these API defaults must remain documented consistently.

5. **Ledger line 87 — strict conformance evidence.** Generic conformance requires
   one declared known-success source/policy case and executes each declared strict
   success case, but it does not require every third-party implementation to
   support a strict route. Spec §13 permits honest policy rejection; mandatory
   managed-route success belongs in native platform acceptance. A fake that rejects
   a declared strict success must fail. Cost if wrong: generic conformance alone
   cannot prove native strict support, so platform suites must retain known
   managed-success fixtures.

6. **Ledger line 99 — initial channel snapshot.** Add a private per-player
   `requestState` command and subscribe/request/first-full-state creation barrier.
   All three legacy create replies omit a snapshot and only EventChannel `onListen`
   emits initial state, so a second player could otherwise time out on the shared
   stream. `requestState` calls existing state emission without activation or
   peer/audio effects. Cost: one temporary private command to remove with typed
   transport; this avoids unbounded pre-ID buffering and requires second-player and
   failed-snapshot cleanup tests.

7. **Ledger line 101 — atomic Tasks 6–8.** Treat the adapter, controller and public
   cutover as one implementation and review unit with one green commit. The plan
   prohibited Task 6/7 intermediate commits, and splitting them would create broken
   commits or falsely empty diff reviews. Cost: a larger review diff, mitigated with
   focused responsibilities, tests and native preflight contexts.

8. **Ledger line 103 — authenticated Apple HLS bridge.** Extend the controlled
   legacy HLS policy minimally for explicit credential names and sticky stripping
   across redirects/retries. Existing policy handled only three standard names and
   restored credentials after returning to the original origin; opaque routes may
   still reject credentials honestly. Reason: authenticated HLS success and the
   mandatory source-origin boundary both had to survive v2 source acceptance. Cost:
   duplicated temporary Apple policy support before consolidation.

9. **Ledger line 120 — temporary audio ownership limit.** The bridge implements
   default `appManaged` and rejects explicit `pluginManagedMediaPlayback` with
   `policy.unsupported` before native creation until typed native ownership
   coordinators exist. Existing per-engine/per-plugin audio mutation cannot meet
   shared reference-counted ownership. Legacy absent config retains v1 behavior.
   Cost: the development-only convenience mode is unavailable during this phase;
   later native work must implement it before publication.

10. **Ledger line 134 — candidate load correlation.** Add private candidate-owned
    load metadata and echo it on committed state/reply. Dart serialization and newer
    generation alone cannot disambiguate a prior commit callback already queued
    before a newer Load, and native cancellation cannot retract it. Never stamp the
    latest request onto old state. Cost: temporary protocol-1 metadata to remove
    with typed transport; delayed-prior-commit regression coverage is mandatory.

11. **Ledger line 146 — candidate cancellation and pairing deadline.** Add
    token-matched `cancelOpen`; a new validated Load cancels the older pending
    candidate before policy assessment. The pairing deadline begins only after one
    commit-pair half arrives, not across native preparation. A missing peer half
    terminates transport and best-effort disposes because native may have committed.
    Cost: temporary commands/timers; cleanup of a broken instance may end old
    playback, while normal candidate failure must preserve it.

12. **Ledger line 153 — buffering strategy mapping.** Map builtin buffering goals
    to the existing AV item, fallback candidate and Android load-control strategy at
    source install, preserving prior controls on candidate failure and avoiding
    algorithm tuning. Bounded remains rejected. Reason: public load options cannot
    be accepted and ignored. Cost: temporary native configuration plumbing.

13. **Ledger line 158 — sticky cross-origin credentials.** For the fixture path
    primary master → secondary manifest → primary key, credentials stay stripped
    after the origin crossing. Split the old master/key expectation, add a custom
    credential, and preserve AVPlayer, First Frame and ordinary-header assertions.
    Reason: restoring credentials on a returned-origin child conflicted with the
    binding source-origin rule. Cost: host authentication flows that rely on such
    restoration must adapt.

14. **Ledger line 169 — retry publication and HLS cache.** Gate retry publication
    by candidate ownership so precommit public events are dropped while committed
    byte-source retries remain visible; also correct the context-sensitive HLS cache
    under the secret boundary. Cost: precommit retries remain internal and the
    temporary publication gate adds plumbing.

15. **Ledger line 208 — no artificial view edit.** Do not edit `player_view.dart`
    merely to manufacture Task 8 compatibility evidence. Independent review found
    it consumes only retained `controller.textureId`, migrated view tests cover that
    contract, and geometry belongs to the later View plan. Cost if wrong: a hidden
    compatibility dependency will require a targeted fix; no geometry completion is
    claimed here.

16. **Ledger line 232 — private pending-command test seam.** Permit a read-only
    `@visibleForTesting` pending-command count only on private
    `_LegacyChannelPlayer`. It measures the real outstanding-registration invariant
    without GC/heap flakiness or a broader transport abstraction and adds nothing to
    SPI/app exports, factory options or production behavior. Cost if wrong: tests
    couple to a private legacy implementation and must change or be deleted when it
    is removed.

17. **Ledger line 246 — exact legacy scan fixtures.** Permit exactly three quoted
    legacy wire keys: `channel_codec_test.dart:24` (`isHardwareDecoding`),
    `channel_codec_test.dart:38` (`platformDiagnostic`), and
    `channel_player_test.dart:651` (`platformDiagnostic`). They verify unknown
    decoder evidence and redaction of unsafe native diagnostics and are not exported
    v1 symbols; the parent independently confirmed all three. Cost if wrong: a
    broad test exception could hide a future surface regression, so only these hits
    are allowed and the application negative-export test plus no-production-hit
    requirement remain mandatory.

18. **Final phase review — accepted Stop before native idle.** Conformance
    requires immediate stopped-identity rejection after accepted Stop, but awaits
    actual idle within the existing bounded case deadline. Independent native
    reply/callback delivery permits reply-before-idle; fabricating a native
    snapshot is forbidden. Missing idle must still fail, and rejection/newer
    session protection remain required. Cost: bounded delivery delay is allowed;
    a synchronous idle snapshot is not required.

19. **Final phase fix — analogous iOS authenticated rollback.** Include the
    confirmed iOS slot activation-failure path in this same fix wave: ordinary AV
    reactivation would recreate a bare asset after destroying the old controlled
    HLS loader. Preserve iOS preparation before quiescence; hold the controlled
    asset/loader only across the synchronous replacement transaction, restore on
    failure, and release after success, failed restoration, Stop or disposal.
    Ordinary deactivation must keep its prior resource-release semantics. Cost:
    iOS transaction lifetime differs from macOS asynchronous HLS re-preparation;
    later Apple consolidation must preserve both platform behaviors and their
    ownership, authentication, play-intent and session-identity tests.

20. **Task 8 R29 — deferred Apple fallback geometry.** Hardening Task 7 owns
    authoritative geometry/PAR/rotation closure before View/release acceptance.
    The two exact cases are
    `packages/yl_player/example/integration_test/ios_mkv_playback_test.dart` —
    `local H264 AAC MKV uses native fallback and renders a frame` — and
    `packages/yl_player/example/integration_test/macos_mkv_playback_test.dart` —
    `local H264 AAC MKV uses native fallback and renders a frame`. Both originally
    required `expect(controller.state.videoGeometry?.displaySize.width, 320)` and
    `expect(controller.state.videoGeometry?.displaySize.height, 180)`. Task 8's
    authorized interim expectation is
    `expect(controller.state.videoGeometry, isNull)`. Hardening Task 7 must replace
    that interim state with authoritative geometry, pixel-aspect-ratio and rotation
    publication and restore the exact 320 by 180 display-size assertions on both
    platforms before View/release; texture allocation or First Frame alone does not
    discharge this obligation.

## Android v0.2 phase self-review — 2026-09-08

This Android Task 9 record applies to reviewed implementation
`79aa0e616f010ec26c0d835c686b1b9e4c31c1dc` on `codex/player-v0.2` in the selected
`.worktrees/player-v0.2` worktree. Tasks 1–8 have independent review; Task 8 round 1
closed I1/I2/M1 with Spec Compliance and Task Quality approved. Task 9 found no
additional concrete defect requiring a source edit. This documentation self-review
is not the subsequent independent task/whole-phase review or a release approval.
All preceding Dart/Apple checkpoints remain historical evidence, unchanged.

The local audit/report root is
`.superpowers/sdd/2026-09-06-player-v2-android/` (called `audit/` below).
`audit/task-9-report.md` and `audit/task-9-logs/` retain the current checks;
`audit/task-8-report.md`, `audit/task-8-rereview-1.md` and `audit/task-8-logs/`
retain the cited runs. These are local audit artifacts; the durable tracked record
is this document. No emulator was started and no SDK, shared cache, lock, adb
server, user device, Apple implementation, or public API was changed for Task 9.

### Responsibility boundaries checked in actual source

Kotlin paths in this table are under
`packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/`;
Dart paths are under `packages/yl_player_android/lib/`. Locations refer to the
Task9 reviewed checkpoint `ba1d2f4017cc2f4f1008791c32800d701c65d69a`,
not line locations after the final repair below. Tests named here belong to the retained 239-test JVM gate;
these are coverage references, not additional executions or additive test counts.

| Boundary | Concrete implementation and supporting evidence |
| --- | --- |
| Registration/lifecycle forwarding | `YlPlayerAndroidPlugin.kt:21` creates the real `YlMedia3SessionFactory`/registry, installs only the generated factory API and forwards Activity/memory/configuration lifecycle. Detach unregisters handlers/callbacks and invokes registry cleanup. It owns no Media3 commands, active-player arbitration, source policy or reducer. `yl_player_android.dart:13` constructs `AndroidPlayer` with `PigeonAndroidFactoryTransport`, suffix-specific player transport and callback setup. `YlPlayerRegistryTest` covers actual plugin registration and teardown. |
| Registry and borrowed outputs | `YlPlayerRegistry.kt:35` / `:38` validates Create and invokes factory preparation before texture allocation; each entry has an opaque suffix and one host/session. `beginDispose` removes and invalidates transport immediately; `startCleanup` awaits session safe-close before releasing its borrowed texture. Detach keeps cleanup independent of cancelled hosts. `forEachSession` forwards lifecycle to every participant and isolates one host's failure. Registry suite: 20 tests, including held-close/rollback/lifecycle cases. |
| Sessions and publication | `YlSessionCoordinator.kt:147` owns per-player operation/session/request identity, pending Load cancellation, former/candidate engines and transaction authority. `SessionLease.commitLease` completes fallible checks before its commit version/publication boundary; candidate snapshots/retries are staged until commitment. `onEngineEvent` checks immutable identity and private/public output before reducer ingress. Stop fences identity/idle before awaiting safe release. Background cancels uncommitted candidates, preserves current intent and stages restoration snapshots until acknowledgement. Session suite: 43; session/audio suite: 17. |
| Cross-player decoder leases | `YlDecoderLeaseCoordinator.kt:45` owns registry-local scarce-resource transfer; its mutex and asynchronous stage callbacks await quiescence, activation and rollback off the main call stack. Newest scarce requests cancel competing transfers; retirement retains the lease until safe disposal. Audio-only READY evidence changes exclusivity and restores conservatively quiesced peers before commit. Nonexclusive participants are retained independently. Publication failure closes the boundary instead of retracting observed states; restoration failure reports `resource.exhausted`. Lease suite: 12. Unknown media inspection can temporarily interrupt the old scarce owner; this is a disclosed arbitration cost. |
| Media3/thread and Surface ownership | `YlMedia3Engine.kt:34` starts a dedicated worker; even waiting for its Looper occurs on `Dispatchers.Default`. `onWorker` owns Media3 calls and hands immutable, session-tagged events to main. Flutter texture borrowing stays main-owned. `YlMedia3Core.kt:121` constructs ExoPlayer with the owned Looper, preserved selector/load-control/health/stall policies, actual media attributes and per-engine focus/noisy handling disabled. `prepare:328` sets a decoder-free candidate; `initializeDecoder:420` performs actual prepare under lease activation. Public output follows readiness/evidence. Safe disposal uses real Media3 acknowledgement; timeout leaves worker/outputs quarantined and the close future pending rather than freeing a borrowed Surface. Candidate-output 8, acknowledgement 3, load-control 10, selector 14 tests; Task 8 devices also exposed and covered real callback/lifecycle defects below. |
| Source and network policy | `YlMediaSourceFactory.kt:23` builds one source-lifetime provenance graph and OkHttp-backed HTTP/HLS data path. Managed mode disables independent Media3 retries/fallback. `YlManagedHttpClient.kt:41` owns per-resource retry/redirect budgets, cancellable header deadlines, body inactivity handling and validated partial-body continuation; waits belong to loader/network workers. `YlOriginCredentialPolicy.kt:8` copies request maps and propagates sticky stripped ancestry through parsed HLS children, redirects, retries and return-origin reuse. Credentials are applied to each request, never global defaults. Shared assessment rejects unsupported managed routes and bounded buffers; hardware-required applicability can need real media inspection. Managed-network/redirect 21, retry 3, source-assessment 4 tests, plus actual encrypted HLS device requests. |
| Shared audio and lifecycle | `YlMedia3Engine.kt:184` injects `YlSharedAudioFocus.get(context)` through the real factory. `YlAudioFocusCoordinator.kt:18` ref-counts live participants, invalidates stale callbacks and retires one shared request/noisy receiver after the last participant. The actual two-registry factory test is `YlPlayerRegistryTest.kt:17`; all-session lifecycle forwarding already exists and requires no cosmetic registry/policy edit. App-managed playback never acquires shared ownership. API 26+ plugin-managed declares `setWillPauseWhenDucked(true)` and maps CAN_DUCK to transient pause/resume; API 24–25 uses a shared 0.2 volume multiplier. Resume still requires current session and current playback intent. This observable API-dependent behavior is intentional (Rulings 31/32). Driver 4, coordinator 6 and lifecycle-policy 8 tests support it. |
| Revisions, callback order and Dart pairing | `YlStateReducer.kt:7` is the sole native revision/overall-sequence author; deltas include exact prior revision, and First Frame requires current public output and is emitted once per session. `YlCallbackDispatcher.kt:38` serializes every generated callback method in one acknowledged FIFO with a five-second ACK deadline. `YlPigeonPlayerHost.kt:62` binds both directions to the same suffix. Dart `src/android_player.dart:304` starts the five-second Load counterpart deadline only after a matching successful reply or committed state, validates `loadRequestId` and exact delta ancestry, and delays final Load completion by one cancellable event turn. Newer accepted state does not discard a still-valid older-revision event. Separate public state/event streams do not promise a total observer order. Reducer 6, callback 6; retained Dart adapter/controller tests and real delayed-ACK device case cover their respective boundaries. |
| Metrics and diagnostics | `YlMetricsCollector.kt:6` owns measured immutable values, preserves unknowns and always leaves managed buffered bytes unknown. Core analytics supplies actual readiness/render/rebuffer/drop/underrun/bandwidth/retry observations; reducer only publishes the values. `YlSafeDiagnostics.kt:7` logs generated ID plus sanitized type, never exception message/cause/stack; `YlFailureMapper` produces code-owned safe public failures. Metrics 8 and failure-mapper 3 tests, including hostile exception inputs. Diagnostics are not playback metrics or a public raw platform diagnostic. |

Explicit bounded buffering remains unsupported: Media3 allocator targets do not
prove a hard managed-byte ceiling. Hardware-required video must have initialized
hardware evidence. The current API 29+ implementation binds manufacturer-reported
`hardwareAccelerated`/`softwareOnly` decoder attributes to the actual initialized
decoder; that is platform evidence, not independent physical-silicon verification.
API 24–28 codec names never constitute such evidence. Actual
audio-only applicability inspection can succeed without video/First Frame. The
public `hardwareVideoCodecs` capability contains safe normalized video MIME
families; initialized decoder names remain private evidence/state identity.

### Fresh forbidden-surface and documentation checks

All checks below actually ran at the reviewed HEAD in this worktree; no code was
changed. Commands resolve the root with
`YL_REPO_ROOT=$(git rev-parse --show-toplevel)` and `cd "$YL_REPO_ROOT"`.
Exit 1 with no output from `rg` means no matches, not a failing test.

| Command | Observed result and narrow interpretation |
| --- | --- |
| `rg -n 'EventChannel\|MethodChannel\|stackTraceToString\|Throwable\.message\|platformDiagnostic' packages/yl_player_android` | Exit 0, exactly one hit: generated `android/src/main/kotlin/dev/ylplayer/yl_player_android/pigeon/YlPlayerAndroid.g.kt:10`, the unused Pigeon `EventChannel` import. No handwritten plugin dispatch or diagnostic-leak match. No test-fixture hit for this exact pattern. |
| `rg -n 'activePlayerId\|players\.values.*deactivate\|setDefaultRequestProperties\(.*credentials' packages/yl_player_android/android/src/main` | Exit 1, zero matches. |
| `rg -n '[T]ODO\|[F]IXME\|[T]BD\|[X]XX' docs/superpowers/plans/2026-09-06-player-v2-android.md` | Exit 1, zero matches. |
| `rg -n 'YlAndroidChannel\|YlMedia3Player\|MethodChannel\|EventChannel\|invokeMethod\|onMethodCall\|when \(call.method\)\|Temporary\|temporary.*factory\|platform.unavailable' packages/yl_player_android/lib packages/yl_player_android/android/src/main` | Exit 0, exactly two hits: generated import above and `YlFailureMapper.kt:19`, the code-owned `PLATFORM_UNAVAILABLE` failure catalog entry. The catalog does not install the removed temporary factory or a fake-success backend. No old class/dispatch path remains. |
| `rg -n 'pigeon\|AndroidPlayerFactoryHostApi\|AndroidStateMessage\|AndroidLoadRequest' packages/yl_player/lib packages/yl_player_platform_interface/lib` | Exit 1, zero matches. No generated type crosses the production application/SPI boundary. |
| `git diff --check` | Exit 0; no authored whitespace error. Repeated after documentation edits and before commit. |

Table `\|` escapes are Markdown delimiters; execute them as ordinary regex `|`,
as recorded verbatim in `audit/task-9-logs/*.log` and `scans.json`.

The main playback example is `packages/yl_player/example`, distinct from
`packages/yl_player_android/example`; the required package scan alone therefore
does not inspect Ruling 36's observer. The supplementary scan of main-example
Android source and integration tests with the same forbidden pattern returned
five MethodChannel references: `android/app/src/debug/kotlin/dev/ylplayer/yl_player_example/FrameObservationProvider.kt`
at lines 18 (import), 55 (construction), 79 and 131 (typed result arguments),
and `integration_test/support/android_frame_observation.dart:5` (test consumer).
The exact additional `MethodChannel|invokeMethod|when \(call.method\)` scan of
those two files returns all seven observer hits: those five plus provider line 61
(three-method debug dispatch) and Dart line 20 (bounded `remove`). Each is a
read-only debug test observation boundary, not plugin playback transport.

Release exclusion is substantiated by Task 8 round 1
`release-exclusion-and-dependencies-pass.log`, `release-exclusion-proof.json`,
`debug-merged-AndroidManifest.xml` and `release-merged-AndroidManifest.xml`:
debug has observer/provider classes and a non-exported provider; release has
MainActivity only and no provider. Debug Media3 dependencies resolve to the
existing 1.11.0. Actual `:app:compileReleaseKotlin` and
`:app:processReleaseMainManifest` passed; no release APK or publication was
claimed. Observer installation/removal/read have three-second native and
five-second Dart deadlines, bounded observations and Activity cleanup.

Hostile fixtures are accounted for separately, not exempted by directory:
`YlFailureMapperTest.kt:14` contains a deliberately unsafe URI/query/auth/cookie/
stack-shaped string and line 47 an unsafe generated FlutterError; each is input
to assertions that public/local diagnostics contain none of it.
`test/android_codec_test.dart:443–444` injects an unsafe code and diagnostic ID,
and line 457 tests a channel error with secret prose. A targeted fixture scan
returned exactly these five lines (`hostile-fixture-exact.log`). They are not
production leak matches and were not removed from any gate. Historical evidence
text in this document quotes forbidden names to explain scans, outside the
production scan roots; it is not a source exception.

Pinned Pigeon Kotlin bytes retain exactly six known trailing-space lines at
2998, 3017, 3036, 3055, 3074 and 3093. Task 9 did not normalize them. Foundation's
only exact generated Dart source exclusion is
`packages/yl_player_android/lib/src/pigeon/yl_player_android.g.dart`; authored
schemas/adapters/tests are formatted. Its normal build and `.dart_tool` artifact
filters do not exempt handwritten source. Drift checks use repository-root
`packages/yl_player_android/...` pathspecs for both generated files, preserving
provider bytes and preventing a falsely empty comparison.

### Retained phase gates and precise reuse boundary

Ruling 7 explicitly permits docs-only reuse after real passes. No suite below was
rerun for Task 9. Fresh inspection compared `a1796e4` to `79aa0e6`: only seven
main-example debug/integration files changed, and their seven SHA256 values match
`task-8-logs/round1/verified-round1.json`. Task 9 changes this document only.
Production, generated schema/output, package tests, runners/CI and dependency
locks are unchanged; no relevant environment change was made by this task.
Foundation is the historical complete gate, supplemented by the later example
analysis/format/release compilation and affected device runs. This is scoped
reuse, not a claim of a fresh complete gate at the later checkpoint.

| Checkpoint / exact command | Actual retained result |
| --- | --- |
| Full Task 8 `a1796e4f81e0d941a2cf5110c40d55e28d8bcca2`; plugin example `android` cwd: `JAVA_TOOL_OPTIONS=-Dnet.bytebuddy.experimental=true ./gradlew :yl_player_android:testDebugUnitTest --stacktrace` (also invoked by standalone gate) | 239 tests in 27 suites, 0 failures/errors/skips, reparsed from `task-8-logs/final-jvm-xml/TEST-*.xml`. `api24-standalone-gate.log` retains actual execution. This is the qualified plugin suite; the earlier chronological Ruling 4's proposed unqualified final command was superseded by the actual rooted qualified gate and Task 9 dispatch. JDK 22 flag is command-scoped, with no dependency upgrade or disabled tests. |
| Same full checkpoint; root: `sh tool/check_foundation.sh` with Flutter/Dart `/Users/yy2021_8689/flutter/bin` on PATH | `foundation-complete.log`: 238 Dart tests, specifically 145 SPI + 32 app + 3 app example + 52 Android + 1 Android example + 2 iOS + 1 iOS example + 2 macOS. Analysis: no issues. Authored format: 94 files, 0 changes. Both iOS/macOS FFmpeg build contracts passed. Six shell contracts passed, separate from the 238 Dart count. |
| Same full checkpoint; root: `sh packages/yl_player_android/tool/check_pigeon.sh` | Exit 0, exact pinned Pigeon generation/drift passed with generated bytes unchanged. `pigeon-complete.log` is empty because success is silent; completion is separately recorded in `phase-complete.txt` and the Task 8 report. An empty log alone is not the pass assertion. |
| Same full checkpoint; root: `python3 tool/test_android_scripts.py`; `sh -n tool/check_native_android.sh tool/boot_ci_android_emulator.sh tool/run_android_integration.sh` | Six hermetic shell contracts passed (`script-contracts-final.log`), including outside-checkout rooted execution, qualified JVM, explicit same-code skip, boot identity, lifecycle choreography and fail-fast behavior. Shell syntax passed in Task 8. `ci-structure.log` separately confirms exact API 24/36 matrix/shared JVM/single drift structure; it is not remote CI execution. |
| Same full checkpoint; main app example cwd: `YL_ANDROID_DEVICE_ID=emulator-5580 YL_ANDROID_SKIP_JVM=1 sh ../../../tool/check_native_android.sh` | `api24-final-gate.log`: progressive 3, HLS 3, replacement 2, rollback 1; four files, 9 device passes. JVM was already passed at unchanged code. |
| Same full checkpoint; main app example cwd: `YL_ANDROID_DEVICE_ID=emulator-5582 YL_ANDROID_SKIP_JVM=1 sh ../../../tool/check_native_android.sh` | `api36-gate.log`: progressive 2, HLS 3, replacement 2, rollback 1; four files, 8 device passes. API 24's strict-name-only assertion is not selected or counted on API 36. |
| Reviewed Task 8 round 1 `79aa0e616f010ec26c0d835c686b1b9e4c31c1dc`; main app example cwd: `YL_ANDROID_DEVICE_ID=<serial> sh ../../../tool/run_android_integration.sh integration_test/android_progressive_playback_test.dart` and separately `integration_test/android_session_replacement_test.dart` | Only affected files rerun: API 24 progressive 3 (`round1/api24-progressive.log`) and replacement 3 (`round1/api24-private-frame-second.log`); API 36 progressive 2 (`round1/api36-progressive.log`) and replacement 3 (`round1/api36-replacement.log`). These are 11 executed tests across four separate commands. Unchanged HLS/rollback and 239 JVM evidence are reused. No new full four-file aggregate gate ran in round 1. |
| Same round 1; main app example cwd: `flutter analyze`; `dart format integration_test/android_progressive_playback_test.dart integration_test/android_session_replacement_test.dart integration_test/support/android_frame_observation.dart integration_test/support/gated_android_media_server.dart` | Analysis no issues (`round1/analyze.log`); four authored files, no formatting changes. Example Android cwd: `./gradlew :app:dependencyInsight --dependency androidx.media3 --configuration debugCompileClasspath :app:processReleaseMainManifest :app:compileReleaseKotlin -Ptarget=lib/main.dart` passed with the release/debug exclusion proof described above. |

Task 8's initial device pass did not prove the missing seek outcome or positive
private-frame boundary. Round 1 closes both: seek reaches within 250 ms of 4 s,
remains stable within 100 ms while paused for 500 ms, then advances beyond 4.5 s.
The gated valid MKV releases a 160,000-byte video prefix, observes actual decoder
initialization/private Surface rendering while Load is pending and the old
session authoritative, then holds for another 250 ms without a public frame.
After releasing the remaining bytes, exactly one public First Frame matches the
new committed session and later real public-Surface timestamp. API 24 observed
private Surface 89738383 at 642022 ms → public Surface 115551393 at 642346 ms;
API 36 observed 133856693 at 96371 ms → 136949357 at 96776 ms. Those are actual
Media3 callbacks, not withheld-all-input, synthetic state or boot-readiness proof.
The separate private-Pigeon delayed-ACK test proves real cross-method FIFO/main
command responsiveness. Strict held-input cancellation proves entry into real
HTTP-backed acquisition/inspection before initialized evidence; it does not
prove hardware decoder initialization or physical decoder pressure.

### Actual runtime and honest deferred evidence

| Device used in both checkpoints | Verified scope |
| --- | --- |
| `emulator-5580` / `codex_yl_v2_api24` | API 24, `arm64-v8a`, Google APIs image revision 29. Physical display 320×640, effective override 640×720. The earlier 1280×720 narrative was incorrect and is not reused. |
| `emulator-5582` / `codex_yl_v2_api36` | API 36, `arm64-v8a`, Android TV image revision 4, 1920×1080. This local image differs from unexecuted CI Google APIs x86_64. |

The actual example APK declares minSdk 24/targetSdk 36. Runtime/image/manifest
records are in `task-8-logs/runtime-evidence/`; latest exact serial/name/API/ABI/
display commands are in `round1/emulator-5580-runtime.txt` and
`round1/emulator-5582-runtime.txt`. Emulator executable 37.1.11 is the tool version,
not a substituted Android API. Both owned runtimes were identity-checked and
stopped with scoped `adb -s <serial> emu kill` after evidence capture;
`round1/owned-runtime-cleanup.txt` retains acknowledgements. AVD data/indexes
remain under `/private/tmp/yl-v2-android-runtime`. Task 9 did not touch them.

Actual Task 8 behavioral REDs remain distinct from setup failures: missing pinned
Media3 LoadControl callbacks failed on API 24 and focused JVM regressions; lost
restoration snapshot publication failed real lifecycle playback and the focused
held-restore test; an ordinary GET returning 416 failed a real loopback fixture
regression. Each received focused RED→GREEN and affected/full gates. Initial
HTTP override/compilation harness errors, stale VM-service discovery, debug
observer compile/start timing failures, transient adb shell 255, and the absent
AGP sourceSets reporting task are environment/test setup failures, not meaningful
production REDs. The debug observer and extra positive device tests did not
establish a production defect and did not manufacture one.

Unverified: physical Android TV decoder pressure/capacity, long playback soak,
reconnect endurance, and device-specific physical MediaCodec/hardware evidence.
Short measured emulator playback/retry cases do not establish those properties.
Remote GitHub Actions has not run; optional API 35 was not substituted. Native
release timeout can retain/quarantine resources indefinitely when Media3 supplies
no safe later acknowledgement. Debug observer reflection and the fixture's 160 KB
packet/buffering threshold require revalidation if the private schema/media changes.
Inherited CocoaPods/SPM migration, AGP/Kotlin/JDK dynamic-agent/unsafe/deprecation,
and emulator graphics/old-framework notices remain disclosed maintenance items;
logs are not warning-free. Prior Apple baseline/flakiness/physical-device limits
remain exactly as recorded above. No push, merge, release tag or publication was
performed.

### Android chronological rulings and costs (verbatim transfer)

The following 36 chronological entries preserve their original wording and
`cost if wrong` statements from `audit/rulings-index.md`. Intermediate constraints
and temporary limitations describe their original checkpoints; later rulings and
the current evidence above define the final state. In particular, temporary
factory rejection, temporary managed-audio rejection and legacy coexistence did
not survive Task 8. Ruling 4's historical unqualified-final suggestion is overridden
by the qualified plugin phase command recorded above. No chronological wording
has been rewritten to conceal those transitions.

1. Ruling: validate first Pigeon generation with staged generated files or independent repeated-generation byte/hash comparison — git diff alone ignores new untracked outputs and cannot prove no drift — cost if wrong: generation nondeterminism might be hidden until a later clean checkout; committed tracked drift checks remain mandatory. Include actual lockfile changes from dependency resolution.

2. Ruling: the typed Android Load pair deadline starts on either first successful reply or matching committed full state, using the plan's5seconds and no deadline during ordinary preparation — Task2's one-sided wording leaves state-without-reply Load hung despite an already committed source, contradicting symmetric commit pairing/lifecycle guarantees proved in Dart phase — cost if wrong: a delayed missing counterpart terminates that transport; this is bounded transport repair, not an overall network timeout.

3. Ruling: Task2 proves Dart-facing callback order with injected transport; native cross-method acknowledgement FIFO is implemented/proven in Task3 — native dispatcher does not exist at2 and intermediate gates are explicitly scoped — cost if wrong: full native proof remains pending for one task and must not be advertised early.

4. Ruling: qualify all focused Gradle runs as :yl_player_android:testDebugUnitTest — unqualified --tests can target the example app before the plugin and report no matching tests — cost if wrong: another required suite could be omitted, so full JVM phase gate remains unqualified testDebugUnitTest once after migration.

5. Ruling: remove old YlMedia3Player/YlAndroidChannel only when replacement code and affected test references compile with equivalent coverage, with final removal mandatory at Task8 — Task4 extraction and Task8 deletion instructions overlap, and globalconstraints allow scoped intermediate tests but not falsely complete migration — cost if wrong: legacy code may temporarily coexist longer; it cannot survive the Task8 forbidden-pattern/deletion gate or be used as a production fake-success fallback.

6. Ruling: preserve inherited stripped credential context through HLS child/retry/redirect/cache/return-origin media paths on both managed and platformDefault routes — immutable source-origin comparison alone can restore secrets after a cross-origin child, as actual Apple regression demonstrated — cost if wrong: routes need extra provenance plumbing or honest unsupported assessment until proven; promised managed HTTP/HLS positive fixtures must ultimately succeed.

7. Ruling: reuse already-passed JVM/foundation evidence only when code and relevant environment are unchanged; after an explicit JVM pass use YL_ANDROID_SKIP_JVM=1 for the same-code emulator runs — Task8 standalone gate intentionally defaults to JVM+device and CI already separates the shared JVM job — cost if wrong: applying skip across changed code could hide failures; record exact checkpoint and rerun after any relevant fix. Task9 records existing passing phase evidence rather than claiming a fresh run that did not happen.

8. Ruling: the Android check_pigeon script must compare generated paths relative to the directory where git diff runs, using repository-root packages/yl_player_android/... pathspecs or git -C on the package — Task1 Step4 changes to repo root but supplies lib/src and android/src paths, which silently inspect unrelated/nonexistent root paths — cost if wrong: an incorrect pathspec could make drift checks falsely green; demonstrate changed generated output is detected and restored without altering the committed schema.

9. Ruling: retain exact reproducible Pigeon 28 Kotlin output, including its six trailing-space lines, and classify those exact generated lines as known nonfunctional whitespace — task gates require deterministic generation, not upstream whitespace normalization; hand edits would violate generation ownership — cost if wrong: a future generic whitespace gate must add deterministic generation normalization or narrowly account for these lines, without masking authored defects.

10. Ruling: Task2 exhaustive enum mapping follows each actual transport direction, with bidirectional counterpart correspondence/parity tested and both conversion directions tested where both are consumed — Step1 asks every enum both ways, but the actual interface sends policy/source enums outward and state/event enums inward; unused production inverse DTO APIs add no transport guarantee — cost if wrong: a future new reverse consumer must add a converter and regression test instead of relying on speculative code today. Reviewer must still verify every real enum mapping and null/unknown case.

11. Ruling: format/check only handwritten Dart in Task2 and exclude exact generated Pigeon outputs from the authored formatter in Task8's foundation-script update, while mandatory Pigeon drift remains authoritative for generated bytes — recursive plan dart format would mutate pinned generator output and current tool/check_foundation.sh line24 would require those conflicting bytes — cost if wrong: formatter defects in generated output rely on generator validation/drift rather than handwritten formatting; list exact exclusions, do not exempt hand-authored protocol or tests, and keep codegen/analyzer gates.

12. Ruling: add private String loadRequestId to AndroidLoadRequest and AndroidLoadReply and nullable String? loadRequestId to AndroidStateMessage; allocate opaque player-local monotonic request identities, echo and validate them, and retain the committed identity on session full states (idle/no-session uses null) — state-first callbacks otherwise cannot distinguish a delayed already-committed old Load from the new pending Load, causing false new-Load pair deadlines or candidate-failure cancellation; native cancellation cannot retract an already queued valid callback — cost if wrong: private schema/generated consumers change before native implementation, requiring regeneration and mirrored Apple transport alignment, with no public SPI change. Only matching current request state/reply may start its pair deadline or fail its candidate barrier; session-scoped delta/event correlation follows the matching state. Preserve old authoritative session behavior independently. Task2 includes a narrow schema/test/regeneration expansion and concrete old-A/new-B regressions; Tasks3/4 must propagate the identity, reviewers must enforce it. Do not hand-edit generated files.

13. Ruling: add the permanent real-controller/Android adapter regression under packages/yl_player/test/android_player_controller_test.dart, with minimal local transport doubles and narrowly justified private test imports if needed — the main package already directly depends on Android, so this covers actual consumer behavior without circular dev dependencies, public test exports or a test that only imitates the controller — cost if wrong: one integration test is outside the original Task2 file list; it must stay test-only and avoid fragile imports of another package's test files. No production controller or public SPI change is authorized by this placement ruling.

14. Ruling: require monotonic retained state chronology, correlated milestone identity/deduplication and event-stream ordering, without imposing a new total observer ordering across separate asynchronous public state/event streams — public SPI exposes independent streams and native acknowledged cross-method FIFO/ordered reducer ingress is a distinct contract — cost if wrong: consumers needing a combined total observer stream would require explicit new API design; this task must not switch to synchronous streams or add reentrant commit scheduling. Final authoritative state still installs before Load returns; native FIFO is not weakened.

15. Ruling: after installing the final paired backend state, defer only Load Future completion by one owned cancellable zero-delay event turn to let queued asynchronous semantic states reach the real controller — _performLoad otherwise reads the latest backend state first and its revision watermark can discard the replayed READY; this is a concrete consumer timing requirement, refining Ruling14's scheduling restriction — cost if wrong: one event-turn latency and a small cancellation window; test newer Load/Stop/dispose during that window, retain pending/generation guards, and never await external observers, stream closure, or extra native work. Public streams stay asynchronous, and no total cross-stream observer order is promised.

16. Ruling: Task3's production factory binding returns existing typed platform.unavailable with fixed safe prose/diagnostic before allocating textures/sessions, through one named temporary session-factory binding; Task4 must replace it with the real Media3/session factory and remove the rejection — old YlMedia3Player has map events and provisional open but lacks v2 commit/session/revision/request identity, so a temporary successful bridge would fake contracts or absorb the entire subsequent engine task — cost if wrong: Android creation remains explicitly unavailable at this intermediate checkpoint (typed Dart already precedes native integration), with no full playback/phase-completion claim. Complete registry/host/FIFO ownership behavior is tested using narrow injected typed ports; preserve legacy algorithms until extraction. Do not invent resource.unavailable, which is not a public stable code.

17. Ruling: use the Global Constraints' explicitly documented-worker exception for Task4 Media3 engine application calls, with a dedicated owned Looper and immutable asynchronous results to main-owned session/reducer/lease boundaries — pinned Media31.11.0 source shows release, surface replacement and disabling foreground mode can synchronously await internal work, so wrapping main-thread calls in suspend does not satisfy the no-main-wait contract — cost if wrong: extra thread/resource ownership and cross-thread snapshot handling must be tested; Flutter registry/texture allocation/Pigeon dispatch remain main, and no synchronous main↔worker wait or unchecked release-on-timeout is allowed. Source evidence and links are in media3-threading-preflight.md; this is not measured latency/device proof.

18. Ruling: Task3 session close is an asynchronous safe-release completion boundary; registry retains borrowed texture until it completes, while detach immediately invalidates every host/handler then starts independent owned cleanup without blocking main — a synchronous close-initiation followed by immediate texture.release is unsafe for Task4's asynchronous worker release — cost if wrong: cleanup ownership must survive command cancellation/detach and be tracked until completion; test held-close responsiveness and isolated teardown failures. Completion, including a reported cleanup error, means borrowed output is safe to relinquish; Task4 must not signal that point on an unacknowledged release timeout. Retain/quarantine still-used resources rather than force-free them, and record any nonresponsive native cleanup limitation honestly.

19. Ruling: Task4 engine extraction maps SYSTEM_DEFAULT to Media3 default codec ordering and HARDWARE_PREFERRED to preference ranking with software fallback retained; name-based ranking remains preference only, and HARDWARE_REQUIRED stays explicitly unsupported until Task6 proves it — the legacy selector filters software entirely, which would violate the v2 preference/default semantics if copied unchanged — cost if wrong: selected codec may differ from legacy hardware-only behavior; add a focused actual ordering/fallback regression and retain strict proof separation rather than silently weakening required policy. This is a narrow v2 policy correction under Global Constraints, not broad decoder tuning.

20. Ruling: retain the development guard for explicit PLUGIN_MANAGED_MEDIA_PLAYBACK in Task4 real factory.prepare, rejecting policy.unsupported before registry texture/native allocation until Task7 installs genuine shared ref-counted audio ownership; default APP_MANAGED remains usable without requesting/abandoning focus or noisy registration — new factory currently enables old per-engine focus for this explicit option, which silently drops the prior durable Dart-phase Ruling9 even though a session coordinator is not the promised audio coordinator — cost if wrong: explicit convenience audio policy remains temporarily unavailable at this checkpoint; Task7 must remove the guard and prove shared ownership/actual construction flags, not leave permanent rejection. Do not implement Task7 early or claim per-engine focus satisfies the shared policy.

21. Ruling: fix Task4 background loss with retained player-level lifecycle state and cancellation/quiescence of candidates already pending at background entry, consistent with Task5 explicit lifecycle contract; test held first Load and replacement for no background autoplay, safe cancellation/quiescence, prior authoritative suspension and foreground restoration of saved intent. Loads started while backgrounded also cannot autoplay before foreground — reviewer correctly identifies lifecycle loss, but its suggested regression wording requires the pending candidate to commit, which would contradict Task5 cancellation/quiescence semantics — cost if wrong: an in-flight Load may return load.cancelled on background transition instead of later committing; retain proper old-session metadata/output safety and avoid implementing cross-player leases early. Reviewer verifies the defect is addressed under this binding resolution, not mandatory candidate commitment.

22. Ruling: split Task5 production preparation into decoder-free setup/inspection and lease-protected actual ExoPlayer.prepare/READY activation; unknown media kind may conservatively require scarce arbitration only while unknown. A proven audio-only candidate must not evict the prior video owner: observe restoration of any conservatively quiesced predecessor before/at final commit and track the audio participant as non-exclusive — current Task4 prepare initializes codecs before activate, and source descriptors have no trusted audio-only hint, so unchanged stage placement or unconditional non-exclusive assumptions would violate resource safety — cost if wrong: unknown-kind preparation can temporarily interrupt the old owner and adds inspection/restoration work; disclose that cost, preserve exact runtime snapshot, and report restoration failure honestly. Supported decoder-free metadata inspection may avoid unnecessary quiescence; same-version media3-inspector1.11 direct dependency is permitted if used, no Media3 upgrade. Metadata is not initialized hardware proof; unsupported inspection must not permanently reject promised playback routes.

23. Ruling: newest-wins arbitration applies to competing scarce decoder transfers and per-player command supersession; known nonexclusive activations on different Players must progress independently. Same-player former-engine cleanup remains part of the shared transaction authority even when a different peer owns the scarce lease — Task5 requires two nonexclusive active engines and lifecycle restoration for all participants, so a global cancellation rule for every activation contradicts those requirements — cost if wrong: concurrent nonexclusive state requires additional bookkeeping; deterministic overlap, cancellation and output ownership tests must protect it.

24. Ruling: define one irrevocable session commit/publication boundary and perform fallible validation before it. A pre-publication commit rejection restores the former active/lease state; once candidate state can have been observed, an unexpected sink/transport failure terminates through the boundary rather than rolling the reducer back to an allegedly unpublished candidate. Keep enqueue-only reducer ingress nonthrowing for recoverable transport failures and existing asynchronous callback-failure host closure — an internal checkpoint cannot retract emitted states, so rollback after partial publication contradicts authoritative Dart Load/state identity — cost if wrong: a failure after publication closes the Player instead of recovering the previous session; focused real coordinator pre-commit rejection and post-commit transport-close tests must substantiate the boundary, without speculative OOM recovery.

25. Ruling: managed retry handling includes eligible transient body I/O and configured body-inactivity failures, retaining the same original-resource retry/redirect budget and stripped credential provenance across safe reopen/resume. A source-bound DataSource may resume validated byte ranges or safely restart/discard, but must preserve already-delivered byte continuity and reject unverifiable/mismatching representation changes; no whole-resource buffering or blind concatenation — the contract covers transient transport failures and disables independent Media3 loader retries, so making all post-header failures terminal would leave the promised retry behavior incomplete — cost if wrong: safe continuation adds transport state and may end a retry when entity/offset continuity cannot be verified; actual partial-body failure/resume, request-count, cancellation and mismatch tests must prove the boundary.

26. Ruling: for pinned Media3 1.11.0 on the supported API24+ path, emit zero unapplied rotation because VideoSize documents and implements rotation as already handled by the player; do not copy Format.rotationDegrees into a second UI transform or fabricate nonzero VideoSize constructor behavior. Continue correcting PAR exactly once and preserving authoritative encoded/display dimensions — the plan says to include unapplied rotation, but pinned VideoSize deprecates that field and both constructors force it to zero, so introducing source rotation would double-rotate rendered output — cost if wrong: a future different renderer with genuinely unapplied rotation needs explicit evidence and a new mapping; current tests must prove the actual pinned contract and retain public View rotation tests separately.

27. Ruling: shared Assess/Load decision returns requiresInspection when media kind is unknown, including hardwareRequired on API24–28; this is inspection of whether the video requirement applies, not a claim that unavailable video hardware evidence is attainable. Known video without a trustworthy provider/candidate is incompatible; actual strict video is rejected before commit/public handoff and unproven video decoders remain disallowed, while proven audio-only may commit without video callbacks. Use one pure decision with optional trusted hasVideo, not divergent Load validation or format-extension audio guesses; no extra metadata inspector is required solely to force early rejection — every supported container can contain audio-only media, and the spec applies hardwareRequired to video, so blanket pre-load rejection would incorrectly reject supported audio — cost if wrong: unknown sources require real inspection and may temporarily quiesce a peer before video incompatibility is known; disclose that limitation and test both unknown-to-audio success and unknown-to-video rejection.

28. Ruling: public hardwareVideoCodecs retains normalized supported video MIME families (for example video/avc and video/hevc), derived from positively hardware/nonsoftware decoder records, deduplicated/sorted and excluding audio/encoders; exact decoder implementation names/aliases remain the private evidence identity and actual state.decoderIdentity. V2 List<String> safety/immutability tests using h264 do not redefine this existing capability meaning — prior acceptance plan explicitly documents MIME identifiers and all three legacy native backends publish/filter video MIME values, while no v2 spec replaces that semantic contract — cost if wrong: provider records need supported-type metadata and capability consumers receive families rather than implementation names; focused real provider/capability tests must separate them, with no schema change.

29. Ruling: permit a narrow Task6 shared-SPI codec validation correction plus focused Dart adapter regression so documented video MIME capabilities can cross the real native→Dart boundary. Add a codec-specific safe video/subtype grammar and keep accepted safe legacy identifiers such as h264; do not broaden generic metadata validation. Reject URLs, user-info, extra slashes, query/fragment, controls/whitespace and non-video MIME values, with existing length/safety limits — parent confirmed state_validation.dart applies a no-slash generic metadata regex to hardwareVideoCodecs, contradicting the documented/native MIME contract and causing Player creation to reject video/avc — cost if wrong: malformed capability strings could enter the model; narrow positive/hostile SPI tests and actual Android capability decode/create regression must prove the correction, reviewed with Task6 rather than an unreviewed controller fix.

30. Ruling: Task6 stages pending-candidate retry events and replays each exactly once after successful irrevocable commit and authoritative session installation; retain original index/delay/monotonic occurrence time and observed retry-event order, without rescheduling. Failed/superseded/stopped/disposed candidates discard provisional events; terminal/current-identity checks and existing acknowledged FIFO still apply. Keep Ready/FirstFrame semantics and existing no-total-cross-stream-order guarantee — retry events are session-scoped and cannot expose uncommitted identity, but dropping retries for every successful initial Load would lose the task’s actual-scheduled-retry event promise — cost if wrong: committed observers receive delayed retry history and staging retains small event records until candidate settlement; real coordinator success/discard/no-duplicate regressions must prove this, with metrics extraction still Task7.

31. Ruling: pluginManaged on API26+ declares setWillPauseWhenDucked(true) and maps CAN_DUCK to transient pause/resume; API24–25 uses the shared typed duck multiplier. Match real media attributes, resume only a live participant with current playback intent, and keep appManaged ownership calls absent. Do not use false speech metadata or declare pause merely to obtain a manual-duck callback — official AudioFocusRequest.Builder defines true as intent to pause, while default modern automatic ducking can affect all active app players without a callback, so a claimed per-participant manual duck path would contradict the platform request — cost if wrong: convenience-mode temporary interruptions pause playback on API26+ while older devices lower volume; document this observable difference and test actual driver callback mapping and stale-intent suppression on both branches.

32. Ruling: Task7 may leave YlPlayerRegistry.kt and YlLifecyclePolicy.kt unchanged when the actual shared audio owner is injected through the production session factory and existing registry lifecycle dispatch/policy already satisfies the required behavior; verify that production path and its affected regressions instead of adding meaningless file edits or a second owner merely to satisfy the plan file list — the spec requires shared ownership and all-session lifecycle delivery, while earlier tasks already implemented those dispatch boundaries — cost if wrong: an unchanged integration assumption could be missed; the real two-registry factory test and existing registry/lifecycle suites plus focused changed-contract review must substantiate it.

33. Ruling: use bounded host-side adb HOME/foreground choreography, keyed to a unique integration marker and scoped to the verified test-owned package/device, to exercise genuine native Activity background/foreground delivery. Require explicit deadlines and restoration/cleanup on failure; Dart binding lifecycle injection is not equivalent native evidence — Task8 requires actual audio-only lifecycle behavior and production-only test hooks would bypass the boundary being verified — cost if wrong: host/test synchronization can become flaky; explicit observable markers, device identity checks, bounded waits and failure logs must make failures diagnosable without changing user devices.

34. Ruling: Task8 may add a test-only direct Android package dependency and narrow private Pigeon integration consumer to hold real native callback acknowledgements, without exposing production hooks or public APIs. Keep existing deterministic JVM evidence but do not substitute it for the brief’s device integration additions. A controlled real source can hold strict acquisition before initialized decoder evidence for cancellation tests only when the pending boundary is actually established; otherwise record the observation limit — the task explicitly places delayed acknowledgement and evidence-wait cancellation in integration coverage, while private typed transport is already package-owned — cost if wrong: tests couple to the private schema and may need maintenance on regeneration; no fake provider or generic loading assertion may be mislabeled physical decoder evidence.

35. Ruling: Task8 may satisfy already-completed registration/deletion targets through verified existing state and real integration evidence rather than cosmetic edits: yl_player_android.dart already constructs the private Pigeon transports and typed Player, and YlMedia3Player plus legacy Android Dart adapter/tests were removed in earlier reviewed tasks. The remaining YlAndroidChannel/config cleanup still must occur here — the spec requires a fully typed endorsed backend and absence of old dispatch, not repeated deletion or no-op source changes — cost if wrong: earlier-state assumptions could conceal a surviving path; the parent verified the registration source, and production absence scans plus actual endorsed API24/36 tests must support completion.

36. Ruling: Task8 I2 may use an example-APK debug-source-set ContentProvider/test observation channel, locating the existing private instance through read-only reflection and adding a real Media3 AnalyticsListener on its owned worker. Record bounded decoder/frame observations with actual Surface identity, session and monotonic timestamps; use valid fixture byte gating for choreography. Exclude the observer from release source/manifest, add only the already pinned debug Media3 dependencies if needed, and bound installation/removal/Activity cleanup. Do not mutate plugin engine/lease state, delay native callbacks, synthesize frame evidence, or add a plugin/release/public API hook — device-level private rendering cannot be established by withholding every input byte or by public callbacks alone, while an isolated example test observer can observe the real existing boundary — cost if wrong: reflection couples tests to private implementation and buffered-media thresholds can be timing-sensitive; retain exact observation and dependency evidence, stale-instance checks and deterministic timeouts, and report if the real placeholder cannot render rather than silently substituting synthetic evidence.

## Android whole-phase final repair — 2026-09-08

Repair implementation checkpoint: `2c6e7f28bf12347c2c0905995a2bda942ebd8064`, based on
`ba1d2f4017cc2f4f1008791c32800d701c65d69a`. This is one batched repair of the
whole-phase review's I1–I3 and M1–M2; it does not supersede or relabel the historical
Task8/Task9 gates above. All 36 original rulings and their costs remain unchanged.
Apple implementation and remote publication remain outside this repair.

| Finding | Final behavior and coverage |
| --- | --- |
| I1 command rejection | Missing nonempty audio-track IDs and VOD live-edge commands reject without changing healthy playback state or restoration intent. Private Pigeon `seekToLiveEdge`/`selectAudioTrack` are now asynchronous Kotlin host commands. Main-owned track/timeline eligibility precedes acceptance; active worker completion and cancellation/session/operation/lease checks precede saved intent. The actual generated host waits and replies exactly once, including worker rejection and detach; real terminal engine events still fail the session. Held restoration reapplies selections accepted after its restore point, with version checks so a newer position request wins over an older live-edge choice after a held track worker. Actual public device Futures reject both unsupported commands, then valid track selection, pause, seek, play and reload succeed without a failure event. |
| I2 independent nonexclusive progress | Scarce transfers retain global serialization, newest-wins arbitration and safe-release quarantine. Proven nonexclusive activations/restores have Player-local mutex/job ownership and transaction-local stage generations, skip unrelated video retirement and never replace the scarce owner. Deterministic tests hold one audio restore while another actual coordinator resumes, and hold quarantined/retiring video ownership while audio commits. Same-Player old-engine cleanup, queued successor cancellation, late acknowledgement and detach remain owned. Player gate records disappear only after all that Player's queued jobs settle. |
| I3 native request bounds | `YlBoundaryValidation` validates real factory/registry Create before allocation; shared Assess/Load before cancellation; and runtime inputs before intent mutation. Signed32 policy limits, finite volume/speed, nonempty identities, ordered delays and signed64 positions are checked before conversion. Tests cover all six managed policy fields at min/max/one-past, width/height/bitrate including 4294967296, NaN/infinities, invalid request/track/session IDs, and unchanged pending/healthy sessions. Accepted position intervals including 1ms, 5000ms and 2147483647ms are retained exactly. Explicit bounded buffering remains unsupported without a hard-ceiling claim. |
| M1 measured live offset | The real core normalizes only TIME_UNSET to null; measured negative offsets become zero. Unknown, negative, zero and positive cases verify timeline, metrics, live-edge and lifecycle restoration consistency. |
| M2 documentation | Corrected the three Task9 checkpoint anchors to plugin21, registry35/38 and worker34. That responsibility table is explicitly historical; added source lines in this repair do not turn its old references/counts into new verification. |

The final native command, from the Android plugin example's `android` directory,
was `JAVA_TOOL_OPTIONS=-Dnet.bytebuddy.experimental=true ./gradlew
:yl_player_android:testDebugUnitTest --stacktrace`: **28 suites, 257 tests,
0 failures/errors/skips**, exit0. This qualified plugin task exercises real
production factory/coordinator/generated host/core boundaries with deterministic
worker/framework doubles where needed; it is not an empty app test task.

The earlier repair checkpoints of 255 and 256 native tests remain separately
retained. The extra final test came from a concrete self-review RED: a newer seek
during held rollback track application was overwritten by an older captured
live-edge choice. The original native input/overlap/offset REDs, corrected host
RED, held-restoration selection RED and final ordering RED are preserved; harness
SystemClock setup failure and sandbox cache-lock denial are identified separately
from product failures. Intermediate gates are not added to the final test total.

Fresh affected Dart verification: repository `flutter analyze` reports no issues;
Android adapter/schema/transport **52**, public controller **32**, main example
unit **3** tests pass (**87** total). These analyzed Dart files were unchanged by
the subsequent Kotlin-only rollback ordering fix. Pinned Pigeon generation and
repeat/drift checks pass. Kotlin generated bytes changed to implement the two
async methods; generated Dart bytes remain identical because they already expose
Futures. No generated output was hand-edited or globally reformatted, and the
six pre-existing generator-owned trailing-whitespace lines remain disclosed.

Final-source owned-device results (the earlier first device pass is separate):

| Runtime | Progressive/public rejection/lifecycle | Replacement/cancellation/private output/ACK |
| --- | --- | --- |
| API24, emulator-5580, codex_yl_v2_api24, arm64-v8a | 3 pass | 3 pass |
| API36, emulator-5582, codex_yl_v2_api36, arm64-v8a | 2 pass | 3 pass |

Each suite ran through the existing bounded `tool/run_android_integration.sh`
with the explicit verified `YL_ANDROID_DEVICE_ID`; native builds were serial.
The real API24 strict name-only decoder rejection remains API24-specific rather
than a fabricated API36 test. Both APIs exercised actual public rejection followed
by healthy playback and true Activity background/foreground delivery. Replacement
again observed real decoder rendering to distinct private/public Surfaces before
and after commitment. API24 display remains physical320x640/override640x720;
API36 remains1920x1080. Both AVDs were identity-reverified and stopped using only
their scoped `emu kill`; task-owned AVD data are preserved.

Exact commands, original exits, retained XML, final source SHA256 manifest, local
commit range, self-review and logs are in the ignored local execution report
`.superpowers/sdd/2026-09-06-player-v2-android/final-fix-report.md` and its
`final-fix-logs/` directory. Authored diff checks and the generated drift check
pass. Existing unchanged full foundation/Apple contract/HLS/multi-player device
evidence above remains historical under Ruling7; this repair does not claim those
unmodified suites were rerun as a new combined phase gate.

Limits remain: physical Android TV decoder pressure/capacity, independent
hardware/silicon evidence, long soak, reconnect endurance and remote CI are
unverified. Unknown media can temporarily interrupt a scarce owner; unacknowledged
native release may retain resources indefinitely. This repair prevents those
waits from spreading to unrelated proven nonexclusive Players. Inherited
AGP/Kotlin/JDK/ByteBuddy, emulator/framework and CocoaPods notices are retained,
not suppressed or relabeled warning-free. No shared SDK/cache/lock cleanup,
adb-server kill, user AVD change, dependency upgrade, push, merge or publication
was performed.


## Android R1 acceptance correction — 2026-09-08

The independent final re-review addressed the original five I1/I2/I3/M1/M2
findings, but reproduced a new R1 regression at checkpoint
`bba94a4b1a331d51dd422c03e1e86fb9539585c5`: an old active track worker awaited
acknowledgement, peer quiescence allowed a newer suspended track to succeed, and
the old acknowledgement then replaced that intent. Failed peer activation
restored the engine to `older` instead of `newer`. This is a narrow additional
acceptance correction authorized by Ruling37 below, beyond the normal one-wave
cap; the earlier repair and its evidence remain historical.

Track and timeline now own separate issued/successfully accepted ticket orders.
Older completion cannot overwrite a newer successful command; rejected requests
do not take accepted ownership. Quiescence captures only this lease's already
entered command workers and awaits their settlement after engine quiescence,
before activation/rollback can expose restoration. Later suspended commands do
not enter that barrier. Worker success, rejection and cancellation settle it;
existing deadline, quarantine, session/operation/lease and Stop/disposal fences
remain in force. Independent Players retain their existing progress boundaries.

Only a still-winning unapplied position request survives snapshot capture. This
also handles a seek queued behind a held track worker. Once applied, historical
seek intent is not retained across later suspensions: actual restoration tests
verify initial position100 followed by natural playback800 through background
restoration and900 through a later peer rollback, without rewinding.

Permanent production-coordinator/shared-lease regressions preserve the reviewer's
exact old-worker/new-suspended-success/old-ACK/failed-peer sequence and assert the
actual restored engine. They additionally cover live/position replacement,
independent track/timeline intent, rejected newer requests, early rollback
publication, worker rejection/cancellation, generated-host single reply and Stop.
The first behavioral RED was10 tests with3 failures; an additional pending-seek
RED observed expected100/actual0. The initial harness compile error is recorded
separately. The intermediate affected GREEN126 remains separate from the final
**7 suites /127 tests, 0 failures/errors/skips**, exit0, using:

```sh
env JAVA_TOOL_OPTIONS=-Dnet.bytebuddy.experimental=true ./gradlew :yl_player_android:testDebugUnitTest --tests '*YlCommandAcceptanceOrderTest' --tests '*YlSessionCoordinatorTest' --tests '*YlDecoderLeaseCoordinatorTest' --tests '*YlSessionAudioTest' --tests '*YlAudioFocusCoordinatorTest' --tests '*YlFinalBoundaryTest' --tests '*YlPlayerRegistryTest' --stacktrace
```

The command ran from `packages/yl_player_android/example/android`. This correction
changes only the native session coordinator, its test fixture and its focused
regressions. Schema/generated transport, Media3 engine/core, Dart and device
integration contracts are unchanged from the original repair checkpoint. Under
Ruling7, the prior full native257, Dart87 and owned-device11 remain prior
checkpoint evidence, not new R1 results; unrelated full/toolchain/device gates
were not repeated. Physical capacity, soak and remote CI limits remain unchanged.

The complete R1 probe, commands, original RED/GREEN outputs, source hashes,
self-review and exact local commit are retained in
`.superpowers/sdd/2026-09-06-player-v2-android/final-r1-report.md` and
`final-r1-logs/`. Android phase acceptance still awaits the parent's independent
R1 verification; this correction does not authorize or claim Apple-phase work.
All earlier36 ruling texts and costs remain unchanged. The explicit exception
and its cost are recorded verbatim:

37. Ruling: repair the reproduced final residual R1 before beginning the dependent Apple phase, allowing a narrowly scoped acceptance correction and focused independent verification beyond the normal one-wave final-review cap. Preserve acceptance order across active worker completion and suspended immediate commands, with independent track and timeline intent ownership; an older completion cannot replace newer successfully accepted intent, and rejected commands still cannot poison healthy playback or saved intent — the final reviewer executed a concrete current-code probe showing rollback selects older instead of newer, so this is a real load-bearing regression rather than a speculative polish item. The user has authorized all optimization and continued implementation; knowingly parking this ordinary reversible correctness repair would leave that authorized work incomplete — cost if wrong: one additional focused repair/review and its affected tests beyond the planned cap, plus per-intent ordering bookkeeping. Do not reopen the broad phase review, expand to unrelated findings, or claim physical/remote evidence; record the extra scope and exact proof in the durable ledger.

### Accepted R1 outcome

The parent independently accepted the Android R1 correction at
`f1a3fe4`. That acceptance closes the whole-phase review's original five findings
and the residual command-ordering regression described above. The final R1
checkpoint remains the focused seven-suite result: **127 JVM tests, zero
failures/errors/skips**. Under Android Ruling 7, the prior full **257 JVM**, **87
Dart**, and **11 owned-device** results remain their own earlier checkpoints; they
were not rerun or combined into a fictional R1 aggregate. The physical-device,
capacity, soak, reconnect-endurance and remote-CI limits remain open.

## Apple consolidation self-review — 2026-09-08

Apple Tasks 1–8 are accepted through `c37453f176ccf38a4f09b6f73f0b8ef14399181c`
after two scoped Task 8 repair reviews. The implementation sequence is Task 1
`cd828e6`, Task 2 `7ee4ebf`, Task 3 `b36da29`, Task 4 `04b89e0`, Task 5
`102ef09`, Task 6 `13a254a`, Task 7 `ce368c5`, Task 8 `afe0eda6`, Task 8 R1
`8074826`, and Task 8 R2 `c37453f`. This self-review changes no player algorithm,
public API, generated transport, legacy native fixture body, media, dependency,
deployment floor or artifact. It corrects one assertion-provenance description,
removes six stale Xcode navigator file references, and closes one internal
lifecycle-boundary defect found by the explicit platform-conditional audit.

### Self-review audits and bounded cleanup

| Audit | Result and interpretation |
| --- | --- |
| Swift source identity | `find ... -name '*.swift' -exec basename ... | sort | uniq -d` produced no names. Every production Swift basename has one owner in the combined package. |
| Channel surface | The requested `rg` found only historical `YlIosChannel.swift` / `YlMacosChannel.swift` path strings in `source-parity.json` and `behavioral-constants-allowlist.json`. It found no channel class, `FlutterMethodChannel`, `FlutterEventChannel` or `FlutterMethodCall` in production source. Those manifest strings preserve migration provenance and do not provide a callable channel path. |
| Plan gaps | The requested TODO/FIXME/TBD/XXX scan of the Apple consolidation plan had no matches. |
| Shared/engine platform scan | No `UIKit` or `AppKit` import exists in Shared or Engines. The audit initially found four `#if os(iOS)` sites. Three remain as explicit non-UI boundaries: `YlPlatformServices.swift:7` selects the Task-4 R11 platform identity used by immutable compatibility policies; `YlAvPlayerRecoveryPolicy.swift:87` preserves the inherited iOS-only AV media-services-reset policy that the macOS legacy implementation did not have; and `YlHlsResourceLoader.swift:4` preserves the inherited iOS `MobileCoreServices` SDK fallback because neutral `UTType` is available only from macOS 14 while the package floor is macOS 12. The fourth, Task-7-new `YlApplePlayerRegistry.swift:24`, cast the shared lifecycle to `YlIosLifecycle` only to reach an existing callback. R42 moved that callback into `YlLifecycleDriving`, removed the cast and conditional, and retained both adapters' existing storage. iOS still emits the existing real notification; macOS emits no new signal or policy. |
| Task 7 M4 provenance | `task7-host-cases.json` now says the 720-height constraint survives same-session suspend/resume. The shared body loads once, applies `setVideoConstraints`, suspends/resumes, and rechecks that same AV item. It does not load a second source or assert cross-Load constraint inheritance; each Load's options remain authoritative. Original source body, body hash, case identity and assertions are unchanged. |
| Task 8 M2 project cleanup | Only six obsolete `.mkv`/`.flv` PBX file references and their `Fixtures` group children were removed. `plutil -lint` passes. Xcodeproj inspection before and after reports byte-identical RunnerTests membership: 33 unique Swift sources and the same nine unique canonical resources (`h264_aac.flv`, `h264_aac.mkv`, `h264_mp3.flv`, `hevc_aac.flv`, `hevc_aac.mkv`, `hls_encrypted_segment0.ts`, `hls_key.bin`, `network_seek_h264_aac.mkv`, `two_audio_tracks.mkv`). The two valid HLS entries remain in the navigator group. |

### Artifact and provenance checkpoint

| Item | Durable evidence |
| --- | --- |
| Signed FFmpeg source | FFmpeg 9.0.1 archive SHA-256 `cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635`; detached signature SHA-256 `b613a00005232a1245ace7080088781ac23a916119d3e5b0d6c042368eee0177`; pinned valid signing fingerprint `FCF986EA15E6E293A5644F10B4322F04D67658D8`. The historical iOS package had no `bridge-artifact.lock`; that absence remains explicit rather than reconstructed. |
| Canonical recipe | `build_xcframework.sh` SHA-256 `6d6db93bf7bc2344b4dcfad58ad4a6872e41b6b435a3ef33f275d7548da11fde`; deployment floors iOS 15.0/macOS 12.0; network/GPL/nonfree, encoders, decoders and muxers disabled; only file protocol, Matroska/FLV demuxers and AAC/H264/HEVC/MPEG-audio parsers enabled. Eight full reproducibility rounds built 40 targets. The accepted round rebuilt all five targets twice with byte-equal canonical output. |
| Combined XCFramework | Three library entries and five architectures: iOS arm64 binary `612bc07579bf2f323e2d54cb8799b6e22455086bc21290040137bacc2dff116e`; iOS Simulator arm64+x86_64 binary `4fa84d99d67afee3a96edb03ff5c80cc1b81efca7d59d1debbc0c9747ad49279`; macOS arm64+x86_64 binary `041d85d4a1e978aef5d188e54c266fd4cf7d2e9a6506bc18503635942caf0c72`. The lock records 18 canonical file/symlink entries, UUID/signature checks, symbol allowlist and six negative mutation checks. |
| Generated transport | Pigeon 28 generated Dart SHA-256 `e42f9f49bd938d7096bf16059b620a6f91689962259eb898f69a2119dd71ac66` and Swift SHA-256 `0eedaecd35bb238864bb3592f64dc3f861b5bfff7e60b1447ea8a05d414ab9a2`. Six native APIs are async, the host has 13 methods, and the private enum spellings `protocolFailure`/`internalFailure` retain public ordinals 8/10. Generated bytes are never postprocessed; the generated Dart file has the narrow R15 formatter exception and remains guarded by deterministic generation. |
| Source/test provenance | Source classification uses the actual copy checkpoint. Divergent implementations and exact extracted declarations retain source ranges/hashes; 57 behavioral-token comparisons, eight paired declaration extractions and 13 origins passed at Task 7. The exact 20 legacy host cases retain old-to-typed mappings. Task 8 historical main-example provenance resolves immutable blobs at `ce368c55ad291b163b02157b487dbbf798a69892`; current destinations compare against current fixtures. Missing pinned history is a hard, documented prerequisite failure, never a silent skip or fetch. |

The accepted artifact is the reproducible round with valid macOS load evidence.
An earlier no-UUID intermediate was reproducible but failed the macOS load check;
it remains a rejected attempt. Parser builds emitted five
`aac_ac3_parser.c:99 bit_rate` warnings in each of the two accepted full builds
(ten observations total). With the AC-3 decoder disabled, the non-AAC branch does
not prove the warning harmless, and there is no source patch or suppression.

### Verification checkpoints and R5 reuse

| Checkpoint | Actual evidence and limit |
| --- | --- |
| Task 7 independent consumers | Four complete, valid bundles against the then-current shared host: macOS SwiftPM 213/213, macOS CocoaPods 213/213, iOS SwiftPM 251 total/248 pass/3 exact hardware skips, and iOS CocoaPods the same. Total 928 executions, 922 passes, 6 skips. This is pre-Task-8 historical consumer evidence and is not relabeled as final Task-8 consumer evidence. |
| Task 8 main iOS | `check_native_ios.sh` passed at the final native/fixture checkpoint: 251 total, 248 pass, 3 exact hardware skips, 0 fail; 11 Flutter integration cases passed. Simulator: iPhone 17 `431A3ACD-A229-4F82-AC46-9B9481AC0ADE`, iOS 26.5 build 23F77, arm64. Positive AV/HLS publication ran; decoder-unavailable branches are not positive fallback-hardware proof. |
| Task 8 main macOS | Native result bundle passed 213/213, zero skip/fail on macOS 26.6.2 build 25G83 arm64. Integration evidence is an explicit composite: HLS 1 + local MKV 2 + network MKV 3 + HTTP-FLV 1 + HLS headers 3 = 10 passes. An earlier complete native attempt had one authenticated-HLS rollback failure; its focused and later complete reruns passed, but the cause remains unproved. |
| macOS release product | Final build-only gate proved the app executable, Flutter, Dart and FFmpeg are arm64+x86_64; the Apple plugin compiled/linked for both architectures; minimum macOS is 12; the Release app has network-server entitlement. A three-second owned Rosetta x86_64 app liveness smoke passed. This is architecture/link/startup evidence, not physical Intel decoded playback or endurance. |
| Foundation | The final full foundation checkpoint before the last Task-8 provenance-only verifier correction passed 313 Dart tests (145 SPI + 47 player + 3 example + 52 Android + 1 Android example + 65 Apple), 18 Python guards (6+3+3+2+3+1), analysis with zero issues, and format on 108 files with zero changes. After the Python/JSON correction, only the affected migration verifier 4/4 and complete fixture verifier were rerun and passed. No single post-correction 313-test aggregate is claimed. |
| Wrapper repairs | After the full Task-8 checkpoint, R1/R2 changed only the display-awake wrapper/tests and R29 documentation. The current real-process wrapper suite passed 7/7 in 3.039 seconds, including zero/nonzero exit, child SIGTERM/SIGKILL, wrapper SIGTERM/SIGINT/SIGHUP, descendant cleanup and exact caffeinate argv. No owned processes remained. Native/media/artifact/foundation results were not rerun because their inputs were unchanged. |
| R42 focused native proof | The new shared-protocol memory-warning case failed before the fix because the active host stayed active/loading, then passed after the two-line internal boundary repair. Fresh worktree-local xcresults pass 1/1 on macOS 26.6.2 and 2/2 on the iPhone 17 iOS 26.5 simulator. The iOS pair includes the new protocol-generic case and the pre-existing actual `UIApplication.didReceiveMemoryWarningNotification` regression; both have zero fail/skip. These focused runs compile the affected native boundary. They do not turn the pre-R42 full 251/213 matrices into current full runs. |
| This self-review | The source/channel/conditional/plan scans above are fresh. The changed project received fresh `plutil`, Xcodeproj target-membership and exact obsolete-ID checks; the changed fixture/verifier declarations received focused migration and complete fixture verification. Current declarations are 252 iOS and 214 macOS, with one new shared R42 case. The last full native inventories remain the pre-R42 251/213 checkpoints above. Media, Dart/foundation, Pigeon and binary-artifact inputs are unchanged, so their accepted checkpoints remain reused under R5 and are not presented as new runs. The release product/Rosetta checkpoint also remains explicitly pre-R42: the focused builds compile the current shared plugin on both platforms but do not constitute a fresh universal Release product or Rosetta run. |

The first focused macOS command used stale ignored generated SwiftPM aggregator
floors (`macos/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift`
at macOS 10.15 and its iOS counterpart at iOS 13) and stopped before the intended
test. Task 9 aligned these ignored workspace outputs to the tracked package and
example floors, macOS 12 and iOS 15. Later, the first iOS focused command stopped
before XCTest because ignored `ios/Flutter/Generated.xcconfig` named a deleted
temporary Flutter test listener. `flutter build ios --config-only --simulator
--no-pub` regenerated that configuration; the generated aggregator still declared
iOS 15. No canonical Pigeon output, package source, artifact lock or deployment
declaration was hand-edited, and neither setup failure is accepted test evidence.

The macOS native and integration commands use the repository-owned wrapper, which
starts exactly `/usr/bin/caffeinate -d -i -u -t 240 -w <owned-command-pid>` and
releases that owned assertion in handled completion/signal paths. It changes no
global power setting. SIGKILL delivered to the wrapper itself cannot run cleanup,
and a process stuck in an uninterruptible OS state can outlive bounded cleanup.
The passing evidence does not prove playback while the display is asleep or the
app is backgrounded.

### Warning inventory and outstanding evidence

The accepted output is not warning-free. Ownership is recorded so later work does
not convert incremental absence into a false cleanup claim.

| Warning or verification gap | Classification and owner |
| --- | --- |
| `YlApplePlayerHost` Dispose dispatch captures non-Sendable `self` in a Sendable closure | New Task 7 host debt, observed in initial host/iOS CocoaPods output, not inherited. Hardening concurrency/Swift 6 readiness owns a supported actor/Sendable isolation boundary. |
| AnyHashable/Swift-6 incompatibility, raw-pointer `Optional<AnyObject>` conversion, `Any??` coercions, deprecated UTType calls, AppIntents metadata extraction, unused captures and weak variables | Mixed inherited/copied compiler and toolchain debt. Final broad review and hardening own source-by-source triage; no warning suppression or global SDK change occurred. Task 8 specifically observed never-mutated weak variables in `YlOpenCoordinatorTests` and `YlOpenedMediaTests`; their imports/copies changed, their behavior did not. |
| macOS test-only XCTest support built for macOS 14 while the test target declares 12 | Test-toolchain warning. The release plugin still declares macOS 12, but execution on macOS 26.6.2 does not prove XCTest or product runtime on macOS 12. Release device/OS matrix owns closure. |
| Flutter nonstandard CocoaPods notice and three `Invalid key/value pair: DART_DEFINES=...` diagnostics | The Podfile notice is inherited. The exact emitter and newness of the three DART_DEFINES diagnostics were not established by the focused inspection, so they remain unknown-origin build-tooling debt for final broad/release triage. They are not assumed harmless and no global CocoaPods/Flutter repair was attempted. |
| Stale Debug products reported beneath worktree build output and old global DerivedData paths, plus always-run build-phase notes and package-update notices | Build-output/tooling notices. The accepted focused commands explicitly select worktree-local DerivedData, but Xcode still names stale external products while planning the build. These messages do not establish artifact hash drift or playback failure. Build hygiene/release review owns triage; no global cache deletion or repair was performed. |
| Current-target inventory guard | `verify_current_targets` proves fixture bytes and counts current source declarations (252 iOS, 214 macOS); it does not prove each identity executed from PBX membership/xcresult or enforce the exact runtime skip allowlist. The pre-R42 accepted full xcresults prove their earlier 251/213 actual inventories, while the fresh R42 xcresults prove only the affected 2/1 cases. Hardening Task 8 and the final release gate own a durable case-identity/count/skip guard. This self-review does not overstate the file-count check or implement a new gate without concrete design. |
| Internal typed boundary | Pigeon transport, state/events and host validation are typed, but the closed internal `YlPlaybackBackend.command(name:arguments:)` and source/preparation maps remain temporarily behind validated conversions. Hardening Tasks 1 and 2 own their removal; final v0.2 cannot claim all dynamic internals removed before closure. |
| Strict policies | Managed network, bounded buffer and effective hardware-required remain strict `policy.unsupported` during consolidation. Hardening Tasks 2–5 own full support/evidence; app-managed audio remains the usable default. |
| Public geometry | Both `local H264 AAC MKV uses native fallback and renders a frame` cases currently assert `videoGeometry == null`. Hardening Task 7 must restore the exact original positive `displaySize.width == 320` and `displaySize.height == 180` assertions and add authoritative clean-aperture/PAR/unapplied-rotation proof before View/release acceptance. Native dimensions/buffer publication do not close this public metadata regression. |

Still unproved: physical iOS VideoToolbox fallback playback; runtime on the iOS
15/macOS 12 deployment floors; physical Intel Mac decode/playback; Instruments and
memgraph evidence; long endurance, reconnect and repeated replacement soak; and
remote CI. The three iOS skips are exactly the transferred failed-replacement
reactivation case, network-FLV reconnect case and rejected-quality-constraint
case, each conditional only on unavailable hardware. Old Apple package deletion,
historical-verifier reconciliation and final View cleanup remain later-plan work.

### Apple chronological rulings and accepted costs

These 42 entries preserve the phase order. Later entries refine earlier ones; an
intermediate cost remains historical even when later work closed the immediate
gap.

| Ruling | Durable decision | Accepted cost or risk if wrong |
| --- | --- | --- |
| 1 | Classify identical/divergent Swift from a fresh copy-checkpoint manifest, never the plan's candidate list. | Extra reconciliation may be required; no reviewed fix may be lost or mislabeled identical. |
| 2 | Before endorsement, run new-module native tests in four independent consumers; switch the main example only in Task 8. | Temporary duplicate fixture wiring requires maintenance and all four real linkages. |
| 3 | Apple Load uses the symmetric five-second reply/matching-committed-state pair deadline; ordinary preparation has no overall deadline. | A missing counterpart after commitment terminates transport. |
| 4 | First Pigeon verification includes staged bytes or independent repeat generation because Git ignores untracked output. | Hidden nondeterminism could appear only in a clean checkout. |
| 5 | Reuse a passed gate only with unchanged relevant code/environment; refresh every affected/new-source gate. | A false equivalence can hide regression, so each reuse keeps its checkpoint and scope. |
| 6 | Add private monotonic `loadRequestId` correlation to request/reply/state and accept only the matching pending pair. | Schema, Dart and native adapters/tests move together; public API remains unchanged. |
| 7 | Record the missing legacy iOS artifact lock honestly; accept the final combined lock only after clean five-target reproducible builds. | Historical iOS binary provenance stays limited and requires extra measured verification. |
| 8 | Copy licenses verbatim while adapting only shared-package packaging prose; Task 2 supplies the real combined rebuild path. | Incorrect prose can omit distribution/rebuild obligations. |
| 9 | Task 3 extracts only byte-identical declarations; Task 4 migrates/tests all divergent engine suites. | Temporary dependency extraction and a named coverage gap persist until four complete Task-4 matrices. |
| 10 | Transfer exactly 20 host/channel/plugin methods to genuine typed-host Task-7 counterparts with old-to-new assertion mapping. | Temporary host coverage needs explicit mapping; obsolete spelling cannot justify assertion loss. |
| 11 | Preserve real iOS/macOS differences as immutable compatibility policies in one shared implementation. | Bounded policy branches and later hardening migration tests remain necessary. |
| 12 | Match Android async semantics for seek-to-live-edge and audio-track selection as well as load/play/stop/dispose. | Two more completion/order paths require settlement tests without broadening unrelated commands. |
| 13 | Retire only the comments-only iOS `testExample`, retaining source/body/hash/reason. | One fewer execution requires visible count reconciliation. |
| 14 | Rename only private generated enum members to `protocolFailure`/`internalFailure`, preserving ordinals/public mappings. | Two explicit adapter mappings remain maintenance points. |
| 15 | Exclude only generated Apple Pigeon Dart from formatter mutation; deterministic generation/drift remains authoritative. | Generic format gates need one narrow exception. |
| 16 | Keep validated typed transport while temporarily retaining closed internal backend command/source maps; close them in hardening Tasks 1/2. | Final v0.2 cannot claim complete dynamic-internal removal yet. |
| 17 | Keep persistent AVPlayer rollback and bind every async callback to immutable per-open activity/session authority. | Observer/token lifetime adds concurrency bookkeeping and focused stale-callback tests. |
| 18 | Preserve credential names separately, apply at source origin, strip on origin change and never restore within that request intent. | Reader/retry/reopen provenance plumbing grows; Hardening Task 3 still owns the full managed guarantee. |
| 19 | Replace legacy `cancelOpen` characterization with supported typed Load supersession, not Stop/new API, preserving both case identities and invariants. | No one-call syntax remains, so deterministic multi-step held-work tests are required. |
| 20 | Delete only source/build directories in six superseded Task-2 roots and one failed diagnostics subtree after receipts/hashes. | Some rejected-build object forensics now requires rebuilding; retained raw/config/artifact evidence remains. |
| 21 | Preserve the exact transferred iOS hardware skip only for initial `decoder.video_hardware_unavailable`; macOS runs it fully. | Simulator evidence cannot prove that real fallback restoration path. |
| 22 | Rebuild/reprepare macOS fallback after decoder-disposing quiescence; retain iOS's decoder-retaining path. | macOS restoration can add I/O, latency and resource turnover. |
| 23 | Emit nil public geometry when only width/height are known; Hardening Task 7 supplies authoritative geometry. | Consolidation temporarily loses public size/aspect metadata. |
| 24 | Carry R13's sole empty-template retirement through Task 8 with provenance and all real tests intact. | The main iOS count is visibly one below the old no-behavior inventory. |
| 25 | Allow a default-off precommit reconciliation hook to reapply only newer accepted independent intent before atomic commit. | Rapid intent changes can add same-candidate seeks and restore latency. |
| 26 | Include failed post-quiescence local rollback in the accepted-intent repair, with only a narrow default-preserving seam if needed. | Additional seam/coverage and affected reruns are required. |
| 27 | Test the retained-iOS transaction branch on actual macOS media with a narrow compatibility override while keeping production defaults. | Cross-policy proof cannot replace actual iOS hardware execution. |
| 28 | Remove only one failed macOS diagnostics subtree and allow strict `YL_APPLE_TEST_DIAGNOSTICS=never` for owned complete gates. | Bulk system diagnostics are unavailable for those attempts; normal xcresult/raw/case/product proof remains. |
| 29 | Keep both local-MKV tests but assert interim nil geometry and hardware decoder only where positive VT evidence exists; track the exact 320x180 closure. | Endorsement lacks old public size metadata until Hardening Task 7. |
| 30 | Resolve historical main-example provenance from pinned `ce368c5`; CI fetches exactly that object only for the historical verifier. | Shallow/archive consumers must supply the object or fail explicitly. |
| 31 | Recover iOS-gate space by deleting only ignored `build/app/intermediates` after retained-output hashes. | Future Android intermediate work must regenerate; APK/output proof stays retained. |
| 32 | Recover macOS/foundation space by deleting only ignored `.dart_tool/flutter_build` after product hashes. | Flutter intermediates must regenerate; products/evidence remain. |
| 33 | Put native DerivedData under the worktree and refresh affected xcodebuild gates; reuse unaffected integrations only by exact equivalence. | More worktree storage/build work; a bad reuse claim can hide regression. |
| 34 | Disable parallel XCTest for main Apple native gates, preserving cases/timeouts. | Suites run longer and do not themselves stress multi-runner contention. |
| 35 | Wrap macOS native tests in the owned 240-second display-awake process wrapper with exact signal/status cleanup. | Host stays awake during the bounded command; evidence remains display-state qualified. |
| 36 | Apply the same wrapper to each owned macOS Flutter integration and report the gate as explicit checkpoint composite. | Same bounded awake cost; it proves neither asleep/background nor endurance behavior. |
| 37 | Await Ready and exact same-session two-track state in paired local-MKV tests, preserving exact track assertions. | Valid metadata may arrive up to five seconds after commit; missing/wrong-session data still fails. |
| 38 | Await the exact requested selected track in the same session after successful async selection. | The test permits documented callback projection delay, never wrong/unselected state. |
| 39 | Reuse `YlFallbackSeekPolicy` in typed-host preflight to preserve exact `network.range_not_supported` before mutation. | A broad alias would corrupt other errors; the narrow host change requires fresh native proof. |
| 40 | Await same-session Ready before sequential-HTTP-200 seekability/position/engine assertions and rejected seek. | The case no longer claims ready-only metadata at Load commit or pre-Ready command behavior. |
| 41 | Move paired HTTP-FLV engine/live/seekable/hardware assertions after Play and same-session Ready. | Readiness-dependent properties are no longer asserted at commit; real playback/reconnect remains mandatory. |
| 42 | Promote the existing memory-warning callback into `YlLifecycleDriving` and register it through that protocol, removing the shared registry's concrete iOS cast and platform conditional. Keep both adapters' existing callback storage, the real iOS notification, and macOS's absence of a memory-warning signal. | One internal protocol requirement and one shared regression case are added to both native targets. Focused macOS generic-lifecycle and iOS generic-plus-real-notification proof is required; it cannot replace the pre-R42 full inventories or prove a macOS notification policy that does not exist. |

Rejected and failed evidence remains classified: the reproducible no-UUID artifact
failed macOS load; Task 7's first macOS CocoaPods archive printed 213 passing
tests but ended with archive exit -5 and was rerun to a valid bundle; Task 8's
parallel/serial/unsigned/blank-host macOS attempts all failed the same four display
cases; one native HLS rollback attempt and one unwrapped HLS First Frame attempt
failed with no proved root cause; a narrowed-PATH product attempt masked an inner
failure through `tee`, and the next immutable download ended with curl 18 before
the final verified-input pass. None is promoted to accepted evidence.
