# Player v0.2 Dart API and SPI migration evidence

Status: the Dart API and SPI phase is accepted at implementation commit
`fcd2056d3274afcd1cfe765fb5e1a260b64bf90b`. This document records the phase
checkpoint, not full v0.2 release approval. The application API and handwritten
SPI now expose the v0.2 model. The temporary channel compatibility adapter is
isolated behind `yl_player_legacy_transport.dart`, outside the application barrel.

## Workspace and preserved baseline

Development branch: `codex/player-v0.2`, based on `5974434`.

Current reviewed implementation: atomic cutover `72bc790`, boundary fixes
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

## Current phase acceptance

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

### Latest gate evidence retained from Tasks 6–8

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

This is the durable extraction of every ruling in `progress.md` at Task 9. Ledger
line references preserve chronology; each entry records its reason and the cost or
risk accepted if the ruling is wrong.

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
