# AirPlay Video Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans; independent Dart and remux modules use superpowers:dispatching-parallel-agents. Steps use checkbox syntax.

**Goal:** Opt-in AirPlay video with AVPlayer and compatible custom-source remux.
**Architecture:** Optional versioned channel preserves schema 7 and existing load ACK barriers. Native source admission selects direct AVPlayer or retained bounded HLS remux output. System route picker owns device selection.
**Tech Stack:** Flutter/Dart, Swift, AVFoundation/AVKit, Network, existing FFmpeg demux bridge.
**Spec:** `docs/superpowers/specs/2026-10-19-airplay-video-design.md`

## Global Constraints

- iOS 15/macOS 12; no runtime ffmpeg command dependency or private AirPlay APIs.
- Existing loads unchanged; unsupported policies rejected before replacement.
- No false local first-frame event or physical-device acceptance claim.

## Review Focus

- Replaced/stopped session callbacks cannot revive external playback state.
- Background/route disconnect and audio interruptions preserve intended pause.
- Failed/cancelled remux cleans resources and preserves accepted playback.
- HTTP traversal, missing capability, range abuse and slow clients stay bounded.
- Header/DRM/strict-policy sources cannot silently bypass original guarantees.

### Task 1: Public API and route picker

Files: platform interface load options/new AirPlay SPI; controller, ApplePlayer,
new Dart AirPlay channel and button; related Dart tests.
Interface: side channel `dev.ylplayer.airplay.<suffix>` with generated schema-7
codec; state/assess/load return `{value: ...}` or `{error: AppleFailureMessage}`.
State events use standard codec on `dev.ylplayer.airplay.events.<suffix>`.
- [x] Tests for unsupported adapter, load ACK, stale events and UI gating fail.
- [x] Implement opt-in delegation, state ownership and native picker widget.
- [x] Run affected package Flutter suites and analysis.

### Task 2: Bounded remux

Files: new `Shared/AirPlay/YlAirPlayRemux.swift` and helpers; `tool/airplay` tests.
Interface: `YlAirPlayRemux.prepare(source:configuration:token:) throws`
returns a retained resource with `url: URL`, cleaned on final release.
- [x] Tests for real AVC/AAC remux, rejection, cancellation, HTTP bounds fail.
- [x] Produce HLS with compressed samples and expose safe LAN HTTP delivery.
- [x] Verify generated media with native AVPlayer and resource cleanup.

### Task 3: Native integration

Files: source descriptor/router; host/coordinator/registry; AVPlayer backend;
new AirPlay policy/channel/picker; native tests; example configuration.
- [x] Route-policy and host tests fail for missing AirPlay support.
- [x] Add versioned optional channel, direct/remux load routing and retention.
- [x] Add external-state KVO, frame-watchdog handling, lifecycle and picker.
- [x] Build/test both Apple targets; run relevant existing regressions.

### Task 4: Delivery

- [x] Document usage, supported sources, resource limits and device checks.
- [x] Review combined diff and fix material findings; record evidence.

## Execution ledger

- Clean baseline; branch `codex/airplay-video` created. Work in current checkout
  to retain the available native fixture/build setup; no user changes at start.
- User explicitly requested implementation after scope discussion; no repeated
  plan approval. Dart/remux workers own disjoint files; root owns Swift wiring.

- Completed public API, native routing, bounded remux, example and documentation.
- Review corrections include automatic live HLS, same-route interruption resume,
  AV resource retirement, handler cleanup and rejected/stale Stop state fencing.
- Focused Apple builds/tests passed on both platforms. The expanded iOS selection
  still exposed an existing reactivation decoder.unavailable failure; the full
  native suite and physical receivers are not claimed as accepted.
- Detailed commands, results and limits: `docs/verification/2026-10-19-airplay.md`.
- Working tree retained on `codex/airplay-video`; no integration requested.
