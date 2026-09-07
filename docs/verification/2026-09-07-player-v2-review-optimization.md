# Player v0.2 review optimization verification

Date: 2026-09-07

This change applies the confirmed findings from both reviews to the five v0.2
implementation plans and repairs the existing macOS baseline. It does not
implement the planned v0.2 API, typed transports, or Apple package migration.
The starting checkout was clean at `49f59cf`; the former eleven uncommitted
files are preserved by `1b239e0` and `49f59cf`. The review fixes were prepared as
a local changeset; no publishing, tagging, or pushing was performed.

## Existing implementation fixes

| Finding | Applied change | Regression evidence |
|---|---|---|
| Unbudgeted video waiting in dispatch closures | Reserve compressed bytes before sample creation/submission; queued and executing work share the byte ceiling; at most 256 submissions and the existing 16 active decoder frames | Pending byte/count limits, cancellation payload release, queue ordering, and a negative-control probe |
| Cancelled samples retained until queued closures run | Removable pending storage; invalidate/stop producers, clear pending work, join the running submission before decoder teardown | Cancellation releases retained samples; stale generation cannot enter decoding or corrupt a replacement reservation |
| Automatic audio restart overrides pause | Serialize converter/output operations and verify current intent/generation before restarting | Reentrant and concurrent pause regressions; old behavior failed before the fix |
| Refresh cadence follows the wrong screen | Pass registrar view to both engines; follow its owning window and screen changes; preserve pause | Window/screen change regression failed before the fix and passed afterward |
| Large mixed fallback test file | Split audio, video, and presentation tests from fallback policies and update Xcode sources | All 71 RunnerTests discovered and passed |
| Fixed-delay playback-rate assertions | Measure position against Stopwatch elapsed time using state events and bounded waits | Both 3x-to-1x cycles pass in real network MKV integration |
| Marker test does not prove continued delivery | Send and assert a subsequent full state and delta after fallbackActivated | All 11 channel-player tests pass |

## Plan corrections

- Resolve command roots inside the selected checkout/worktree, removing
  machine-specific return paths and stale dirty-baseline instructions.
- Introduce coherent migration versions early. Add v2 models/SPI behind an
  internal barrel, add native Stop, and make adapter/controller/registration/
  example switching one buildable API cutover. Delete old Apple workspace
  packages before the legacy transport they import.
- Define Load completion as the commit reply plus accepted corresponding full
  state. Cache Ready/First Frame without treating initial buffering or private
  candidate output as milestones. Fence stale sessions and dispose late work.
- Serialize acknowledged typed callbacks; distinguish event deduplication from
  state revisions. Specify schema types, nullability, units, and numeric ranges.
- Make Android decoder activation/restoration cancellable asynchronous stages.
  Reject name-only hardware claims; cover all lifecycle participants and use one
  audio-focus owner.
- Define managed header/read deadlines, request-wide retry/redirect budgets,
  Retry-After handling, and permanent credential stripping. No overall request
  timeout guarantee is invented from the existing fields.
- Remove Apple's temporary Dart strict-policy rejection when native mechanisms
  become available. Require supported Matroska/FLV success fixtures and explicitly
  reject unsupported managed HLS/MP4/MOV/AVI/MPEG routes. Apply credential safety
  even under platformDefault; preserve the iOS 15 VideoToolbox key path.
- Use process-wide Apple audio leases, retained-payload budget lifetimes, and
  independent Flutter consumers providing genuine CocoaPods/SwiftPM linkage.
  Artifact provenance includes clean rebuild evidence, not checksum edits alone.
- Define extensible typed requirement/limitation IDs, a single implementation
  metadata authority, precise geometry values, and bounded conformance cases
  with cleanup and deterministic candidate controls.
- Apply PAR once before rotation/BoxFit. Generate negative compilation fixtures
  outside the analyzed source tree. Separate PR quick checks from complete
  nightly/release evidence and specify Android API 24/36 integration coverage.
- Synchronize the architecture specification and domain glossary with these
  decisions. All five plans were cross-reviewed for boundary consistency.

## Verification performed

Commands below start at the active repository root unless noted otherwise.

| Check | Result |
|---|---|
| `flutter --suppress-analytics analyze` | Passed; no issues |
| `flutter --suppress-analytics test test/channel_player_test.dart` in platform-interface package | 11 passed |
| macOS `xcodebuild test`, RunnerTests | 71 passed, 0 failed, 0 skipped |
| `macos_network_mkv_playback_test.dart -d macos` | 3 passed, including repeated playback-rate transitions |
| `macos_mkv_playback_test.dart -d macos` | 2 passed, including audio-track switching |
| `macos_http_flv_playback_test.dart -d macos` | 1 passed, including socket-drop reconnect |
| `macos_hls_headers_playback_test.dart -d macos` | 1 passed |
| `sh tool/check_native_macos.sh --build-only` | FFmpeg artifact contract, universal release build, arm64/x86_64 plugin compile/link, macOS 12 floor, signed loopback entitlement, and Rosetta smoke passed |
| Dart format check on the two changed Dart tests | Passed, no formatting changes |
| Five plan shell-fence checks | 131 Bash blocks passed `bash -n`; fences balanced; no original checkout path remains |
| `git diff --check` | Passed |

The native suite used:

```sh
xcodebuild test -quiet \
  -workspace packages/yl_player/example/macos/Runner.xcworkspace \
  -scheme Runner -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/yl-player-baseline-review-derived \
  -only-testing:RunnerTests FLUTTER_TARGET=lib/main.dart
```

The explicit Flutter target avoids an existing generated configuration that
referenced an expired test listener. Build output still contains existing
SwiftPM/CocoaPods migration notices and stale DerivedData warnings. Some test
launches could not foreground the app; all reported integration assertions
completed successfully. No generated configuration cleanup was required.

## Evidence boundaries

- Four local/loopback integration suites ran in this change. The separate
  external-CDN HLS smoke was not rerun, so this is not a claim that the entire
  legacy macOS script ran as one full gate.
- Physical multi-monitor observation, Intel-native execution, long-duration
  memory/soak profiling, Android device checks and iOS device checks were not
  performed in this change. Screen changes have controlled native regression
  coverage; x86_64 startup was verified through Rosetta.
- New v0.2 consumer, codegen, conformance, and publication gates are corrected
  implementation instructions, not newly implemented or executed gates.
