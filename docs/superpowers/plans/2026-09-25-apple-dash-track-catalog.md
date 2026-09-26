# Apple DASH track catalog Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development. User explicitly authorized commit then next stage; reuse existing `codex/fel-integration` checkout, baseline `2aa997c`. No new approval pause, no automatic commit/push for this new stage; native/build lane serial.

**Goal:** Publish a truthful, stable current-Period DASH video catalog through the existing Apple track state.

**Architecture:** Retain validated microsecond Period bounds → immutable effective catalog in compiler/loader → installed backend refresh from actual playback time. AVAsset metadata remains geometry/audio authority without overwriting DASH catalog.

**Tech Stack:** Existing Swift/AVFoundation + Flutter/Dart, no dependencies.

**Spec:** `docs/superpowers/specs/2026-09-25-apple-dash-track-catalog-design.md`

## Global Constraints

- iOS15/macOS12, Apple schema3/Android schema4/SPI2 unchanged; no commercialSDK/newwire.
- Existing static clear AVC/AAC domain, parser/proxy/registry budgets/credentials/caps enforced unchanged.
- Catalog is accepted projection currentPeriod; numeric stableIDs, MPD video bitrate, allDASH isSelected=false, automatic/initial unchanged.
- RuntimeDASH caps still reload-required; fixedunsupported; no claim of actual selectedbitrate or fullABR.
- Keep ordinary HLS/MP4 behavior and finalHLS restoration preferencefix from2aa997c.

## Review Focus

- Late AV metadata cannot replace MPDcatalog or publish retireditem data.
- Exact boundaries/fractional times/paused seek cannot leave previousPeriod metadata attached to newposition.
- Failed/cancelled candidate and Stop retain/clear only correct session catalog.
- Preserving legacy singleton varyingbandwidth and duplicatequality display must not reject previously accepted inputs.
- Per-tick updates must not spam tracksChanged; any complete state has coherent position/catalog.

## Task 1: Native catalog, lifecycle and regression evidence

**Files:** existing Shared/DASH/YlDashDocument.swift and YlDashHlsCompiler.swift; Shared/HLS/YlHlsResourceLoader.swift; Engines/AvPlayer/YlAvPlayerBackend.swift under packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple. Internal catalog type may stay alongside compiler or new focused DASH file if include validation is explicit. Tests canonical tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashHlsCompilerTests.swift and YlDashResourceLoaderTests.swift, matching example ios/macos mirrors; current main_example_tests.py/new-tests-manifest.json only. No public Dart API/schema changes.

**Interfaces:** immutable internal `YlDashVideoCatalog` queried by `tracks(at positionUs: Int64) -> [YlNativeTrack]`; presentation owns `videoCatalog`, loader exposes safe snapshot, backend owns installed snapshot. Period adds exact `startUs/endUs` preserved during filtering. Existing public videoTracks wire fields used unchanged.

- [x] Add compiler regression for multiPeriod catalog / cap / identity and microsecondlookup, prove representative behavior RED before implementing.
```swift
// Exact IDs, e.g. dash-video-w320-h180-b350000.
// catalog.tracks(at: 3_999_999) => Period0; at4_000_000 => Period1.
// For boundary4_000_500: at4_000_499 old, at4_000_500 new (no milliseconds truncation).
// Reordered IDs/XML have same numeric IDs; video bitrate350000 excludes audio64000.
```
- [x] Retain validated bounds, build effective catalog, carry via compiler/loader; retain safe budgets/admission and no sensitiveIDs/labels. Samequalitytuple dedup only display, not compiledmedia changes.
- [x] Wire backend installedcatalog into fullstate/periodictimeline/actualseek path. Prevent asynchronous AVmetadata overwrite and oldgeneration effects; update only on catalog differences; preserve savedposition lifecycle. AllDASH isSelectedfalse; ordinarysources unchanged.
```swift
// Controlled AVPlayer currentTime + production emitState/emitStateDelta path:
// t=1 => high, prefetch/no timeadvance => high, t=5 => low; pausedseek measuredtime=>newcatalog.
// sameperiod repeatedticks => no extra tracksChanged.
// newcandidate failure => old catalog; Stop/newMP4 => no dash-video IDs.
```
- [x] Meaningful loader/backend regressions including cancellation/restoration, stale metadata, late candidate, ordinarysource preservation; native relevant compiler/loader suites bothOS serial. Update canonical mirrors/current inventory, record exact selectors/counts/commands/logs and warnings, no unrelated matrix.
- [x] Selfreview, report Task1 to root, independenttaskreview/fixes. No commit; preserve evidence.

## Task 2: Public current-Period catalog acceptance and docs

**Files:** create packages/yl_player/example/integration_test/apple_dash_track_catalog_test.dart; minimal existing support/dash_server.dart only if needed; update docs/platform-support.md and create docs/superpowers/reports/2026-09-25-apple-dash-track-catalog.md. Root owns plan/spec/architecture.

**Interfaces:** existing `state.videoTracks` YlMediaTrack fields; `state.videoSelection` automatic/initial; DashServer.start(variants:true,manifestOverride:...). Same source fixtures32 media bytes, eightsecond/twofoursecondPeriods. No new assetbytes.

- [x] Three spec publiccases in singlefile: samecatalog reordered multiPeriod + completion; high→low natural+seekback/forward; strictcapcatalog + failedcandidatepreservation + Stopempty. Bind every state/event tosessionID; inspect actual dimensions/positions. Check exact numeric IDs and video bitrate, codec, allDASHfalse. Explicitdash andautomatic both.
```dart
// current catalog (w,h,bitrate): [(320,180,350000),(640,360,700000)]
// high→low sample natural pos>4500ms, seek1 sample1500<pos<4000; seek5 sample5500<pos<8000.
// failed high→low cap180 => qualityConstraintUnsupported, candidateMediaRequests0.
// automatic + initial and catalog equality asserted at each checkpoint.
```
- [x] Review all assertions before final runs; format/analyze target, verify unchanged media manifest/hashes, public3case file macOS theniOS. Record commands/logs/observations/warnings; restore simulatorinitialstate and fourFLUTTER_TARGET=lib/main.dart. Any nativebug report to root, do not silently amend nativeownership.
- [x] Document true catalog meaning and selectedunknown, admitted source boundaries/no broader fixedABRclaim, exact native/public separate evidence; base2aa997c committed, newstageuncommitted. Independenttaskreview and finalreview; no auto commit.
