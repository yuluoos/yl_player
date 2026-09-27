# Apple DASH aligned presentation offsets implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Execute inline with one final independent review; leave this stage uncommitted.

**Goal:** Extend the existing static AVC/AAC DASH adapter to full-segment-aligned nonzero presentationTimeOffset without changing public APIs.

**Architecture:** Keep sample timestamps for segment addressing and normalize only the admitted segment window. HLS continues to use exact segment durations and Period discontinuities; no compressed media rewriting in production. Within each Period, all video/audio offsets must represent the same rational time so the existing HLS rendition timestamps remain aligned.

**Tech Stack:** Swift bounded DASH parser/compiler; Dart controlled media server/public playback; existing XCTest runner.

**Spec:** ../specs/2026-09-20-playback-expansion-requirements.md REQ-02/04/05, CAP-DASH/PERIOD, REG-LIFE/REQ. Baseline f88f993. User has authorized staged implementation in the existing codex/fel-integration checkout.

## Global Constraints

- No SDK/dependency/deployment/schema/public API changes; preserve original fixture bytes.
- Existing clear static AVC/AAC compatibility, credentials, bounds, fixed-selection/caps and lifecycle policies remain unchanged.
- Admit nonnegative integer PTO only with explicit SegmentTimeline whose first effective t equals PTO and whose contiguous full segments end at PTO + Period duration in timescale units. Missing first S@t means zero, not PTO.
- Support SegmentTemplate $Time$/$Number$ and SegmentList timelines; unshifted media timestamps remain the URL substitution values. Positive/negative repeats retain finite bounds and exact divisibility.
- Nonzero PTO without a timeline, partial segments, gaps/overlaps, negative/overflow/unknown values and different rational offsets among any rendition/audio remain unsupported.
- Normalize offset comparisons by integer reduction, never floating point or overflowing cross multiplication. Offsets may change across Periods.
- All rejected manifests fail before media emission and retain safe errors. Zero-offset behavior remains unchanged.

## Source basis

[DASH-IF timing model](https://dashif.org/Guidelines-TimingModel/): MPD time = Period start + (sample time − PTO) / timescale; absent first S@t is zero, $Time$ addresses sample timeline. [RFC 8216](https://www.rfc-editor.org/rfc/rfc8216.html): matching rendition timestamps and discontinuities synchronize HLS. This stage admits a common origin and complete segments; it does not claim general editorial clipping or measured lip-sync accuracy.

## Review Focus

- First absent t must not be silently reinterpreted as offset; $Time$ must never use normalized zero.
- PTO+duration and r=-1 expansion need overflow/divisibility/budget checks before allocation.
- All original candidates/audio must share rational origin before caps/fixed pruning, including different timescales and huge offsets.
- Real shifted tfdt/sidx media must play on program time across Periods; a manifest-only offset test is insufficient.
- Fixed selection, caps reprojection and seek must preserve timeline/identity; invalid offset candidate must not retire accepted playback.

## Task 1: Bounded parser and native behavior

**Files:** Shared/DASH/YlDashDocument.swift; canonical YlDashHlsCompilerTests.swift and mirrored iOS/macOS files; current inventory/manifests only.
**Interfaces:** internal YlDashTrack offset origin added; compiler public presentation/caps/selection contract unchanged.

- [x] Add RED tests: nonzero $Time$ with repeats and inherited PTO; SegmentList byte ranges; equal rational offsets at different scales; cross-Period origins; all unsupported boundaries and caps hiding mismatched candidates.
```swift
// PTO=100, scale=10, Period=4s, S(t:100,d:20,r:1)
// requests 100.m4s and 120.m4s, EXTINF 2+2, program period 0..4s.
```
- [x] Run the new native selectors on macOS before implementation. Expected: acceptance tests fail with container.unsupported, refusal cases keep failing safely.
- [x] Parse PTO, calculate checked sample end=offset+durationTicks, admit only exact contiguous windows; add reduced rational origin to each track and validate complete Period before emitting URLs. Keep no-timeline zero route unchanged.
- [x] Update current test mirrors/hash/counts; run full compiler+loader classes macOS then iOS. Expected: all named methods pass, no skip, verified actual case identities.

## Task 2: Actual shifted media and public evidence

**Files:** new test-only support/dash_offset_fixture.dart and support helper unit tests, existing support/dash_server.dart, new integration_test/apple_dash_offsets_test.dart, docs/platform-support.md, architecture entry and stage report. Original asset/media bytes stay unchanged.
**Interfaces:** test helper transforms owned fixture copies: per-Period offsets 10/30 seconds, tfdt/sidx timestamps and MPD timeline/addressing together; existing server default behavior unchanged.

- [x] Implement a bounded known-fixture transformer with direct tests: inspect exact tfdt/sidx shift, reject truncated/unknown-version/overflow boxes, leave initialization and mdat unchanged, preserve source bytes. RED before implementation.
```dart
// transform known fixture copy; first video tfdt becomes 122880 ticks
// and audio becomes 480000 ticks at Period0, both representing 10 seconds.
```
- [x] Serve transformed two-Period variants using $Time$ addressing and transformed same media with SegmentList. Run actual public playback: first frame near program zero, 8s duration, natural transition, seeks5→1, fixed high/auto/caps and malformed-offset candidate rollback; require continued progress and same session identity. Audit media requests and selected AAC; do not equate metadata with quantitative lip sync.
- [x] Run helper unit tests/analyze, public macOS then iOS serially. Record commands, exact results, failures/warnings and source hashes; restore four Flutter targets and simulator.
- [x] Update bounded support/docs/report and final independent review. No automatic commit/push.
