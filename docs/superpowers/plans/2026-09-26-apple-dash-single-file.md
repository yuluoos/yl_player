# Apple DASH single-file SegmentList implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline, with one final independent review. Continue the user's approved staged implementation.

**Goal:** Play existing supported static AVC/AAC DASH when SegmentList initialization/media references are omitted or empty and resolve to inherited BaseURL.
**Architecture:** Resolve the empty reference to the already validated effective base and pass through existing resource recording, URI budget, sticky credential stripping and byte-range validation. Retain existing HLS projection and controlled range loader.
**Tech Stack:** Swift, AVPlayer, Dart/Flutter integration fixture.
**Spec:** ../specs/2026-09-20-playback-expansion-requirements.md (REQ-02/04, CAP-DASH; current network/decoder/resource constraints).

## Global constraints

No commercial SDK, dependency/deployment/public API change. Existing clear static AVC/AAC and full-segment/common-origin rules remain. No SegmentBase/sidx discovery, DRM, subtitle, new codec or PD-02/03 decision. Keep strict network/decoder/cache policies. No push; new stage remains uncommitted.

## Design and review focus

Omitted/empty URL is a base reference, not a path guessed from a file extension. Preserve final-redirect URL/query and nearest inherited BaseURL. Record every resource before HLS emission to retain URI budgets and sticky credential policy. Invalid ranges/unsafe URLs must still reject before any media emission. Explicit nonempty references remain unchanged. Public evidence must use actual single-file media and HTTP Range, not merely HLS text.

Source basis: [Shaka initialization reference resolution](https://shaka-project.github.io/shaka-player/docs/api/lib_dash_segment_base.js.html), [SegmentList resolution](https://shaka-project.github.io/shaka-player/docs/api/lib_dash_segment_list.js.html). These are interoperability references, not claims of complete DASH conformance.

## Task 1: Resource reference resolution

Files: YlDashDocument.swift; canonical YlDashHlsCompilerTests.swift plus two current example mirrors; current main_example_tests.py/new-tests-manifest.json inventory.
Interface: private resource(_:_:_:) keeps its signature and returns validated YlDashResource.

- [x] Add tests for omitted and empty sourceURL/media with inherited base and exact HLS ranges, fallback to redirected document URL/query, cross-origin-return sticky stripping, malformed ranges/unsafe base rejection before emission.
```swift
// BaseURL=all.m4s?token=one, Initialization range=0-99,
// SegmentURL mediaRange=100-199 / 200-399 => same URL and 100@0/100@100/200@200.
```
- [x] Run new native methods on macOS against old code; acceptance fails with container.unsupported.
- [x] Implement empty-reference fallback through record, never bypass range validation.
```swift
let reference = (name == nil || name == "") ? location.0.absoluteString : name!
```
- [x] Refresh current mirrors/inventory only. Run full compiler+loader methods on macOS then iOS, verify actual xcresult case identities and no skips.

## Task 2: Real single-file playback and retained request policy

Files: test-only dash_single_file_fixture.dart and unit test; dash_server.dart option; apple_dash_single_file_test.dart; support table/report/architecture.
Interface: packDashSingleFile(manifest, files) returns (manifest, files), consuming the existing owned shifted SegmentList fixture; production never packs media.

- [x] Unit test exact packed bytes, init/media ranges, empty URLs, preserved source, then implement helper. Reuse existing actual shifted fixture (10/30s origins), preserve timeline. One file per rendition per Period.
```dart
// init=[1,2], segments=[3,4,5],[6] => [1,2,3,4,5,6], ranges0-1,2-4,5-5.
```
- [x] Serve with singleFileSegmentList option. Run same-origin and cross-origin public cases: first frame/program8s, fixed high natural transition, seek5/1, same session, selected AAC, completion and no failure; require actual closed byte-range requests for video/audio files in both Periods and correct credentials. Existing origin/header policy unchanged.
- [x] Run example unit suite/analyze and public macOS then iOS, capture warnings/failures/source hashes. Restore Flutter targets and simulator. Update bounded docs and perform one independent final review. No commit/push of new stage.
