# Apple DASH fixed selection Implementation Plan

> Use superpowers:subagent-driven-development. Continue the existing authorized codex/fel-integration checkout. User authorized commit then next stage; previous stage committed f3b2cd3. No new-stage commit/push. Native and public build lanes serial.

**Goal:** Deliver actual Apple DASH fixed rendition selection and observable sticky PD-01 automatic fallback through the existing public API.
**Architecture:** Extend strict MPD projection with semantic fixed identity and an available catalog separate from projected media paths. Coordinate fixed/auto/caps and missing-Period transitions with snapshot-based asynchronous installation; preserve actual transport and current-Period authority.
**Tech Stack:** Existing Swift/AVFoundation, Dart/Pigeon, Flutter integration fixtures.
**Spec:** docs/superpowers/specs/2026-09-26-apple-dash-fixed-selection-design.md

## Global Constraints

- No commercial SDK, dependency, media-byte or deployment-floor change. No Android edits. SPI major 2; Apple wire schema 3→4 with old factory tags preserved.
- Fixed media candidates must be exact semantic identity, never just AVPlayer preferences. Catalog remains allowed current-Period candidates; selected mode is separate from measured output.
- Missing current-Period quality means sticky automatic/trackUnavailable; prefetch, bandwidth shortage and transient metadata do not. Caps/decoder/output restrictions remain.
- Original admitted MPD snapshot/provenance only, no refetch; prepare failure preserves accepted playback. Same public identity, exact latest transport intent; Future means installation commit, not first frame.
- New Load priority, shared command supersession, lifecycle cancellation, old callback isolation. Inactive/restoring changed selection explicitly rejected.
- Preserve canonical mirrors/current inventory; historical manifests unchanged. Report limitations and warning noise honestly. No auto commit/push.

## Review Focus

- Sticky fallback must remove effective fixed filtering for a later backward seek, not only change the public label.
- Prefetch and unresolved seek targets cannot be mistaken for measured current Period; frame publication and mode must align.
- Cap/fixed/auto transactions cannot restore a retired policy when preparation or restoration completes late.
- Public ID collisions in legacy admitted catalogs must reject ambiguity before fixed enforcement, without making automatic admission stricter.
- Schema mismatch must remain reachable from genuine old codec-tag factory requests and malformed selection must fail safely.

## Task 1: Native fixed policy, lifecycle and Apple transport

**Files:** packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/DASH/YlDashHlsCompiler.swift, YlDashDocument.swift if identity parsing needs it; Shared/HLS/YlHlsResourceLoader.swift; Engines/AvPlayer/YlAvPlayerBackend.swift; Shared/Session/YlAppleSessionCoordinator.swift, YlApplePlayerHost.swift, YlApplePlayerRegistry.swift, YlAppleSessionModels.swift; small focused new DASH selection type if needed. packages/yl_player_apple/pigeons/yl_player_apple.dart; generated Swift/Dart; lib/src/apple_player.dart, apple_transport.dart, apple_codec.dart; targeted package tests/stubs. Canonical tool/consumer_fixtures/apple_flutter tests + existing iOS/macOS mirrors, current main_example_tests.py/new-tests-manifest.json and exact changed source hashes in allowed-hardware-skips.json only. Necessary schema-4 fixtures across Apple tests; focused packages/yl_player_platform_interface/lib/src/diagnostics/safe_diagnostics.dart mapping and its test for source.seek_failed if absent, no unrelated edits.

**Interfaces:** consumes existing public selectVideoTrack(String?) and YlVideoSelection/optional SPI; produces Apple implementation of that same contract and full-state wire selection. Native names internal; document them for Task2. Root owns spec/plan; Task2 owns integration tests/support docs/tracked report.

- [x] Write behavioral RED tests demonstrating unsupported Apple command, no fixed projection, missing selection in wire or lost fixed lifecycle. Run focused tests before implementing.
```swift
// Accepted two-quality static DASH: select high through host; media paths contain
// high only in matching Periods, current public catalog still includes low/high.
// Reordered IDs preserve semantic fixed; confirmed missing current Period returns
// auto/trackUnavailable and seeking back no longer uses fixed-only projection.
```
- [x] Implement strict semantic resolution, real fixed projection, truthful catalog/mode and transaction reconciliation per spec. Use existing caps transaction infrastructure; include backward seeks and automatic reprojection failure explicitly.
```swift
// Prepare from accepted original snapshot; validate latest policy and period at
// commit. Reconcile transport changes; install and accept policy atomically.
// Fixed high + low-only cap => command failure; old accepted item/mode untouched.
```
- [x] Add awaited Pigeon nullable-ID command and selection state, schema4 handshake and optional Dart selection SPI. Append new wire classes; regenerate pinned tool, preserve old factory codec tags and existing enum ordinals.
```dart
// Native completion held => selectVideoTrack Future remains pending.
// Native error completes Future as safe command failure.
// Full state fixed->delta keeps selection; malformed reason/absent schema4 data fails.
```
- [x] Cover all Review Focus and lifecycle cases with production-wired native tests: latest seek/pause, fixed/auto/caps/no-op supersession, pending Load priority, failed prepare, inactive rejection, restoration, Stop/new Load, stale completions, current vs prefetched Period. Exercise automatic non-DASH compatibility and ambiguity rejection.
- [x] Run target Dart test/analyze, pinned repeated-generation drift, native relevant DASH/host/schema tests macOS then iOS serial. Expected: named tests pass with exact case identities, no unreported skips; mirror/current inventory verifies. Capture all commands/receipts and original vs final hashes. Restore targets/simulator.
- [x] Self-review and freeze task report; independent task review. No commit.

## Task 2: Public playback and support evidence

**Files:** new packages/yl_player/example/integration_test/apple_dash_fixed_selection_test.dart; minimal existing support/dash_server.dart additions only if necessary; any affected Apple prior unsupported assertions in integration tests; docs/platform-support.md; docs/transport-compatibility.md current Apple schema statements; new docs/superpowers/reports/2026-09-26-apple-dash-fixed-selection.md.

**Interfaces:** same await session.selectVideoTrack(idOrNull); authoritative state.videoSelection with initial/user/trackUnavailable; catalogs from Task1 report. Existing DASH variants: 320x180/350000 low and 640x360/700000 high, 4s each Period, same media bytes.

- [x] Add three concrete public playback scenarios with all-state consistency audits, actual geometry/continued progress, same session/root count: stable fixed high across ID/order changes then auto/low; cap conflict retains high and later user auto permits low cap; missing high naturally enters low and sticky auto then backward seek/Stop.
```dart
// await session.selectVideoTrack(high.id);
// wait for fixed/high ID + actual videoGeometry 640x360 + measured progress;
// missing high => auto/trackUnavailable + 320x180; seek backwards stays auto.
// every emitted fixed state contains its fixedTrackId in videoTracks.
```
- [x] Run format/analyze then new/affected public tests macOS then iOS serial. Expected: all named scenarios pass; measured sizes and states recorded rather than inferring decoded bitrate. Use existing media; manifest-only longer program allowed. Restore four Flutter targets and simulator.
- [x] Write self-contained tracked evidence with exact commands/results/failures/warnings and limits from both tasks; update support docs and stale current unsupported claims. Independent task review then root final whole-stage review. No commit.
