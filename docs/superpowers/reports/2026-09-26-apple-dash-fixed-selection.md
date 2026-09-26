# Apple DASH fixed selection and missing-Period fallback

Base: `f3b2cd3`. This uncommitted stage implements the existing public
`selectVideoTrack(String?)` command for the admitted clear static AVC/AAC DASH
subset on macOS and iOS. A chosen quality is projected into the actual media
paths while `videoTracks` remains the full allowed current-Period catalog.
When the confirmed current Period lacks that quality, playback installs the
prepared automatic path and publishes sticky `trackUnavailable`. A later seek
back does not silently restore fixed mode. Apple private wire schema is **4**;
public SPI major remains **2**. No Android implementation or media bytes changed
in this stage.

## Public playback acceptance

The new public integration file is
`packages/yl_player/example/integration_test/apple_dash_fixed_selection_test.dart`.
It uses the existing eight-second two-Period server and media (320×180 at
350,000 declared video bandwidth; 640×360 at 700,000). The base MPD changes
Representation IDs and order in Period 1; `manifest_missing_high.mpd` removes
high there. The commands ran **serially**, first macOS then iPhone 18 Pro iOS
Simulator (`A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6`):

```sh
cd packages/yl_player/example
python3 /Users/yy2021_8689/Desktop/Flutter/yl_player/tool/run_with_display_awake.py /Users/yy2021_8689/flutter/bin/flutter test integration_test/apple_dash_fixed_selection_test.dart -d macos --no-pub --reporter expanded > /private/tmp/yl-apple-fixed-public-macos-final.log 2>&1
xcrun simctl boot A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6
xcrun simctl bootstatus A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6 -b
python3 /Users/yy2021_8689/Desktop/Flutter/yl_player/tool/run_with_display_awake.py /Users/yy2021_8689/flutter/bin/flutter test integration_test/apple_dash_fixed_selection_test.dart -d A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6 --no-pub --reporter expanded > /private/tmp/yl-apple-fixed-public-ios-final.log 2>&1
xcrun simctl shutdown A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6
```

Both final logs end in **3/3 passed**. All three scenarios observed one primary
MPD request, unchanged session identity before Stop, a selected AAC track
after metadata settled, and no session failure. Every emitted Load-paired
state through the last pre-Stop phase was audited for session identity,
fixed-ID membership in that state's catalog, fixed/user reason, and unselected
catalog entries. Once a high decoded frame was confirmed, **every** state in
the fixed-high interval was required to retain high/user and both catalog IDs;
each non-null geometry in that interval had to remain 640×360. The public
state stream samples published geometry, not individual frame PTS.

| Public scenario | macOS observations | iOS observations |
|---|---|---|
| Explicit DASH fixed high across ID/order change, then user auto and fixed low | 640×360 at 500 ms and Period 1 at 4750 ms; 320×180 after user low at 5250 ms; 87 states | Same positions/sizes; 85 states |
| Automatic `.mpd` route, conflicting low cap, then user auto and feasible low cap | High at 500 ms and continued high at 1000 ms after rejected `decoder.quality_constraint_unsupported`; low at 1500 ms after clear/cap; excluded high ID rejected as `policy.video_selection_unsupported`; 2 emitted states during cap rejection, 0 during invalid-ID rejection | Same positions, sizes, errors and rejection counts |
| Explicit missing-high MPD, natural fallback, backward seek and low cap | High at 500 ms; first `trackUnavailable` at 4013 ms; decoded low at 4750 ms; seek back to 1000 ms stayed automatic; low cap produced decoded 320×180 at 1500 ms in first Period; 89 states | First fallback exactly 4000 ms; other positions/sizes same; 87 states |

The natural first fallback therefore did not precede the declared four-second
boundary. After seekback the public mode stayed automatic/trackUnavailable;
decoded 320×180 in the first Period was observed **after** the low-only cap
transaction. That public observation does not isolate the immediately installed
automatic spare before the cap; native tests establish that immediate
installation. Stop reset each session
to idle, empty catalog, automatic/initial. `videoGeometry` is observed decoded
size; these runs do **not** measure selected bitrate or network ABR behavior.

Targeted format/analyze commands were:

```sh
/Users/yy2021_8689/flutter/bin/dart format packages/yl_player/example/integration_test/apple_dash_fixed_selection_test.dart
/Users/yy2021_8689/flutter/bin/dart analyze packages/yl_player/example/integration_test/apple_dash_fixed_selection_test.dart
git diff --check
```

Format completed, analyze returned `No issues found!`, and diff checking
passed. After the
final runs, the four iOS/macOS Flutter generated target entries were restored
to `lib/main.dart`; the simulator was verified `Shutdown`. The 39 frozen Task 1
source hashes in `task-1-source-hashes.json` and all 38 fixture hashes in
`media-baseline.json` still matched exactly. Final new-file SHA-256 is
`ce9d9de96a7d826407933557ead17a23149f6d2b2390d33c63724365c96de603`;
`docs/platform-support.md` is
`a13a48cc709a9165b5e4ec47607da3cd36d6089fd8c540be4582b415e9a14e94`.
The support page now describes schema 4, conditional automatic default,
fixed selection, cap conflict, catalog meaning, and sticky fallback.
`docs/transport-compatibility.md` is
`5e6abd3f1d9013709451fb0e8408aae58baf505d3bc05e50651fe66e421f8865`;
it preserves the dated schema-3 DASH history and states the current Apple
schema-4 mismatch/factory-tag behavior.

## Native and Dart implementation evidence

Task 1's frozen native/Dart change added the Apple selection SPI, awaited
nullable-ID Pigeon command, schema-4 full-state selection and delta retention,
strict semantic quality matching, a separate complete allowed catalog, fixed
media projection, a dormant bounded automatic candidate, guarded current-Period
fallback, seek/output fencing, and transaction/lifecycle cleanup. Full details
and frozen source inventory are in the Task 1 report under
`.superpowers/sdd/2026-09-26-apple-dash-fixed-selection/`.

The relevant native broad suites (`YlDashResourceLoaderTests`,
`YlDashHlsCompilerTests`, `YlAppleRegistryTests`, `YlAppleHostTests`) ran with:

```sh
xcodebuild test -quiet -parallel-testing-enabled NO -collect-test-diagnostics never -workspace packages/yl_player/example/macos/Runner.xcworkspace -scheme Runner -sdk macosx -destination 'platform=macOS,arch=arm64' -derivedDataPath packages/yl_player/example/build/native-macos-tests -resultBundlePath /private/tmp/yl-fixed-macos-final2.xcresult -only-testing:RunnerTests/YlDashResourceLoaderTests -only-testing:RunnerTests/YlDashHlsCompilerTests -only-testing:RunnerTests/YlAppleRegistryTests -only-testing:RunnerTests/YlAppleHostTests > /private/tmp/yl-fixed-macos-final2.log 2>&1
xcodebuild test -quiet -parallel-testing-enabled NO -collect-test-diagnostics never -workspace packages/yl_player/example/ios/Runner.xcworkspace -scheme Runner -sdk iphonesimulator -destination 'platform=iOS Simulator,id=A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6' -derivedDataPath packages/yl_player/example/build/native-ios-tests -resultBundlePath /private/tmp/yl-fixed-ios-final.xcresult -only-testing:RunnerTests/YlDashResourceLoaderTests -only-testing:RunnerTests/YlDashHlsCompilerTests -only-testing:RunnerTests/YlAppleRegistryTests -only-testing:RunnerTests/YlAppleHostTests > /private/tmp/yl-fixed-ios-final.log 2>&1
```

Those receipts are **110/110 macOS** and **112/112 iOS**, zero failed or
skipped. They predate the final four-line display-callback generation guard.
After that guard, the three focused frame/fallback cases ran **3/3 macOS** and
**3/3 iOS**, zero failed/skipped, with the selectors
`testFixedFrameCannotPublishAfterFallbackRetiresItsItem`,
`testFixedOutputRejectsFuturePeriodAndContradictoryPixelsBeforePublication`,
and `testFixedAutomaticInstallationFailureRetainsTruthfulModeAndReleasesSpare`.
Their result bundles/logs are `/private/tmp/yl-fixed-frame-macos-green.*` and
`/private/tmp/yl-fixed-frame-ios-green.*`. These are separate receipts; there
was **no final full 113/115-case sweep**.

```sh
xcodebuild test -quiet -parallel-testing-enabled NO -collect-test-diagnostics never -workspace packages/yl_player/example/macos/Runner.xcworkspace -scheme Runner -sdk macosx -destination 'platform=macOS,arch=arm64' -derivedDataPath packages/yl_player/example/build/native-macos-tests -resultBundlePath /private/tmp/yl-fixed-frame-macos-green.xcresult -only-testing:RunnerTests/YlDashResourceLoaderTests/testFixedFrameCannotPublishAfterFallbackRetiresItsItem -only-testing:RunnerTests/YlDashResourceLoaderTests/testFixedOutputRejectsFuturePeriodAndContradictoryPixelsBeforePublication -only-testing:RunnerTests/YlDashResourceLoaderTests/testFixedAutomaticInstallationFailureRetainsTruthfulModeAndReleasesSpare > /private/tmp/yl-fixed-frame-macos-green.log 2>&1
xcodebuild test -quiet -parallel-testing-enabled NO -collect-test-diagnostics never -workspace packages/yl_player/example/ios/Runner.xcworkspace -scheme Runner -sdk iphonesimulator -destination 'platform=iOS Simulator,id=A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6' -derivedDataPath packages/yl_player/example/build/native-ios-tests -resultBundlePath /private/tmp/yl-fixed-frame-ios-green.xcresult -only-testing:RunnerTests/YlDashResourceLoaderTests/testFixedFrameCannotPublishAfterFallbackRetiresItsItem -only-testing:RunnerTests/YlDashResourceLoaderTests/testFixedOutputRejectsFuturePeriodAndContradictoryPixelsBeforePublication -only-testing:RunnerTests/YlDashResourceLoaderTests/testFixedAutomaticInstallationFailureRetainsTruthfulModeAndReleasesSpare > /private/tmp/yl-fixed-frame-ios-green.log 2>&1
```

Task 1 also ran:

```sh
PATH=/Users/yy2021_8689/flutter/bin:$PATH flutter test packages/yl_player_apple/test packages/yl_player/test/apple_player_controller_test.dart packages/yl_player_platform_interface/test > /private/tmp/yl-fixed-dart-final.log 2>&1
PATH=/Users/yy2021_8689/flutter/bin:$PATH dart analyze packages/yl_player_apple/lib packages/yl_player_apple/test packages/yl_player/test/apple_player_controller_test.dart packages/yl_player_platform_interface/lib/src/diagnostics/safe_diagnostics.dart > /private/tmp/yl-fixed-analyze-final.log 2>&1
PATH=/Users/yy2021_8689/flutter/bin:$PATH sh packages/yl_player_apple/tool/generate_pigeon.sh
```

The Dart result was **228/228 passed** and targeted analyze reported `No
issues found!`. Pinned Pigeon 28.0.0 was run twice with byte-identical output;
`task-1-pigeon-hashes.json` records it. Current native inventory/mirrors
verified 601 iOS and 517 macOS test identities (+12), without changing
historical inventories, skip rules, or allowance counts.

## Failed-attempt and warning history

Task 1 deliberately recorded RED and corrective runs. The initial Dart SPI
case proved Apple lacked the command; schema testing first selected the wrong
XCTest class and ran zero tests, then a mixed build also ran zero, before a real
schema RED showed schema 3 was accepted and 4 rejected. Host RED returned the
honest unsupported command. Lifecycle tests initially exposed an accidental
change to the existing inactive-cap error, which was restored. Cancelled-seek
RED exposed premature PD-01; recovery RED exposed missing autonomous recovery;
the bounded single retry, five-second deadline and fencing were then added.
The first broad Dart attempt passed 94 Apple cases but could not compile a
public test stub until its new method/schema fixtures were updated. Diagnostic
RED lacked the safe `source.seek_failed` message. The first broad native macOS
run had 109 passes/1 failure because an unknown-ID safe code was collapsed to
`platform.failure`; allowlist/messaging were corrected and the 110-case rerun
passed. A final frame RED found publication of a retired buffer after fallback;
the focused 3/3 runs on both OS passed after its guard. The full native attempt
history, exact selectors and logs remain in `task-1-native-history.json` and
`task-1-commands.txt`; no zero-test attempt is counted as a pass.

Task 2's first two macOS attempts each had **0/3 passed** because the new audit
incorrectly included controller idle or required AVPlayer before the
Load-paired loading state had assigned an engine. A third attempt passed the
first scenario, then two checks read audio before metadata settled after
replacement (1/3 passed). The fourth, strengthened macOS attempt passed 3/3.
The final source added explicit audio-ready predicates to every sampled audio
assertion and passed 3/3 macOS and 3/3 iOS. These were test-harness corrections;
no production failure was observed. Task 2 log paths in order are
`/private/tmp/yl-apple-fixed-public-macos.log`, `-macos2.log`, `-macos3.log`,
`-macos4.log`, `-macos-final.log`, and `-ios-final.log` with the same
`yl-apple-fixed-public` prefix.

Native builds retain existing warning noise: the broad final macOS/iOS logs
contain 42/80 textual `warning:` occurrences and 3/4 recorded runtime
warnings; the final focused macOS/iOS logs contain 10/24 textual warnings and
zero runtime warnings. They include Swift Sendable/capture, Network switch,
deprecated API and generated/test diagnostics. Textual `error:` occurrences
in native logs include echoed source context and are not XCTest failure counts.
The first two Task 2 macOS rebuild logs had 46/90 textual warnings; the final
macOS and iOS public logs had zero warning/error text. macOS logs report
`Failed to foreground app; open returned 1` even though the app ran and the
final assertions passed. No auto-review rejection affected the tests.

The independent Task 1 review approved the implementation with two minor
qualifications: recovery-deadline retirement after newer seek/replacement/Stop
is guarded and code-inspected but those exact interleavings were not all
directly exercised, and existing native warning noise remains. This stage's
native and public fixtures do not establish arbitrary DASH/DRM/HDR support,
weak-network response, seamless switches, selected bitrate, or a physical
device/minimum-OS matrix. Historical reports remain descriptions of their
earlier stages. No commit or push was made.

## Final review and completion

Both independent task reviews and the final whole-stage review approved spec
compliance and code quality; no Critical or Important finding remains. The
final reviewer verified the 39 native/transport and 3 public/support source
hashes against the frozen evidence, keeping the broad and final focused native
receipts separate. No production fix wave or repeated suite was required.
The two nonblocking qualifications above remain deferred: exact retired
recovery-deadline interleavings and existing warning/environment noise.

The two implementation rulings retain their explicit costs. Preparing one
dormant automatic candidate permits synchronous sticky fallback but retains
bounded additional manifests/asset and can briefly buffer on replacement.
One guarded recovery after the latest cancelled fixed seek has a five-second
deadline; failure costs a bounded delay followed by explicit
`source.seek_failed`, rather than leaving output gated indefinitely.

The review declined to judge arbitrary DASH/DRM/HDR and codec interoperability,
quantitative weak-network ABR/selected bitrate/seamless latency, physical-device
and minimum-OS coverage, every rendered frame's PTS, or an isolated uncapped
post-seekback decoder choice. These remain explicit evidence boundaries, not
completed capabilities. The immediate automatic installation requirement has
separate native evidence; public low output after seekback follows a low-cap
transaction.

The prior runtime-caps stage is committed as `f3b2cd3`. This fixed-selection
stage is complete and remains uncommitted, with no push. Four generated Flutter
targets are restored to `lib/main.dart`; no simulator remains booted. The final
simulator status query needed sandbox escalation for CoreSimulator access and
then succeeded; it did not rerun playback tests. Final bookkeeping changes only
the plan, architecture entry, this report and the private progress ledger.
