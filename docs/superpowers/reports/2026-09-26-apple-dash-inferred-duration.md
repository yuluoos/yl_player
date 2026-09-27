# Apple DASH finite final-Period duration

Baseline: `bd51daf` (single-file SegmentList). Implements a bounded compatibility
fallback for missing static final-Period duration under REQ-02/04 and CAP-PERIOD.
No public API, commercial SDK, dependency, deployment-floor or Android change.

## Admission and preserved behavior

Declared Period duration, next explicit Period start and final MPD total retain
precedence. Only an undelimited final Period may infer its duration. Every
original representation, including audio and qualities later excluded by caps
or fixed selection, must have a finite inherited SegmentTimeline and the same
exact positive duration in microseconds. Full segment windows and common media
origin remain required. Different timescales are supported when exact durations
agree. Internal negative repeats are bounded by the next explicit S@t; a final
r=-1 with no declared boundary is rejected. Duration-only templates/lists,
unknown middle boundaries, differing tails, overflow, segment-budget excess and
nonintegral microsecond durations remain unsupported.

Segment inheritance and timeline-run validation are shared by inference and
normal media expansion. Repetition arithmetic and budgets are checked before
expansion. Inference does not load media, guess a frame rate, truncate tracks or
change raw $Time$ addressing. Unsupported candidates still fail before media
emission, preserving the accepted session through the existing transaction path.

The [DASH-IF restricted timing model](https://dashif.org/Guidelines-TimingModel/)
requires an explicit final Period duration. This feature is a compatibility
fallback outside that restricted profile, not a claim that the profile mandates
inference. Its cost is that ambiguous or differently ending presentations remain
unsupported; the overall DASH requirement is not reduced.

## Native evidence

Commands use `xcodebuild test -quiet -parallel-testing-enabled NO
-collect-test-diagnostics never`, example Runner workspace/scheme, native platform
derived data, macOS arm64 or iOS simulator
`A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6`. Full selected classes are
`YlDashHlsCompilerTests` and `YlDashResourceLoaderTests`.

Four new methods cover inherited offset/internal negative repeats, two-Period
program length, SegmentList audio with equal rational duration, divergent audio,
unknown/nonfinite/gapped/overflowed windows, fractional microseconds, preserved
declared duration and hidden rendition mismatch before pruning.

RED: two acceptance methods failed, two refusal cases passed
(`/private/tmp/yl-duration-red.{log,xcresult}`). First GREEN build failed due to
local `duration` redeclaration (`/private/tmp/yl-duration-macos.log`); renaming the
optional declared value fixed compilation without changing the planned logic.
Final macOS: **113/113**, no skips/failures; actual canonical method identities
verified (`/private/tmp/yl-duration-macos-final.{log,xcresult}`). Current inventory
614 iOS /530 macOS are discovery totals, not executed counts; historical inventory
and skip conditions remain unchanged.

Final iOS native: **113/113**, zero skips/failures; actual method identities
verified (`/private/tmp/yl-duration-ios.{log,xcresult}`). Both native result
summaries contain zero runtime warnings. Final logs contain 18 macOS /16 iOS
textual warning occurrences, including pre-existing Sendable/capture, unsafe
pointer and XCTest deployment-link warnings. Those logs do not establish
minimum-OS behavior. Original59 media asset checksums still match.


## Fixture and Dart evidence

The test-only manifest transformer removes MPD total and only final Period
duration. A literal input/output test preserves the first duration and unrelated
SegmentTemplate durations. The no-op RED failed
(`/private/tmp/yl-duration-helper-red.log`); complete example suite **14/14**
(`/private/tmp/yl-duration-unit.log`) and targeted four-file analysis is clean
(`/private/tmp/yl-duration-analyze.log`). Run from `packages/yl_player/example`:
`flutter test test --no-pub` and `flutter analyze --no-pub` with the stage's
integration, server, helper and helper-test files.

Public fixtures reuse actual shifted owned media (10/30s origins), using Time
addressing and packed single-file SegmentList. The server records the actual
manifest it serves so public assertions prove the MPD total/final duration are
absent, and the first Period still declares4s. Original media files are not
modified; no production media rewriting is introduced.

## Limits

This does not claim general DASH or full REQ-02/04 completion, quantitative
lip-sync, minimum OS/physical iOS, weak-network ABR, DRM, subtitles or other codecs.
PD-02/03 remain undecided. Unknown non-final boundaries and inconsistent tracks
need additional design/evidence; no best-effort clipping or shortest-track rule
is silently applied.

## Public playback commands

Executed serially from `packages/yl_player/example`, using the existing
`tool/run_with_display_awake.py` wrapper:

```sh
flutter test integration_test/apple_dash_inferred_duration_test.dart -d macos --no-pub --reporter expanded
flutter test integration_test/apple_dash_inferred_duration_test.dart -d A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6 --no-pub --reporter expanded
```

Two cases per platform: explicit Time-template DASH and automatic MPD with
single-file SegmentList. Each asserts program8s±50ms, first frame near zero,
fixed640px natural transition with same-session monotonic state, seek5→1,
automatic320px caps, rejection of an undelimited r=-1 candidate without retiring
the accepted session, continued progress/completion, one root MPD request,
selected AAC and both Periods' real high-video/audio requests. The served MPD
must actually omit total/final duration. This does not measure per-frame PTS or
quantitative audio synchronization.

macOS: **2/2 passed**, `/private/tmp/yl-duration-public-macos.log`. Both cases
first high500ms, natural fixed4750ms, auto-low2000ms, completion8012ms. The log
retains the existing `Failed to foreground app; open returned 1` warning; actual
playback assertions passed.

iOS: **2/2 passed**, `/private/tmp/yl-duration-public-ios.log`. Both first high500ms,
natural fixed4750ms, auto-low2000ms; completion8013ms (Time) /8015ms (single file).
No source changes between final platform runs. All tested source hashes still
match; four generated Flutter targets restored to `lib/main.dart`.

## Final independent review and closure

Fresh non-author review returned **Spec PASS / Quality PASS** for the bounded
stage, with no Critical, Important or Minor findings. It independently verified
both113-method native identity sets, public2/2 each, example14/14 and clean
analysis, plus all14 final-stage and10 tested-source hashes. No tests/builds
were repeated during review.

Disposition of review exclusions: broader REQ-02/04/05, general DASH/subtitles/
codecs/adaptation, quantitative lip-sync/per-frame PTS, weak-network ABR,
physical iOS and minimum OS remain separate outstanding work. Restricted-profile
conformance remains excluded under the original compatibility ruling. Review
relies on saved execution artifacts and matching source identity, so it does not
prove a fresh environment can reproduce all results. No Minor is deferred.

Final review/status checkboxes are now closed; only this report, the plan and
architecture status changed after review. Tested implementation and test hashes
remain unchanged. Simulator shutdown completed; four generated Flutter targets
are restored. Previous stage committed as `bd51daf`; this new stage remains
uncommitted and unpushed, following the staged delivery workflow.
