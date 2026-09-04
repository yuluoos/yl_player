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
- Treat custom `maxBufferBytes` as the total managed-media budget for network
  bytes, scheduled PCM, and one in-flight encoded packet; do not persist media.
- Keep iOS network MKV live, HTTP-FLV and other remote fallback containers,
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
