# Apple DASH finite final-Period duration implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline and one final independent review; ongoing user-authorized staged implementation.

**Goal:** Accept an otherwise supported static final Period without an MPD/Period duration when every original representation has the same exact finite SegmentTimeline duration.
**Architecture:** Keep declared Period duration, next explicit start and MPD total authoritative. Only a final undelimited Period may infer an exact microsecond duration from inherited finite timelines. Share segment inheritance and bounded timeline-run parsing with normal expansion, so inferred admission cannot diverge from emitted media.
**Tech Stack:** Swift/AVPlayer and Flutter integration.
**Spec:** ../specs/2026-09-20-playback-expansion-requirements.md REQ-02/04/05 and CAP-PERIOD duration-unknown dimension.

## Global constraints

No commercial SDK/dependency/public API/deployment-floor change. Preserve clear static AVC/AAC, common per-Period origin, complete segment windows, all original candidate validation before caps/fixed pruning, strict request/decoder/cache policy. PD-02/03 remain undecided. No push; stage remains uncommitted.

This is a deliberately bounded compatibility fallback. DASH-IF restricted timing guidance requires last Period duration; do not describe this fallback as compliance with that restricted profile. No inference for an undelimited non-final Period, duration-only addressing, divergent tracks, fractional microsecond duration or a trailing unbounded r=-1. An internal r=-1 is finite only with explicit next S@t.

## Review focus

Declared timing must never be silently replaced. All original audio/video candidates must agree before pruning. Inheritance must match normal segment construction. Checked arithmetic and segment budget must precede expansion. Actual playback must expose the correct inferred program duration, seek and natural transition; tests cannot fabricate a total in a server path.

## Task 1: Shared bounded timing and final duration

Files: Shared/DASH/YlDashDocument.swift; canonical YlDashHlsCompilerTests and both example mirrors; current inventory only.
Interfaces: private segmentInfo(ancestors) gives effective mode/attributes/timeline/init/URLs; timelineRuns(timeline, offset, end?) gives checked finite (start,duration,count) runs; inferredDuration(root,period) computes one exact shared duration. No public API.

- [x] Add native RED cases: inherited PTO finite final timeline, two-Period absent total/final duration, SegmentList equal rational video/audio duration; rejection of unbounded tail/gap/overflow/noninteger microseconds/duration-only/unknown non-final and mismatched hidden rendition.
```swift
// Period0=4s; final PTO100/scale10 S(t100,d20,r1) => total8s.
// finite internal r=-1 followed by t120,d20 is equivalent; tail r=-1 has no end.
```
- [x] Run new methods on macOS against old implementation, expect acceptance failure.
- [x] Extract existing inheritance/timeline checks into private shared helpers. Infer only missing final duration, preserving declared precedence; compare all original normalized durations, exact microseconds and aggregate segment limit.
```swift
// end=nil: last r=-1 rejects; end!=nil: exact complete window required.
// candidateUs=(cursor-offset)*1_000_000/scale, divisible and checked.
```
- [x] Update current mirrors/inventory; run complete compiler/loader classes on macOS then iOS and verify actual result identities.

## Task 2: Real playback and supported-boundary evidence

Files: dash_server.dart test option, apple_dash_inferred_duration_test.dart, docs support/architecture/report.
Interface: omitFinalDuration flag removes MPD total and final Period duration from the existing actual shifted fixtures. It preserves first duration and both starts, and works with Time template or single-file SegmentList.

- [x] Unit-test the manifest transformation with literal XML including unrelated SegmentTemplate duration; then implement exact test-only transformation.
```dart
// MPD total8 + Period0 duration4 + Period1 duration4 -> only first duration4 remains.
```
- [x] Public Time-template and single-file SegmentList cases:8s program, real fixed640 cross-Period output, seek5/1, auto320 caps, malformed unbounded candidate rollback, completion and no failures. Assert served root manifest actually omits final/MPD duration and real child media requests occur both Periods.
- [x] Run example tests/analyze and public macOS then iOS. Record all failures/warnings, freeze source hashes, restore generated targets/simulator, update bounded docs and final independent review. No automatic commit/push.
