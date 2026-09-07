# Player v0.2 migration evidence

Status: implementation in progress. This document records completed checkpoints,
not release approval. The public API remains v0.1 while additive v2 types are
introduced behind `yl_player_platform_interface/lib/src/v2.dart`.

## Workspace and preserved baseline

Development branch: `codex/player-v0.2`, based on `5974434`.

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
| 4 — SPI and conformance | In progress | Additive SPI/testing entry; existing production SPI remains in use. |
| 5 — native Stop | Pending | Native cancellation, reset and texture-identity checks required. |
| 6–8 — atomic API cutover | Pending | Adapter, controller, view, registrations, examples and tests must pass together. |
| 9 — phase acceptance | Pending | Full foundation and native gates have not been run against the completed v2 phase. |

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
