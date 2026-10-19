# Custom Live AirPlay Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans with independent modules delegated through superpowers:dispatching-parallel-agents. Steps use checkbox syntax.

**Goal:** Play compatible RTMP and HTTP-FLV live streams through the existing AirPlay interface.
**Architecture:** Production compressed live input feeds a retained worker and sliding HLS store. AVPlayer consumes its LAN URL; source and player lifetimes own cancellation and terminal-error delivery.
**Tech Stack:** Swift, existing FFmpeg bridge/RTMP/HTTP transports, AVFoundation, Network; no Pigeon change.
**Spec:** `docs/superpowers/specs/2026-10-19-airplay-live-design.md`

## Global Constraints

- iOS 15/macOS 12, H.264/optional mono-stereo AAC-LC; no arbitrary transcoding.
- Existing VOD, direct HLS, request validation and strict-policy rejection remain.
- Files, connections, packets, startup waits and reconnection are bounded.
- Keep previous uncommitted AirPlay implementation; same authorized branch.

## Review Focus

- Readers holding old playlists must fetch their segments during retention.
- Input disconnect/PTS resets cannot reuse an init filename or fake continuity.
- Failed candidate or old callbacks cannot terminate a newer session.
- Stopping during open, append, backoff or HTTP read cannot leak or deadlock.
- A never-ending input must become ready without EOF or VOD scanning.

### Task 1: Live HLS storage and HTTP

Files: `Shared/AirPlay/YlAirPlayLiveStore.swift`, existing HTTP server;
`tool/airplay` store tests.
- [x] Add tests for atomic playlist, rolling sequence, discontinuity/maps, retention and disk bounds; run red.
- [x] Implement resource resolver with locked open and bounded publication/retirement.
- [x] Verify HTTP/Range security and old VOD behavior.

### Task 2: Live compressed producer

Files: `Shared/AirPlay/YlAirPlayLiveRemux.swift`, shared sample helper access in `YlAirPlayRemux.swift`; focused harness.
- [x] Add finite-start/infinite-input readiness, timestamp and cancellation tests; run red.
- [x] Implement real compressed live input, keyframe segmentation and retained worker.
- [x] Add bounded reconnect with new HLS period and terminal failure observation.
- [x] Verify actual AVPlayer output and source teardown.

### Task 3: Route and native lifetime

Files: source policy/router, prepared-media lifetime, session coordinator and AVPlayer backend; canonical native host tests.
- [x] Add live source admission and rejected policy cases; run red.
- [x] Route RTMP and live FLV to live producer; preserve ordinary paths.
- [x] Deliver current-session errors, close producer on retirement, preserve candidate rollback.
- [x] Build/test macOS and iOS, integrate real protocol fixtures.

### Task 4: Delivery

- [x] Review combined source and fix material findings.
- [x] Update usage, supported limits and evidence; run focused regression and public checks.
- [x] Leave working tree for review; no commit/push requested.

## Execution record

- Source-policy tests first failed on the missing live route, then passed after
  routing RTMP/live FLV through the retained producer.
- Store/HTTP suite reached 45 checks. A fresh review's held-reader disk-cap
  repro was run red, fixed with resource leases and playlist-generation
  accounting, and passed re-review.
- Added seven canonical native AirPlay cases on each Apple host, preserving
  the existing eight. Real held-open HTTP-FLV and RTMP fixtures exercise
  readiness, rolling, reconnect, cancellation and session lifetime.
- Producer uses bounded compressed writer queues and a streaming FLV validator
  because stream-level FFmpeg metadata does not expose changed packet-side AAC
  configuration. Validator fragmentation/configuration/size/seek cases pass.
- Final commands, results and remaining physical-device acceptance are recorded
  in `docs/verification/2026-10-19-airplay-live.md`.
- All changes remain in the working tree; no commit or push was requested.
