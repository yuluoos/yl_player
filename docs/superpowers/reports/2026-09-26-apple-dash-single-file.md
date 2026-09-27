# Apple DASH single-file SegmentList

Baseline: `1a4757c` (aligned presentation offsets). This stage implements omitted
and empty SegmentList resource references within the existing clear static
AVC/AAC fMP4 subset. No new public API, dependency, commercial SDK, minimum OS or
Android implementation change.

## Behavior and boundary

Initialization `sourceURL` and SegmentURL `media` may be omitted or empty. They
resolve to the effective inherited BaseURL (or final redirected document URL
when no BaseURL is declared), including its query. A nonempty reference retains
existing resolution. Every resulting resource still enters the URI budget and
sticky credential-stripping ledger; malformed/overflowing byte ranges and unsafe
URLs reject before HLS media emission. Existing range loading, caps, selection
and rollback behavior is reused.

This resolves a common single-file SegmentList shape. It does not implement
SegmentBase or discover indexes from sidx, and does not relax timing, codec,
network, decoder or cache admission rules. Resource resolution alone cannot
prove that arbitrary referenced bytes contain playable media.

Interoperability references: [Shaka's initialization base reference](https://shaka-project.github.io/shaka-player/docs/api/lib_dash_segment_base.js.html)
and [SegmentList reference resolution](https://shaka-project.github.io/shaka-player/docs/api/lib_dash_segment_list.js.html).
These inform reference handling; local tests establish this project's behavior.

## Verification records

Native commands use `xcodebuild test -quiet -parallel-testing-enabled NO
-collect-test-diagnostics never`, example Runner workspace/scheme, macOS arm64
or iOS simulator `A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6`. Selected complete classes:
`YlDashHlsCompilerTests` and `YlDashResourceLoaderTests`. Current inventory totals
610 iOS / 526 macOS are discovery counts, not executed totals. Historical
inventories and skip conditions remain unchanged.

RED: two new acceptance methods failed under the old implementation; one
invalid-input refusal method passed. `/private/tmp/yl-single-native-red.{log,xcresult}`.
An earlier sandbox startup could not access Xcode services and ran no tests
(`/private/tmp/yl-single-red.log`); the elevated run supplied the actual RED.

macOS: 109/109 passed, zero failures/skips, actual canonical method identities
verified. `/private/tmp/yl-single-macos.{log,xcresult}`.

Test-only packing consumes the owned shifted SegmentList fixture: it concatenates
initialization and media bytes per rendition/Period and emits exact closed byte
ranges. Original assets and initialization/media bytes are not modified by this
packing. Production never packs or rewrites media. Unit expectations use literal
bytes `[1,2,3,4,5,6]` and ranges `0-1`, `2-4`, `5-5`, and verify source isolation.
The helper no-op RED failed (`/private/tmp/yl-single-helper-red.log`); complete
example suite passed 13/13 (`/private/tmp/yl-single-unit.log`). Commands run from
`packages/yl_player/example`: `flutter test test --no-pub`, followed by targeted
`flutter analyze --no-pub` for the four new/changed Dart files. One initial brace
style info was corrected; final analysis is clean
(`/private/tmp/yl-single-analyze-final.log`).

## Evidence limits

The fixture is deliberately limited to the owned two-Period AVC/AAC media and
uses existing 10/30-second aligned offsets. General DASH interoperability,
minimum OS/physical iOS, quantitative AAC priming/lip-sync, weak-network ABR,
other codecs, DRM, subtitles, independent rendition origins and PD-02/03 remain
outside this stage. Full REQ-02/04 acceptance is not claimed.

## Playback fixture correction

First macOS public attempt failed both cases during fixture construction, before
player load, with `Expected owned multi-Period fixture`
(`/private/tmp/yl-single-public-macos.log`). The packer incorrectly required
Period id although the existing shifted fixture identifies its file directory
through Period BaseURL and has no id. Updating the helper unit input to match
that legal shape reproduced the failure
(`/private/tmp/yl-single-helper-period-red2.log`). The packer now consumes the
owned Period BaseURL; it does not require id. Server binding follows successful
fixture construction so such failures do not leave listener resources behind.
Production code did not change during this correction.

iOS native: 109/109 passed, zero failure/skip; canonical identities verified
(`/private/tmp/yl-single-ios.{log,xcresult}`). Both native summaries have zero
runtime warnings. Logs contain 98 macOS / 16 iOS textual `warning:` occurrences,
including existing Sendable/capture/unsafe pointer and XCTest deployment-link
warnings. These are not a lowest-OS validation result.

## Public playback

Commands run serially from `packages/yl_player/example` through the existing
`tool/run_with_display_awake.py` wrapper:

```sh
flutter test integration_test/apple_dash_single_file_test.dart -d macos --no-pub --reporter expanded
flutter test integration_test/apple_dash_single_file_test.dart -d A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6 --no-pub --reporter expanded
```

Each platform runs same-origin explicit DASH and cross-origin automatic MPD.
Both use actual packed files, 10/30s media origins and an 8s program. Assertions
cover first frame near program zero, fixed 640px output with monotonic states
through natural Period transition, seek5→1, auto/320px caps, invalid-range
candidate rollback with continued accepted progress, and completion without
failure. Both Periods' high-video and AAC requests must include initialization
range0 and nonzero closed media ranges. All media requests must address packed
files and retain ordinary headers; credentials remain only on same-origin
requests. Each case requires one root MPD request across reconfiguration.

Final example suite: **13/13**, `/private/tmp/yl-single-unit-final.log`; final
analysis clean, `/private/tmp/yl-single-analyze-final2.log`.
macOS public: **2/2**, `/private/tmp/yl-single-public-macos-final.log`.
Both first fixed high500ms, natural fixed4750ms, auto-low2000ms; completion
8012ms same-origin / 8010ms cross-origin. macOS retains the existing foreground
warning and stale-derived-artifact warnings despite passing assertions.

iOS public: **2/2**, `/private/tmp/yl-single-public-ios.log`.
Both first fixed high500ms, natural fixed4750ms, auto-low2000ms; completion
8012ms same-origin / 8015ms cross-origin. All request-policy and rollback
assertions pass. The ten implementation/test/inventory paths match the frozen
source hashes across both final public runs. All59 original media checksums
remain unchanged. Four generated Flutter targets restored to `lib/main.dart`.

## Final review and closure

Fresh independent non-author review returned **Spec PASS / Quality PASS** for
this stage, with no Critical, Important or Minor findings. It independently
checked all109 actual native method identities per platform, public2/2 each,
example13/13, clean analysis, and all14 final /10 tested /6 native source hashes.
It did not repeat tests, builds or generators.

Review exclusions are retained: general DASH/full REQ-02/04, DRM, lowest OS and
physical-device compatibility, and quantitative lip-sync remain unproven. The
cost of this scoped acceptance is that these broader requirements still need
separate implementation/evidence; the passing subset cannot establish them.
No product requirement is removed and no Minor finding is deferred.

Only this report, the plan completion checkbox and architecture status changed
after review. Tested production and test source hashes are unchanged. Simulator
shutdown completed and all four generated Flutter targets are `lib/main.dart`.
Predecessor committed as `1a4757c`; this new stage remains uncommitted/unpushed.
