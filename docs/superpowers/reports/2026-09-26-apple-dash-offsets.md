# Apple DASH aligned presentation offsets

Baseline: `f88f993`, the committed DASH diagnostics stage. This stage extends
REQ-02/04 and CAP-DASH/PERIOD with nonzero `presentationTimeOffset` for the
existing clear static AVC/AAC subset. There is no public API, wire schema,
dependency, SDK, deployment-floor or Android implementation change.

## Implemented boundary

SegmentTemplate and SegmentList require an explicit SegmentTimeline that spans
exactly `[PTO, PTO + Period duration)` in its timescale, with complete contiguous
segments. Missing first `S@t` remains zero; `$Time$` uses the raw sample timestamp.
Positive and finite negative repeats, inherited timing and byte ranges retain
their existing checks. Checked integer arithmetic rejects overflow before
expansion. All original candidates and optional audio have exactly equal reduced
rational origins before caps or fixed projection. Origins can differ by Period.

The chosen boundary costs compatibility with partial-segment edits, non-timeline
offsets and independently shifted audio/video; these remain future work, not a
reduction of the accepted overall DASH requirement. Production rewrites no
media. HLS durations/discontinuities provide the existing program timeline.
The implementation follows the sample/MPD time distinction in the
[DASH-IF timing model](https://dashif.org/Guidelines-TimingModel/) and the rendition
timestamp/discontinuity rules of [RFC 8216](https://www.rfc-editor.org/rfc/rfc8216.html).

## Native evidence

`xcodebuild test -quiet -parallel-testing-enabled NO -collect-test-diagnostics never`
uses example `Runner.xcworkspace`, scheme `Runner`, derived data
`packages/yl_player/example/build/native-{macos,ios}-tests`. macOS destination is
`platform=macOS,arch=arm64`; iOS is
`platform=iOS Simulator,id=A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6` (iOS 27).
Final selectors are `RunnerTests/YlDashHlsCompilerTests` and
`RunnerTests/YlDashResourceLoaderTests`.

- RED: four new aligned-offset methods selected, three acceptance cases failed
  on the existing rejection; the refusal matrix passed. Bundle/log:
  `/private/tmp/yl-offset-native-red.{xcresult,log}`.
- macOS: **106/106 passed**, no skip/failure.
  `/private/tmp/yl-offset-macos.{xcresult,log}`.
- iOS: **106/106 passed**, no skip/failure.
  `/private/tmp/yl-offset-ios.{xcresult,log}`.

Both actual result trees were checked against the complete selected canonical
method identities. Current inventory is 607 iOS / 523 macOS (+4); those inventory
totals are not execution counts. Original historical inventories and skip
conditions are unchanged. Tests cover raw Time/Number URLs, inherited PTO,
SegmentList ranges, exact ratios at different scales, neighboring origins above
2^53, finite repeats, implicit-start/clipping/gap/overflow/budget rejection,
whole-original validation before caps/fixed pruning, and existing loader and
selection lifecycle cases.

## Media fixture and Dart checks

A test-only transformer copies the owned `dash_variants` fixtures, shifting real
fragment `tfdt` decode times and `sidx` earliest presentation timestamps by 10s
for Period 0 and 30s for Period 1. MPD origins and segment URL times shift with
those bytes. Both video qualities and shared AAC use the same seconds origin.
Initialization and mdat payloads remain unchanged. Production does not contain
this transformer and original checked-in media still match both SHA256SUMS files.

The helper's no-op RED failed all three tests. Direct green covers tfdt/sidx v0
and v1 shifts, unchanged source/media bytes and invalid-version/truncation/size/
negative-delta/timescale/overflow rejection. `flutter test test --no-pub` from
`packages/yl_player/example` passed **11/11**, including all three new helper
cases and existing example/server tests (`/private/tmp/yl-offset-example-unit.log`).
A fourth helper case subsequently checks literal video/audio byte timestamps
at both Period origins in the built Time/List fixtures, not merely MPD text.
The final complete example suite passes **12/12**
(`/private/tmp/yl-offset-example-unit-final2.log`).
Initial analyze reported three brace-style infos; they were corrected before
public execution. Final targeted analyze reports `No issues found!`
(`/private/tmp/yl-offset-analyze-final2.log`, including the added byte-level case).

## Public playback evidence

Commands run serially per platform from `packages/yl_player/example`:

```sh
python3 /Users/yy2021_8689/Desktop/Flutter/yl_player/tool/run_with_display_awake.py /Users/yy2021_8689/flutter/bin/flutter test integration_test/apple_dash_offsets_test.dart -d macos --no-pub --reporter expanded
python3 /Users/yy2021_8689/Desktop/Flutter/yl_player/tool/run_with_display_awake.py /Users/yy2021_8689/flutter/bin/flutter test integration_test/apple_dash_offsets_test.dart -d A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6 --no-pub --reporter expanded
```

Both cases use actual shifted fragments, one with `$Time$` SegmentTemplate and
one with SegmentList. They require first frame on program time below 1s, duration
8s ±50ms, actual 640px fixed output in each Period, same-session monotonic fixed
state samples through the natural boundary, seek5→1 with continued high output,
auto + low caps with actual 320px output, continued accepted playback after a
misaligned-offset candidate fails, completion, one root MPD request, and shifted
high-video/AAC media requests from both Periods.

macOS **2/2 passed**, `/private/tmp/yl-offset-public-macos.log`:

| Addressing | First fixed high | Natural fixed | Auto/low after cap | Completion |
|---|---:|---:|---:|---:|
| Time template | 500ms | 4750ms | 2000ms | 8012ms |
| SegmentList | 500ms | 4750ms | 2000ms | 8011ms |

iOS **2/2 passed**, `/private/tmp/yl-offset-public-ios.log`: first fixed high
500ms, natural fixed 4750ms, auto/low 2000ms for both cases; completion
8016ms (Time) and 8010ms (List). Both retain one MPD request and usable accepted
playback after candidate rejection. Native and public implementation sources
were unchanged between the final platform runs.

## Warnings and limits

Native macOS/iOS logs contain 134/42 textual `warning:` occurrences, including
existing Sendable/capture/deprecation and Xcode derived-data/deployment warnings.
Both xcresult summaries have zero runtime warnings. macOS public execution
retains `Failed to foreground app; open returned 1` despite successful playback
assertions. No test skip is treated as success.

AAC metadata selection and requests establish audio participation, not a measured
lip-sync error or rendered per-frame PTS guarantee. Minimum-OS/physical-device,
weak-network ABR, general editorial clipping, SegmentBase, DRM, other codecs and
independent audio/video origins are outside this measured stage. PD-02/03 stay
open. No new support claim is based only on MPD declarations.

The final example-suite attempt was initially invoked from the repository root
rather than the example directory. Its four helper and six widget cases passed,
but `live_flv_server_test.dart` (first live connection drops and the next
connection still streams) and `range_media_server_test.dart` (standard GET/range
responses) failed to load their example media assets. That 10-pass/2-fail run
(`/private/tmp/yl-offset-example-unit-final.log`) is retained. Re-running from
the example directory passed all 12 cases without a code change.

Four generated Flutter targets are restored to `lib/main.dart`; the simulator
is shut down. This stage remains uncommitted and no changes were pushed.

## Final independent review

An independent non-author reviewed the complete stage against `f88f993` and
returned **Spec PASS / Quality PASS**, with no Critical, Important or Minor
findings. The reviewer independently checked actual native result identities,
public and example logs, all 14 frozen source hashes, 6 native source hashes and
59 original fixture checksums, without rerunning passing suites.

The reviewer declined to judge quantitative lip-sync/AAC priming/edit-list and
rendered PTS behavior, minimum OS/physical iOS, general DASH interoperability,
weak-network ABR, other codecs, DRM and PD-02/03. These remain explicit evidence
limits and outstanding broader work. Partial clipping, non-timeline offsets and
independent rendition origins remain excluded under the existing full-segment,
common-origin ruling; the cost is that these otherwise valid DASH presentations
remain unsupported. Previously committed diagnostics were not reopened.
No new product ruling or deferred Minor finding resulted from review.

Only this report, the plan completion checkbox and the architecture status were
updated after review. Production and test sources remain the verified versions.
The predecessor diagnostics commit is `f88f993`; this offset stage is left
uncommitted and unpushed for the next commit step.
