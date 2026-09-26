# Apple DASH runtime caps Implementation Plan

> Use superpowers:subagent-driven-development. User authorized commit then next stage; existing codex/fel-integration workspace, baseline b44d95e. Continue without another approval pause. No auto commit/push of this stage. Native/build lane serial.

**Goal:** Change active Apple static DASH caps transactionally through the existing public Future.
**Architecture:** Retain accepted bounded original manifest snapshot; asynchronous compile/preparation with separate cancellation authority; main-turn backend replacement at latest measured position; await actual commit in Pigeon host.
**Tech Stack:** Existing Swift/AVFoundation/Dart/Pigeon, no dependencies.
**Spec:** docs/superpowers/specs/2026-09-26-apple-dash-runtime-caps-design.md

## Global Constraints

- No commercial SDK, new media, dependency or deployment-floor change. Existing wire fields/schema unchanged unless source proves necessary and root records decision.
- Public identity stable. Available catalog unselected, automatic/initial. Fixed/PD01 not enabled.
- Failed preparation leaves accepted item/policy/state/output unchanged; completion means installation commit, not first frame. Post-commit failures ordinary playback failures.
- Compile original accepted immutable MPD snapshot, never refetch or compile only filtered candidates. Preserve budgets/credential provenance/output constraints.
- Latest cap request wins; pending Load wins over caps; Stop/dispose/deactivate cancel; transport commands during prepare remain effective. Inactive changed caps explicitly reload-required.

## Review Focus

- Clearing caps restores original candidates across all Periods and restoration; no server refetch drift.
- Acknowledgment/accepted policy cannot outrun asynchronous failures or canceled generation.
- Seek/pause during preparation, exact boundary and near-tail resume must preserve latest intent.
- Old item callbacks, texture frames and metadata cannot escape accepted generation during replacement.
- Candidate cleanup, credential provenance, opaque retention budgets, pending Load and inactive restoration must preserve previous guarantees.

## Task 1: Native transaction and awaited transport

**Files:** Shared/HLS/YlHlsResourceLoader.swift; Engines/AvPlayer/YlAvPlayerBackend.swift; Shared/Session/YlAppleSessionCoordinator.swift and YlApplePlayerHost.swift under packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple; related prepared HLS type only where needed. packages/yl_player_apple/pigeons/yl_player_apple.dart and generated Dart/Swift via tool/generate_pigeon.sh. Canonical tool/consumer_fixtures/apple_flutter/RunnerTests tests + existing example ios/macos mirrors; current main_example_tests.py/new-tests-manifest.json, and current allowed-hardware-skips.json source hash only when async host call migration changes its fingerprinted shared test (no skip rule/count changes). Necessary existing Swift host constraint callsites become try await; target Dart transport tests if completion behavior needs coverage. No public playback test/docs ownership.

**Interfaces:** existing public Future<void> setVideoConstraints and source schema. Internally snapshot is immutable bounded original MPD Data/effectiveURL; loader preparation consumes optional snapshot. Coordinator owns separate pending-cap generation/token; backend installs a prepared DASH item using current exact time/intent. Names internal to task, document report for Task2.

- [x] Behavioral RED for host/coordinator runtime cap change previously rejected; snapshot clear restores originals; async completion failure must be awaited.
```swift
// Load accepted low-only caps, change/clear through host; same identity.
// Change to impossible cap -> throws quality error, old player.currentItem unchanged.
// Hold preparation, then seek/pause, release: current-time/paused intent wins.
// Pending caps A -> B/no-op: A canceled once, accepted policy only B.
```
- [x] Implement bounded snapshot/recompile, independent cancellation lifecycle, backend exact-time replacement, async host/bridge and success-only accepted policy.
```swift
// Capture source+accepted snapshot on main; compile on bounded existing worker queue.
// Before commit verify identity/generation/current active backend and token.
// Capture latest time/intent at installation, then commit accepted policy.
```
- [x] Cover spec failure/clear/restoration/cancel/Load priority/output/ordinarysource risks in production-wired tests; update affected reload-only tests. Use existing test scheduling seams or minimal injectable preparation seam, no production-only bypass.
- [x] Run pinned Pigeon generation/drift, target Dart checks, native relevant suites both OS serial. Canonical mirrors/current inventory synchronized, no historical manifest rewrite. Record exact commands/selectors/results/source hashes and all limitations; restore environment.
- [x] Selfreview/frozen task report and task-scoped independent review; no commit.

## Task 2: Public playback acceptance and support docs

**Files:** new packages/yl_player/example/integration_test/apple_dash_runtime_caps_test.dart, minimal support/dash_server.dart extension if needed; update affected existing apple_dash_load_caps_test.dart reload-only assertions; docs/platform-support.md and new docs/superpowers/reports/2026-09-26-apple-dash-runtime-caps.md. Root owns spec/plan/architecture.

**Interfaces:** existing await session.setVideoConstraints; same session.id. Task1 report describes boundary and native tests. Existing two-quality/high-to-low fixture width320/640,height180/360,bitrate350000/700000; cap tuple320/180/350000.

- [x] Add real playback scenarios matching spec, measured progress and catalogs, no MPD refetch, Future failure, retained session and paused intent; public identity every emitted state. Explicit/automatic DASH routes.
```dart
// await session.setVideoConstraints(lowCaps); same ID and only low catalog;
// await session.setVideoConstraints(YlVideoConstraints()); both original IDs;
// impossible cap failure leaves accepted catalog and continuing progress.
```
- [x] Run target format/analyze and new/affected public cases macOS then iOS, serial. Reuse existing media bytes. Inspect all observations, no fixed/selected bitrate/seamless claim. Restore targets/simulator.
- [x] Tracked report self-contained commands/logs/counts/warnings/failure history and limits; support docs active/inactive behavior accurate. Independent task review then root final stage review. No commit.
