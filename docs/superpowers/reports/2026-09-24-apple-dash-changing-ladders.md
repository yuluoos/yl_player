# Apple DASH changing ladders: focused acceptance

The previously accepted fixed-selection stage is committed as `76b99d7`.
This changing-ladder stage is included in the current commit. It extends Apple automatic
playback for compatible static clear AVC/AAC DASH presentations whose quality
identities change between Periods. It keeps
the private HLS/AVPlayer route and public API unchanged. The former identical
ladder and singleton domains remain supported. Changing ladders use bounded
complete-program paths keyed by `(width,height,bandwidth)`, with at most 16
distinct identities; each path covers the full program timeline. The public
fixture below happens to be eight seconds long.
Declared codec/Profile, roles, display ratio, frame rate, SAR and shared AAC
compatibility are checked before media URL emission. This is manifest-level
admission, not arbitrary bitstream equivalence or HDR conversion.

The compiler and loader gate is recorded in the Task 1 stage report at
`.superpowers/sdd/2026-09-24-apple-dash-changing-ladders/task-1-report.md`.
Before the review fix, each platform passed 55 focused tests: 37 compiler and
18 loader. Review finding I1 exposed duplicate quality identities with
irrelevant audio declaration differences. A three-line production guard and
regression were added, then three targeted compiler cases passed on each
platform. There was no post-fix 56-test full rerun; the 55-test and 3-test
evidence are separate. The prior automatic multivariant playback gate
selected 320×180 on both platforms and did not establish actual size changes.

The new public integration file is
`packages/yl_player/example/integration_test/apple_dash_changing_ladders_test.dart`.
Two new MPDs force high-only→low-only and low-only→high-only video across two
four-second Periods, reusing the separately encoded 640×360 and 320×180 AVC
bytes and shared AAC. A third case uses the existing `manifest_missing_high.mpd`
to exercise a multivariant first Period followed by a low-only Period, without
assuming AVPlayer's first-Period choice. The MPDs and every reused media file
are covered by `SHA256SUMS`.

Each public case requires a matching-session first-frame event, AVPlayer
engine, automatic video selection with `initial` reason at the initial,
natural-transition, post-seek and completed checkpoints, selected audio,
eight-second duration, reported output geometry,
monotonic natural position across 4.5 seconds, geometry after the natural
transition and after resumed progression from seeks to five and one seconds,
with the backward-seek resumed sample before the four-second Period boundary,
completion at or beyond 7.5 seconds, and actual init/media requests for video
and audio in both Periods. The forced cases assert both exact geometries at
first frame, natural transition, seek-five and seek-one checkpoints. A media
request or command acknowledgement alone does not satisfy the output checks.

macOS 27.0 arm64 (26A428) passed all three public cases. High→low geometry was
640×360, 320×180, 320×180, 640×360 at those four checkpoints; low→high was
320×180, 640×360, 640×360, 320×180. The missing-high case reported 320×180
throughout. Natural sampled position reached 4750 ms; resumed seek samples
were 5750 and 1750 ms in each case. Final positions were 8008, 8007 and
8008 ms. The server log captured corresponding video and shared
audio init/media requests from both Periods. The exact command and output are
in `/private/tmp/yl-dash-changing-play-macos-finalwave.log`.

iOS 27.0 arm64 Simulator on iPhone 18 Pro
`A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6` also passed all three cases.
High→low reported 640×360, 320×180, 320×180, 640×360 and completed at
8006 ms; low→high reported 320×180, 640×360, 640×360, 320×180 and
completed at 8007 ms. The missing-high multivariant case reported 320×180
at all four checkpoints and completed at 8005 ms. Natural sampled position
reached 4750 ms and resumed seek samples were 5750 and 1750 ms in every case;
the server captured corresponding video and shared-audio
init/media requests in both Periods. The output is in
`/private/tmp/yl-dash-changing-play-ios-finalwave.log`. Earlier passing runs
are retained in the `-task2-r1.log` and initial playback logs. In the initial
round, an iOS
discovery attempt (`/private/tmp/yl-dash-changing-play-ios.log`) exited
before tests because Flutter did not enumerate the shutdown simulator.

Executed from `packages/yl_player/example`:

```sh
python3 /Users/yy2021_8689/Desktop/Flutter/yl_player/tool/run_with_display_awake.py /Users/yy2021_8689/flutter/bin/flutter test integration_test/apple_dash_changing_ladders_test.dart -d macos --no-pub --reporter expanded > /private/tmp/yl-dash-changing-play-macos-finalwave.log 2>&1
xcrun simctl boot A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6
xcrun simctl bootstatus A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6 -b
/Users/yy2021_8689/flutter/bin/flutter test integration_test/apple_dash_changing_ladders_test.dart -d A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6 --no-pub --reporter expanded > /private/tmp/yl-dash-changing-play-ios-finalwave.log 2>&1
xcrun simctl shutdown A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6
```

The final minor-fix tests ran serially and passed 3/3 on each platform. The iPhone
simulator began and ended Shutdown. Asset SHA-256 audit and targeted Dart
analysis, formatting and `git diff --check`
were performed. Flutter-generated iOS/macOS `FLUTTER_TARGET` assignments
were restored to `lib/main.dart`. No native production source, Android
playback test or broader Apple suite was changed or rerun in this task.

Scope remains automatic compatible static DASH only. This evidence does not
establish Apple fixed selection, a strict quality ceiling, quantitative
weak-network ABR, decoded pixel comparison, physical iOS hardware, minimum-OS
coverage, DRM, HDR/SDR conversion, or general DASH interoperability. The
macOS Flutter runner's foreground helper returned 1 while the actual three
integration assertions passed; existing Swift Sendable warnings remained.

Independent task reviews and the final whole-stage review are complete. The
last backward-seek sampling observation was tightened and passed one scoped
re-review; no Critical or Important finding remains. Existing build diagnostics
are disclosed above and remain a separate follow-up.
