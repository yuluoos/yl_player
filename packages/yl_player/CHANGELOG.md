## 0.2.0-dev.1

- Replace implicit construction/open with asynchronous Player creation, source
  assessment, committed Session handles, and separate Ready/First Frame futures.
- Add stale-session fencing, reusable Stop, idempotent Dispose, correlated
  state/events, safe structured failures, and authoritative video geometry.
- Add explicit player/load options for network, buffer, decoder, audio ownership,
  autoplay, start position, and video constraints.
- Endorse the consolidated Android and Apple v0.2 implementations and remove the
  legacy protocol bridge and split Apple packages.
- Publish the v0.2 migration, support, policy, diagnostics, and runnable lifecycle
  documentation. Final multi-platform acceptance remains pending.

## 0.1.0-dev.1

- Define the app-facing controller and texture-only player view.
- Endorse the Android and iOS implementation packages.
- Add a runnable public API example.
- Add functional Android Media3 and iOS AVPlayer endorsed main paths.
- Bundle an experimental iOS H.264/H.265 + AAC Matroska fallback for local files
  and HTTP/HTTPS VOD; hardware decode, physical-device playback, and endurance
  acceptance remain release gates.
- Add URLSession-backed custom AVIO streaming with bounded 4/8/16 MiB network
  cache profiles, Range seek, sequential HTTP 200 playback, retry, redirects,
  request headers, cancellation, and foreground reconstruction.
- Add experimental iOS HTTP/HTTPS-FLV live playback for hardware H.264/H.265
  with AAC-LC or MP3, non-seekable state, keyframe-gated bounded reconnects, and
  caller request headers.
- Add iOS HLS custom headers across manifests, AES keys, initialization/media
  resources, with same-origin-only credentials and a cancellable loopback media
  proxy that avoids undocumented AVFoundation header options.
- Add bounded iOS AVPlayer reconnects for direct live HLS and sanitized
  HLS error-log diagnostics for terminal failures.
- Add the endorsed macOS 12+ implementation with AVPlayer HLS/progressive
  playback and hardware-only VideoToolbox fallbacks for local/network MKV and
  HTTP/HTTPS-FLV live playback.
- Add macOS AAC/MP3 fallback audio, bounded network buffering and reconnects,
  authenticated HLS origin protection, lifecycle cleanup, universal
  `arm64`/`x86_64` artifacts, and native/integration CI gates.
- Verify macOS runtime on Apple Silicon and compile/link plus Rosetta smoke for
  Intel; physical Intel hardware runtime remains unverified.
- Treat custom `maxBufferBytes` as the total managed-media budget for network
  bytes, scheduled PCM, and bounded in-flight encoded video; do not persist
  media.
- Enforce one macOS VideoToolbox fallback decoder at a time with quiesce/rollback
  replacement, one-shot terminal teardown, origin-bound redirect credentials,
  and sanitized AVPlayer errors.
- Keep iOS network MKV live and other remote fallback containers,
  non-AAC MKV audio, subtitles, and DRM unsupported.
- Keep Dart resource teardown idempotent even when native disposal reports an
  error.
- Add Android automatic device tiers, hardware-only video selection,
  source-specific bounded buffers, downgrade-only health adaptation, and
  low-memory TV lifecycle recovery.
- Expose nullable Android device-tier, target-buffer, adaptive-downgrade,
  Surface-rebuild, and selected-video-bitrate metrics.
- Keep Android physical-device endurance validation deferred for the Android
  7.0 / 1.5 GB RAM / 32-bit ARM reference TVBox.
