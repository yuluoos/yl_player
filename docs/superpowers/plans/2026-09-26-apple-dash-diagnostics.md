# Apple DASH admission diagnostics implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox syntax for tracking.

**Goal:** Fulfil a bounded part of REQ-13: distinguish known Apple DASH admission failures without broadening media support or leaking source data.

**Architecture:** Preserve existing parser/compiler/loader admission gates. Only typed package-owned parser failures survive the compiler boundary; arbitrary callback errors retain the generic fallback. Native publication and shared Dart diagnostics replace all source prose with fixed guidance.

**Tech Stack:** Swift Foundation XMLParser, existing Apple native harness, Flutter/Dart.

**Spec:** ../specs/2026-09-20-playback-expansion-requirements.md (REQ-13, REG-DIAG, REG-LIFE). Continues user-authorized staged implementation. Baseline 685a22a; existing checkout and inline execution, one final independent review. This stage stays uncommitted.

## Global Constraints

- No commercial SDK, dependencies, deployment-floor change or wire-schema change.
- Preserve all admission limits, credential stripping, cancellation and failed-candidate rollback.
- Do not decide PD-02/03 or claim DRM support from an encryption declaration.
- Add exactly five code classifications; all other existing unsupported cases retain container.unsupported.
- Do not emit URL, XML, credentials, parser prose or source-provided code/message.

## Frozen classifications

| Code | Evidence / guidance |
|---|---|
| container.dash_manifest_invalid | Invalid UTF-8 or XML syntax; obtain a valid UTF-8 MPD from the provider. Not every unsupported semantic declaration is malformed. |
| container.dash_dynamic_unsupported | Parsed MPD type is dynamic; choose a static DASH VOD source. Unknown type remains generic. |
| container.dash_protection_unsupported | DASH/no-namespace ContentProtection element encountered; current Apple DASH path does not support this declaration; choose a compatible source. Do not claim a license failure. |
| container.dash_segment_base_unsupported | DASH/no-namespace SegmentBase encountered; choose a compatible SegmentTemplate or SegmentList presentation. |
| resource.dash_manifest_too_large | Existing exact 2 MiB input byte limit exceeded at compiler or network preflight; ask provider for a smaller manifest. Other resource budgets stay generic. |

All five are nonretryable; category container/resource respectively. Existing scope and diagnostic association remain authoritative. Foreign-namespace feature names and manually aborted unsupported XML must not be mislabeled as known DASH features or syntax errors.

## Review Focus

- Compiler catch-all must preserve only typed package classifications, never a code forged by media/manifest callbacks.
- Parser abort due to unsupported structure must remain distinct from malformed XML; namespace validation precedes feature classification.
- Input-byte limit must agree between direct compiler, declared Content-Length and streamed response paths; other budgets must not imply bytes exceeded.
- Failed candidate diagnostics must survive both native publication and Dart while accepted playback remains usable.
- Unknown type/root and DTD restrictions retain prior generic behavior; no support expansion or native prose leakage.

## Task 1: Classify, publish and verify admission failures

**Files:** YlDashDocument.swift/YlDashHlsCompiler.swift in Apple Shared/DASH; Shared/Diagnostics/YlAppleSafeDiagnostics.swift; shared Dart failure.dart/safe_diagnostics.dart; existing compiler/loader canonical tests and iOS/macOS mirrors; current new-tests-manifest.json/main_example_tests.py; Apple failure-message Dart tests; existing public apple_dash_playback_test.dart and new apple_dash_diagnostics_test.dart; support/report docs. No media/server changes.

**Interfaces:** Existing NativePlayerError → AppleFailureMessage → YlFailure; consumes existing compile/load APIs. Produces the five string codes above and fixed safe messages; no transport API changes.

- [x] Write compiler table-driven assertions for five reasons, no emitted media, public native code/category/retryability/guidance and no private source strings. Add foreign-namespace/manual-abort/unknown type and forged callback regression. Migrate existing assertions only where the reason changes.
```swift
XCTAssertThrowsError(try compile("<MPD type=\"dynamic\"/>")) {
  XCTAssertEqual(($0 as? NativePlayerError)?.code, "container.dash_dynamic_unsupported")
}
```
- [x] Add Dart known-code safe message tests; run before implementation. Run focused native compiler test before implementation using RunnerTests/YlDashHlsCompilerTests. Expected: assertions fail on container.unsupported/platform.failure/generic guidance, not compilation errors.
- [x] Add internal typed parser error with fixed native mapping; preserve it at compiler catch before generic callback sanitization. Set specific error only at proven conditions. Add native allowlist/messages and public Dart constants/messages.
```swift
// catch let error as YlDashAdmissionError { throw error.nativeError }
// catch { throw YlDashBounds.unsupported }
```
- [x] Migrate malformed loader/candidate expectations and verify native compiler+loader classes serially on macOS and iOS. Refresh only current mirrors/hashes/counts. Expected: exact selected XCTest identities all pass without skips.
- [x] Add public five-case rejected-load checks with credentials in URI/header/XML, fixed guidance and diagnostic ID, no media requests, then successful valid Load. Also run existing malformed replacement test for rollback. Run serial macOS/iOS. Expected: five rejection scenarios and existing rollback pass on both platforms.
- [x] Run Apple/controller/platform-interface Dart tests and targeted analyze, inventory validation and diff check. Expected: all pass. Restore four Flutter targets and simulator; record exact runs, warning/coverage limits, update support/architecture and write report.
- [x] Final independent review of stage diff, address concrete blocking findings, leave stage uncommitted.
