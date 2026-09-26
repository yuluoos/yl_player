# Apple DASH admission diagnostics

Baseline: `685a22a` (the committed fixed-selection stage). This stage implements
one bounded part of REQ-13 and REG-DIAG: explicit, safe reasons for five existing
Apple DASH admission failures. It does not expand DASH/DRM support, change
PD-02/03, introduce a commercial SDK or change wire schema 4.

The parser now produces a package-owned typed reason for invalid UTF-8/XML,
dynamic MPD, ContentProtection, SegmentBase and input over 2 MiB. The compiler
preserves only that typed reason; arbitrary callback NativePlayerError codes
still collapse to the existing unsupported error. Namespace/policy aborts stay
distinct from malformed XML. Native safe publication and Dart mapping use fixed
messages, never source text. The existing loader's
`resource.dash_manifest_too_large` now survives the native allowlist instead of
becoming `platform.failure`. Other resource limits remain generic.

The five public codes and migration guidance are in
[platform support](../../platform-support.md#apple-dash-admission-diagnostics).
All five remain nonretryable; scope, category and diagnostic ID survive the
existing bridge. If multiple conditions apply, the first detected gate wins.
The errors do not claim that a license request was made or failed.

## Verification record

All native commands use `xcodebuild test -quiet -parallel-testing-enabled NO
-collect-test-diagnostics never`, the example Runner workspace/scheme, and
`build/native-{macos,ios}-tests` derived data. macOS destination is
`platform=macOS,arch=arm64`; iOS is iOS 27 Simulator
`A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6`.

- Native RED selects the two new compiler methods. 1 passed, 1 failed on
  `container.unsupported` instead of `container.dash_manifest_invalid`, before
  implementation. Bundle: `/private/tmp/yl-dash-diag-native-red.xcresult`.
- Native macOS selects `RunnerTests/YlDashHlsCompilerTests` and
  `RunnerTests/YlDashResourceLoaderTests`: **102/102 passed**, zero skips/failures.
  Bundle/log: `/private/tmp/yl-dash-diag-macos.{xcresult,log}`. Actual case trees
  were compared against all selected canonical method identities.
- Native iOS selects the same two classes: **102/102 passed**, zero skips/failures.
  Bundle/log: `/private/tmp/yl-dash-diag-ios.{xcresult,log}`; actual identities verified.
- Dart RED: five new known-code cases failed on generic guidance; 14 existing
  cases passed. Log: `/private/tmp/yl-dash-diag-dart-red.log`.
- Dart regression: **233/233 passed** using
  `flutter test packages/yl_player_apple/test packages/yl_player/test/apple_player_controller_test.dart packages/yl_player_platform_interface/test`.
  Log: `/private/tmp/yl-dash-diag-dart.log`.

Native assertions cover direct compiler classifications, no media emission,
invalid UTF-8, foreign namespaces, unsupported nodes/unknown type/wrong root/DTD,
forged callback codes, declared and streamed byte limits, and accepted-session
rollback. Current native inventory is 603 iOS / 519 macOS after adding two
methods; these inventory totals are not the executed test count. Historical
inventories and hardware-skip contracts are unchanged.

The public test exercises each of the five failures with private markers in
URI/query/header/XML, checks safe code/category/scope/retryability/diagnostic ID,
verifies only the MPD was requested, then requires first frame and advancing
playback from a valid source. The existing delayed malformed-candidate test
checks that accepted playback continues before and after rejection. Platform results are recorded below.

## Failures, warnings and evidence limits

The first static-analysis run found an unnecessary non-null assertion in the new
public test; it was removed before device execution. The final targeted analyze
reported `No issues found!` (`/private/tmp/yl-dash-diag-analyze-final.log`).
Native macOS/iOS logs contain 150/58 textual `warning:` occurrences, including
existing compiler diagnostics, derived-data stale-file warnings and iOS XCTest
deployment-link warnings. Both xcresult summaries record no runtime warnings.
These warnings are not counted as failed or skipped assertions.

The initial macOS combined-file public invocation passed all five new diagnostic
and recovery cases, then failed to launch the second file's app/debug connection
before its assertions ran. That command exited 1; it is not reported as a clean
six-case run. Only the unexecuted rollback case was retried separately. No
production fix or test weakening was made for the launch failure.

This scope covers the tested macOS and iOS Simulator environments. It does not
prove minimum-OS/physical-device behavior, arbitrary MPD interoperability or
DRM licensing. Android diagnostics are unchanged. Existing unsupported
structures and other budgets retain their generic classification.

## Public execution commands and results

From `packages/yl_player/example`, commands use
`python3 <repo>/tool/run_with_display_awake.py <flutter>/bin/flutter test`
with `--no-pub --reporter expanded`. `<repo>` is the repository root and
`<flutter>` is `/Users/yy2021_8689/flutter`.

- macOS initial: `integration_test/apple_dash_diagnostics_test.dart integration_test/apple_dash_playback_test.dart --name 'DASH admission|malformed candidate' -d macos`.
  Log `/private/tmp/yl-dash-diag-public-macos.log`: five new cases passed; the
  second test app could not establish its debug connection. Overall exit 1.
- macOS scoped retry: `integration_test/apple_dash_playback_test.dart --plain-name 'malformed candidate preserves old session while pending and after rejection' -d macos`.
  Log `/private/tmp/yl-dash-diag-rollback-macos.log`: **1/1 passed**, including
  observed old-session progress and no session failure. The log retains
  `Failed to foreground app; open returned 1` despite successful assertions.

The macOS evidence is five diagnostic cases plus one separate rollback case,
not a single clean six-case invocation.

- iOS diagnostic: `integration_test/apple_dash_diagnostics_test.dart -d A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6`.
  Log `/private/tmp/yl-dash-diag-public-ios.log`: **5/5 passed**, with the
  same root-only rejection and subsequent first-frame/progress checks.

- iOS rollback: `integration_test/apple_dash_playback_test.dart --plain-name 'malformed candidate preserves old session while pending and after rejection' -d A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6`.
  Log `/private/tmp/yl-dash-diag-rollback-ios.log`: **1/1 passed**.

All tested implementation sources remained unchanged between the final native
and public runs; the retained hash inventory confirms this. Four generated
Flutter targets are restored to `lib/main.dart`. The stage remains uncommitted
and no changes have been pushed.

## Final review and closure

Independent review approved both specification compliance and code quality with
no actionable Critical, Important or Minor findings. It independently checked
all 20 stage hashes, 15 native/Dart hashes and both actual 102-case trees, plus
Dart/analyze/public logs. No production fix wave or repeated passing suite was
required. The simulator is shut down and four Flutter targets restored.

The reviewer left four boundaries for explicit disposition, in this order:

1. Minimum-OS and physical-iOS behavior remains unverified; the cost is residual
   device/OS compatibility uncertainty. No claim is extended beyond measured environments.
2. Broader MPD interoperability, DASH and DRM licensing remain separate work;
   those sources can still be unsupported despite clearer diagnostics.
3. The macOS second-file debug-connection startup failure's root cause remains
   unknown. The separate rollback run passed, so no product workaround was
   introduced; the infrastructure issue can recur in later runs.
4. PD-02/03 and the remaining REQ-13 cases remain open. This stage does not
   choose HDR/subtitle-failure policy or claim all error coverage; those product
   decisions and implementations still need their own work.

There are no deferred review minors. Existing build/foreground warnings and the
failed startup attempt remain disclosed above. Prior stage commit is `685a22a`;
this diagnostics stage is complete, uncommitted and unpushed.
