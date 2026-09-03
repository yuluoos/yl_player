# yl_player Native Main Paths Implementation Plan

**Goal:** Replace the compile-only native shells with functional Media3 and
AVPlayer playback over Flutter Texture while preserving the reviewed TVBox
resource and error boundaries.

**Architecture:** Each endorsed package owns a typed Dart channel adapter and a
native player registry. A global method/event channel multiplexes isolated
player IDs. Native players own decoder, network, surface, timers, and teardown;
Dart receives only commands and low-rate state/events. Android uses Media3
ExoPlayer 1.11.0 for HLS, HTTP-FLV, progressive network media, content URIs, and
local files. iOS uses AVPlayer plus AVPlayerItemVideoOutput for HLS, supported
progressive media, and local files. iOS HTTP-FLV remains an explicit
`container.unsupported` result until the separately vendored libavformat +
VideoToolbox fallback is built.

## Task 1: Native channel protocol

- [x] Define stable create/command/dispose method payloads and multiplexed
  state/event payloads.
- [x] Add shared serialization fixtures to platform tests.
- [x] Ensure no packet, frame, PCM, subtitle, or DRM payload is representable.

## Task 2: Android Dart adapter

- [x] Replace the placeholder with a method/event-channel player.
- [x] Decode state, metrics, tracks, first-frame, and structured-error events.
- [x] Test create, command delegation, native state mirroring, and idempotent
  disposal with mocked channels.

## Task 3: Android Media3 backend

- [x] Add stable Media3 ExoPlayer, HLS, and extractor dependencies.
- [x] Build bounded buffer/load-error policies from configuration.
- [x] Render directly to a SurfaceTexture and publish throttled state.
- [x] Support headers, local/content/network sources, HLS, HTTP-FLV, common
  progressive containers, live-edge seek, quality limits, and audio selection.
- [x] Release player, Surface, texture, callbacks, and timers idempotently.
- [x] Compile the API-24 example APK.

## Task 4: iOS Dart adapter

- [x] Replace the placeholder with an equivalent typed channel player.
- [x] Reuse the protocol semantics and test the complete command surface.

## Task 5: iOS AVPlayer backend

- [x] Register AVPlayerItemVideoOutput as a FlutterTexture without Dart frames.
- [x] Support HTTP headers, HLS, supported progressive media, and local files.
- [x] Publish status, timing, live/DVR, dimensions, tracks, and errors.
- [x] Reject HTTP-FLV explicitly for fallback routing.
- [x] Tear down KVO, notifications, periodic observers, display link, player,
  output, and texture idempotently.
- [x] Compile the iOS 15 Simulator example.

## Task 6: Integration and release truth

- [ ] Update the main example and READMEs to distinguish verified main-path
  support from planned fallback formats.
- [ ] Run analyze, all Dart tests, Android debug build, iOS Simulator build,
  format verification, and four pub dry-runs.
- [ ] Do not claim low-end-device smoothness until physical-device soak and
  memory/performance measurements have been recorded.

## Deferred acceptance boundary

The native main-path milestone does not vendor FFmpeg. iOS HTTP-FLV and
containers outside AVFoundation remain unsupported until a reproducible XCFramework
build, licenses, ABI slices, VideoToolbox decode, audio decode/render, A/V sync,
and stress tests exist. Android and iOS physical-device matrices are also a
release gate for the eventual stable `1.0.0`, not for this development release.
