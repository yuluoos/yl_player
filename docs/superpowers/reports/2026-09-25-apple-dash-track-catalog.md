# Apple DASH current-Period video catalog

At baseline `2aa997c`, Apple AVPlayer exposed asset video tracks as DASH
qualities and could mark each selected. This stage publishes the accepted,
cap-filtered MPD video declarations for the playback Period containing the
measured program position. The public ID is
`dash-video-w{width}-h{height}-b{bandwidth}`; video tracks sort by those three
numeric values and all have `isSelected == false`. `videoSelection` remains
automatic with reason `initial`. Codec, dimensions, and bitrate are MPD
declarations, not proof of the decoded rendition. `videoGeometry` separately
reports the displayed frame.

The native compiler retains exact validated microsecond Period boundaries in
an immutable catalog, carried through the accepted loader and installed
backend. Full states and timeline deltas query measured program time. At a
catalog change the backend publishes a full state from the same time sample,
avoiding a new position paired with the old catalog. Failed candidates cannot
replace the accepted catalog; Stop and ordinary-source transitions clear it.
The loader snapshot and inactive/resume paths preserve the accepted catalog.
No public schema, media bytes, dependencies, or new source routes were added.

## Evidence

Native evidence, separately from public playback: the focused compiler and
loader/backend batch ran 79 cases on each of macOS 27 arm64 and iOS 27 arm64
Simulator. A later exact-restoration fix ran 11 targeted cases on each OS; it
did not rerun or add to the 79-case batch. Latest current inventory is 583 iOS
and 499 macOS cases. Native cases cover stable numeric identity, sorting,
deduplication, cap projection, exact submillisecond boundaries, loader
cancellation, measured natural/seek publication, metadata isolation, and
restoration. The fractional restore proof uses a controlled requested `CMTime`
and fake measured landing. It is not a real-media submillisecond playback
observation. Reproducible commands and the batch history are recorded below;
the local working reports are excluded from Git.

The focused public file
`packages/yl_player/example/integration_test/apple_dash_track_catalog_test.dart`
ran three cases on each OS using the existing 32 media files and two four-second
Periods. It exercised explicit DASH and automatic `.mpd` routes. Each nonempty
catalog state was checked for exact IDs, declared `avc1.42c01e` codec,
350000/700000 video bitrates, 320×180/640×360 dimensions, all unselected,
and automatic/initial selection. The changing-ladder case checked **every**
emitted current-session state with a nonempty catalog: published position below
4000 ms required the high-only catalog; position at or above 4000 ms required
the low-only catalog, including transient deltas. Public observations used the
fixture's exact four-second boundary, not the native fractional boundary.
For the rejected candidate, the final focused test also checks **every** state
emitted from immediately before candidate Load until Stop, including empty or
wrong-session states: all four observed states on each OS retained the accepted
session, low catalog, and automatic/initial selection.

| Public case | macOS 27 arm64 | iOS 27 arm64 Simulator |
|---|---|---|
| Reordered two-quality Periods | First 0 ms, natural 4750 ms, seek back 1750 ms, forward 5750 ms, complete 8014 ms; geometry 320×180 throughout | Same checkpoints 0/4750/1750/5750/8015 ms; geometry 320×180 |
| High-only → low-only | High 640×360 at 0 and 1750 ms; low 320×180 at 4750, 5750, 8015 ms; 46 high and 33 low catalog states coherent | Same geometry at 0/1750 and 4750/5750/8016 ms; 44 high and 32 low states coherent |
| Cap 320×180/350000, rejected candidate, Stop | Low catalog at 0/4750/1500/2000/2500 ms; candidate media requests 0; stopped catalog 0 | Same positions and results |

The final public file passed **3/3 macOS** and then **3/3 iOS Simulator**.
An initial macOS run passed the first two cases and failed the third because
the test read `player.state` immediately after the Stop command returned,
before the published idle state arrived. The test now awaits the idle state
and asserts its catalog is empty; the final macOS and iOS runs passed. Full
public command/output and the initial failure are recorded below. A later
review strengthened only the candidate-isolation assertion. That one case
then passed 1/1 on macOS and 1/1 on iOS Simulator, serially; the full
three-case file was not rerun after this test-only change.

## Commands, logs, and batch qualification

Native commands ran from the repository root. The initial 79-case macOS and
iOS compiler/loader selections used these exact invocations:

```sh
xcodebuild test -quiet -parallel-testing-enabled NO -workspace packages/yl_player/example/macos/Runner.xcworkspace -scheme Runner -sdk macosx -destination 'platform=macOS,arch=arm64' -derivedDataPath packages/yl_player/example/build/native-macos-tests -resultBundlePath /private/tmp/yl-dash-catalog-macos-green2.xcresult -only-testing:RunnerTests/YlDashHlsCompilerTests -only-testing:RunnerTests/YlDashResourceLoaderTests > /private/tmp/yl-dash-catalog-macos-green2.log 2>&1
xcodebuild test -quiet -parallel-testing-enabled NO -workspace packages/yl_player/example/ios/Runner.xcworkspace -scheme Runner -sdk iphonesimulator -destination 'platform=iOS Simulator,id=A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6' -derivedDataPath packages/yl_player/example/build/native-ios-tests -resultBundlePath /private/tmp/yl-dash-catalog-ios-final.xcresult -only-testing:RunnerTests/YlDashHlsCompilerTests -only-testing:RunnerTests/YlDashResourceLoaderTests > /private/tmp/yl-dash-catalog-ios-final.log 2>&1
```

The later restore fix selected these exact eleven native cases on both OSes:

```text
YlDashResourceLoaderTests/testCatalogFollowsMeasuredProgramTimeAndPeriodicPublication
YlDashResourceLoaderTests/testCatalogLoaderSnapshotSurvivesCancellationWhilePrivateSnapshotClears
YlDashResourceLoaderTests/testCatalogSeekUsesActualLandingAndRetiredCompletionCannotPublish
YlDashResourceLoaderTests/testCatalogMetadataIsolationOrdinarySourceAndSavedPositionRestoration
YlDashResourceLoaderTests/testCatalogBackendSubMillisecondBoundaryAndInvalidClockAreSafe
YlDashResourceLoaderTests/testCatalogRetainedReplacementRestoreSeeksExactFractionalBoundary
YlDashResourceLoaderTests/testCatalogStagedLoaderRestoreSeeksExactFractionalBoundary
YlDashResourceLoaderTests/testHeaderedHlsRestoreKeepsLatestPreferencesWhileNewLoadKeepsCapturedTuple
YlDashResourceLoaderTests/testLoadCapsRuntimeMutationFailsBeforeAcceptedIntentAndSurvivesRestore
YlDashResourceLoaderTests/testCoordinatorKeepsDashSessionOnInvalidReplacementAndRebuildsPrivateAssetOnResume
YlDashResourceLoaderTests/testStopDuringMPDPreflightAllowsNewLoadAndIgnoresLateResponse
```

For compact reproduction, these commands construct the same
`-only-testing:RunnerTests/...` arguments from the exact names above:

```sh
cases=(YlDashResourceLoaderTests/testCatalogFollowsMeasuredProgramTimeAndPeriodicPublication YlDashResourceLoaderTests/testCatalogLoaderSnapshotSurvivesCancellationWhilePrivateSnapshotClears YlDashResourceLoaderTests/testCatalogSeekUsesActualLandingAndRetiredCompletionCannotPublish YlDashResourceLoaderTests/testCatalogMetadataIsolationOrdinarySourceAndSavedPositionRestoration YlDashResourceLoaderTests/testCatalogBackendSubMillisecondBoundaryAndInvalidClockAreSafe YlDashResourceLoaderTests/testCatalogRetainedReplacementRestoreSeeksExactFractionalBoundary YlDashResourceLoaderTests/testCatalogStagedLoaderRestoreSeeksExactFractionalBoundary YlDashResourceLoaderTests/testHeaderedHlsRestoreKeepsLatestPreferencesWhileNewLoadKeepsCapturedTuple YlDashResourceLoaderTests/testLoadCapsRuntimeMutationFailsBeforeAcceptedIntentAndSurvivesRestore YlDashResourceLoaderTests/testCoordinatorKeepsDashSessionOnInvalidReplacementAndRebuildsPrivateAssetOnResume YlDashResourceLoaderTests/testStopDuringMPDPreflightAllowsNewLoadAndIgnoresLateResponse)
selectors=(); for test_name in "${cases[@]}"; do selectors+=("-only-testing:RunnerTests/$test_name"); done
xcodebuild test -quiet -parallel-testing-enabled NO -workspace packages/yl_player/example/macos/Runner.xcworkspace -scheme Runner -sdk macosx -destination 'platform=macOS,arch=arm64' -derivedDataPath packages/yl_player/example/build/native-macos-tests -resultBundlePath /private/tmp/yl-dash-catalog-fix1-macos-green.xcresult "${selectors[@]}" > /private/tmp/yl-dash-catalog-fix1-macos-green.log 2>&1
xcodebuild test -quiet -parallel-testing-enabled NO -workspace packages/yl_player/example/ios/Runner.xcworkspace -scheme Runner -sdk iphonesimulator -destination 'platform=iOS Simulator,id=A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6' -derivedDataPath packages/yl_player/example/build/native-ios-tests -resultBundlePath /private/tmp/yl-dash-catalog-fix1-ios-green.xcresult "${selectors[@]}" > /private/tmp/yl-dash-catalog-fix1-ios-green.log 2>&1
```

Native result receipts live beside those bundles as
`/private/tmp/yl-dash-catalog-{macos-green2,ios-final}-evidence/{summary,tests,case-identities}.json`
and
`/private/tmp/yl-dash-catalog-fix1-{macos,ios}-green-evidence/{summary,tests,case-identities}.json`.
The macOS 79-case run was followed by test-only strengthening: a targeted
three-case run passed one fractional-clock test and failed two host-callback
checks because the fixture consumer lacked `host.attach()`
(`/private/tmp/yl-dash-catalog-macos-final-targeted.{log,xcresult}`). After
fixture setup was corrected, those two cases passed in a separate focused
run (`/private/tmp/yl-dash-catalog-macos-candidate-final.{log,xcresult}`).
The final iOS 79-case run used all final test sources. A subsequent native
restore regression first failed two cases on pre-fix macOS production
(`/private/tmp/yl-dash-catalog-fix1-red.{log,xcresult}`), then the exact
11-case selection passed on each OS after the fix. These batches are separate;
there is no claim that one final macOS run covered all final native sources.
An earlier macOS green1 build failed before testing because a helper shadowed
an existing time conversion; its log is
`/private/tmp/yl-dash-catalog-macos-green1.log`.

Public commands ran from `packages/yl_player/example`, macOS before iOS:

```sh
CI=true /Users/yy2021_8689/flutter/bin/cache/dart-sdk/bin/dart format integration_test/apple_dash_track_catalog_test.dart
CI=true /Users/yy2021_8689/flutter/bin/cache/dart-sdk/bin/dart analyze integration_test/apple_dash_track_catalog_test.dart
CI=true python3 ../../../tool/run_with_display_awake.py /Users/yy2021_8689/flutter/bin/flutter test integration_test/apple_dash_track_catalog_test.dart -d macos --no-pub --reporter expanded > /private/tmp/yl-dash-catalog-public-macos.log 2>&1
CI=true python3 ../../../tool/run_with_display_awake.py /Users/yy2021_8689/flutter/bin/flutter test integration_test/apple_dash_track_catalog_test.dart -d macos --no-pub --reporter expanded > /private/tmp/yl-dash-catalog-public-macos-final.log 2>&1
CI=true python3 ../../../tool/run_with_display_awake.py /Users/yy2021_8689/flutter/bin/flutter test integration_test/apple_dash_track_catalog_test.dart -d A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6 --no-pub --reporter expanded > /private/tmp/yl-dash-catalog-public-ios.log 2>&1
CI=true python3 ../../../tool/run_with_display_awake.py /Users/yy2021_8689/flutter/bin/flutter test integration_test/apple_dash_track_catalog_test.dart -d macos --no-pub --reporter expanded --plain-name 'capped catalog survives failed candidate and Stop clears it' > /private/tmp/yl-dash-catalog-public-fix1-macos.log 2>&1
CI=true python3 ../../../tool/run_with_display_awake.py /Users/yy2021_8689/flutter/bin/flutter test integration_test/apple_dash_track_catalog_test.dart -d A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6 --no-pub --reporter expanded --plain-name 'capped catalog survives failed candidate and Stop clears it' > /private/tmp/yl-dash-catalog-public-fix1-ios.log 2>&1
```

`/private/tmp/yl-dash-catalog-public-macos.log` ends at 2 passed / 1 failed
on the premature Stop-state read. The final macOS and iOS logs each end at
`+3: All tests passed!`; the two fix1 logs each end at `+1: All tests passed!`
and print `candidateIntervalStates=4`, `candidateMediaRequests=0`, and
`stopTracks=0`. Targeted Dart analysis reported no issues. macOS Flutter
printed nonfatal Xcode stale-file warnings from existing
`build/native-macos-tests` derived data and “Failed to foreground app; open
returned 1”; the application built and tests passed. Native build logs also
contain existing Swift 6 Sendable/AnyHashable and captured test-value warnings,
deprecated URLSession mock initializer warnings, XCTest deployment-version
linkage warnings, and always-run script phase warnings. No skip is claimed as
a pass. The existing iPhone 18 Pro iOS 27 Simulator was Shutdown before and
after both public iOS runs; all four generated `FLUTTER_TARGET` assignments
were restored to `lib/main.dart`. The fixture's 32 tracked media files and
manifests were unchanged.

These results establish the public catalog and lifecycle on this synthetic
clear AVC/AAC fixture on the named Apple environments. They do not establish
which rendition AVPlayer selected in a multivariant Period, fixed selection,
runtime cap mutation, weak-network ABR, other DASH profiles, physical iPhone
coverage, or a broad release matrix. Fixed Apple selection remains unsupported;
changing DASH caps during a session still requires a fresh Load. The source
changes remain uncommitted for review.


## Final review fix: finite near-tail restoration

The final review identified an additional saved-position prerequisite: a finite
DASH item suspended within two seconds of its seekable end could inherit the
live-edge resume flag and skip the exact saved-position seek. The backend now
infers live-edge restoration only for non-DASH sources with explicit live intent
or a genuinely indefinite item duration. It clears that flag for finite sources
and when installing a static DASH catalog, so a stale flag cannot bypass the
saved microseconds. Existing explicit and duration-inferred live behavior remains
covered separately.

Both exact restoration regressions now use a finite 8.001-second item with a
populated seekable range and a later-Period boundary at 6,500,500 µs. They exercise
retained-asset and staged-loader restore, record the requested `CMTime`, apply it
as controlled measured time, and verify the low catalog with public position
6500 ms. A new live regression checks explicit live intent and indefinite-duration
sources retain a deferred edge seek and subsequently seek to the range end.
These are controlled native timeline/landing observations, not real-media
submillisecond landing or automatic ready-callback timing proof.

The final focused selection ran **12 passed / 0 failed / 0 skipped on each OS**,
macOS first, iOS Simulator second. It includes the previous 11-case restore/catalog
selection plus
`YlDashResourceLoaderTests/testLiveEdgeRestorationPreservesExplicitAndIndefiniteLiveBehavior()`.
Exact identities are in `/private/tmp/yl-dash-catalog-finalfix-selectors.json` and
both canonical result receipts:
`/private/tmp/yl-dash-catalog-finalfix-{macos,ios}-final-evidence/case-identities.json`.
Adjacent `summary.json` and `tests.json` preserve observed case identities/counts.
The earlier 79-case native, 11-case restore, and public batches were not rerun or
added to these counts. Public test source and compiler source/tests are unchanged
by this final wave. Final current native inventory is 583 iOS / 499 macOS.

The complete final-wave run history is qualified as follows:

| Bundle/log base in `/private/tmp` | Outcome and meaning |
|---|---|
| `yl-dash-catalog-finalfix-red` | 3 executed: live check passed; 2 near-tail cases failed during MPD preparation because the initial fixture used a segment duration inconsistent with its shortened Period. This was fixture setup failure, not behavioral RED. |
| `yl-dash-catalog-finalfix-macos-green` | 12 executed: 10 passed, the same 2 fixture preparation failures. Not claimed as GREEN. |
| `yl-dash-catalog-finalfix-behavior-red` | Corrected valid fixture against pre-wave production: 3 executed, live check passed, both finite restore routes failed because no saved-position seek was issued (`requestedSeek` was nil). This is behavioral RED. |
| `yl-dash-catalog-finalfix-macos-final` | 12 passed, no failures/skips after the gate fix. |
| `yl-dash-catalog-finalfix-ios-final` | Same final 12 passed, no failures/skips. |

Each base has `.xcresult` and `.log` artifacts; raw preliminary/RED
`-evidence/{summary,tests}.json` records are retained. Both successful receipts
were checked against the canonical identities by the existing inventory tool.
The final exact xcodebuild invocations ran from the repository root:

```sh
xcodebuild test -quiet -parallel-testing-enabled NO -workspace packages/yl_player/example/macos/Runner.xcworkspace -scheme Runner -sdk macosx -destination 'platform=macOS,arch=arm64' -derivedDataPath packages/yl_player/example/build/native-macos-tests -resultBundlePath /private/tmp/yl-dash-catalog-finalfix-behavior-red.xcresult -only-testing:RunnerTests/YlDashResourceLoaderTests/testCatalogRetainedReplacementRestoreSeeksExactFractionalBoundary -only-testing:RunnerTests/YlDashResourceLoaderTests/testCatalogStagedLoaderRestoreSeeksExactFractionalBoundary -only-testing:RunnerTests/YlDashResourceLoaderTests/testLiveEdgeRestorationPreservesExplicitAndIndefiniteLiveBehavior > /private/tmp/yl-dash-catalog-finalfix-behavior-red.log 2>&1
xcodebuild test -quiet -parallel-testing-enabled NO -workspace packages/yl_player/example/macos/Runner.xcworkspace -scheme Runner -sdk macosx -destination platform=macOS,arch=arm64 -derivedDataPath packages/yl_player/example/build/native-macos-tests -resultBundlePath /private/tmp/yl-dash-catalog-finalfix-macos-final.xcresult -only-testing:RunnerTests/YlDashResourceLoaderTests/testCatalogFollowsMeasuredProgramTimeAndPeriodicPublication -only-testing:RunnerTests/YlDashResourceLoaderTests/testCatalogLoaderSnapshotSurvivesCancellationWhilePrivateSnapshotClears -only-testing:RunnerTests/YlDashResourceLoaderTests/testCatalogSeekUsesActualLandingAndRetiredCompletionCannotPublish -only-testing:RunnerTests/YlDashResourceLoaderTests/testCatalogMetadataIsolationOrdinarySourceAndSavedPositionRestoration -only-testing:RunnerTests/YlDashResourceLoaderTests/testCatalogBackendSubMillisecondBoundaryAndInvalidClockAreSafe -only-testing:RunnerTests/YlDashResourceLoaderTests/testCatalogRetainedReplacementRestoreSeeksExactFractionalBoundary -only-testing:RunnerTests/YlDashResourceLoaderTests/testCatalogStagedLoaderRestoreSeeksExactFractionalBoundary -only-testing:RunnerTests/YlDashResourceLoaderTests/testHeaderedHlsRestoreKeepsLatestPreferencesWhileNewLoadKeepsCapturedTuple -only-testing:RunnerTests/YlDashResourceLoaderTests/testLoadCapsRuntimeMutationFailsBeforeAcceptedIntentAndSurvivesRestore -only-testing:RunnerTests/YlDashResourceLoaderTests/testCoordinatorKeepsDashSessionOnInvalidReplacementAndRebuildsPrivateAssetOnResume -only-testing:RunnerTests/YlDashResourceLoaderTests/testStopDuringMPDPreflightAllowsNewLoadAndIgnoresLateResponse -only-testing:RunnerTests/YlDashResourceLoaderTests/testLiveEdgeRestorationPreservesExplicitAndIndefiniteLiveBehavior > /private/tmp/yl-dash-catalog-finalfix-macos-final.log 2>&1
xcodebuild test -quiet -parallel-testing-enabled NO -workspace packages/yl_player/example/ios/Runner.xcworkspace -scheme Runner -sdk iphonesimulator -destination 'platform=iOS Simulator,id=A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6' -derivedDataPath packages/yl_player/example/build/native-ios-tests -resultBundlePath /private/tmp/yl-dash-catalog-finalfix-ios-final.xcresult -only-testing:RunnerTests/YlDashResourceLoaderTests/testCatalogFollowsMeasuredProgramTimeAndPeriodicPublication -only-testing:RunnerTests/YlDashResourceLoaderTests/testCatalogLoaderSnapshotSurvivesCancellationWhilePrivateSnapshotClears -only-testing:RunnerTests/YlDashResourceLoaderTests/testCatalogSeekUsesActualLandingAndRetiredCompletionCannotPublish -only-testing:RunnerTests/YlDashResourceLoaderTests/testCatalogMetadataIsolationOrdinarySourceAndSavedPositionRestoration -only-testing:RunnerTests/YlDashResourceLoaderTests/testCatalogBackendSubMillisecondBoundaryAndInvalidClockAreSafe -only-testing:RunnerTests/YlDashResourceLoaderTests/testCatalogRetainedReplacementRestoreSeeksExactFractionalBoundary -only-testing:RunnerTests/YlDashResourceLoaderTests/testCatalogStagedLoaderRestoreSeeksExactFractionalBoundary -only-testing:RunnerTests/YlDashResourceLoaderTests/testHeaderedHlsRestoreKeepsLatestPreferencesWhileNewLoadKeepsCapturedTuple -only-testing:RunnerTests/YlDashResourceLoaderTests/testLoadCapsRuntimeMutationFailsBeforeAcceptedIntentAndSurvivesRestore -only-testing:RunnerTests/YlDashResourceLoaderTests/testCoordinatorKeepsDashSessionOnInvalidReplacementAndRebuildsPrivateAssetOnResume -only-testing:RunnerTests/YlDashResourceLoaderTests/testStopDuringMPDPreflightAllowsNewLoadAndIgnoresLateResponse -only-testing:RunnerTests/YlDashResourceLoaderTests/testLiveEdgeRestorationPreservesExplicitAndIndefiniteLiveBehavior > /private/tmp/yl-dash-catalog-finalfix-ios-final.log 2>&1
```

Machine-readable argv is also preserved at
`/private/tmp/yl-dash-catalog-finalfix-{macos,ios}-final-command.json`.
Final source hashes and the unchanged original review-snapshot hash are recorded
in `/private/tmp/yl-dash-catalog-finalfix-source-hashes.json`. Current inventory,
canonical mirrors, and `git diff --check` pass. The existing iPhone 18 Pro simulator
was Shutdown before this wave, was booted only for its iOS run, and is Shutdown
again. All four `FLUTTER_TARGET` values remain `lib/main.dart`. Existing
Sendable/AnyHashable, mock URLSession deprecation/capture, XCTest deployment-link,
and always-run script warnings remain; no test skip is counted as a pass.
No full suite, compiler suite, or public playback acceptance rerun was required
for this narrowly scoped native lifecycle change. The previous public and
physical-device evidence limits still apply.

## Review closure

Task-scoped reviews and the whole-stage review are complete. The whole-stage
review found one finite near-tail restoration defect; the combined fix above
passed focused rereview with no remaining actionable findings. Source hashes,
canonical test mirrors, current inventory, generated Flutter targets and
simulator cleanup were independently checked. Prior-stage commit remains
`2aa997c`; this catalog stage is complete and remains uncommitted, with no push.
