## 0.2.0-dev.1

- Implement the typed SPI major 2 registry, per-player transport, source
  assessment, commit/state barrier, session authority, and correlated callbacks.
- Add platform-default and managed Media3 networking with same-origin credential,
  per-attempt timeout, request-wide retry, and redirect policy enforcement.
- Honor system-default, hardware-preferred, and positively verified
  hardware-required decoder policies; reject exact bounded-buffer requests.
- Add one-owner plugin-managed audio focus and generation-safe replacement,
  lifecycle, output, Stop, and Dispose behavior.
- Add generated-callback transport size/schema invariants and publication gates.

## 0.1.0-dev.1

- Add endorsed Android federated registration.
- Set the minimum Android version to API 24.
- Add Media3 1.11.0 playback over SurfaceTexture for HLS, HTTP-FLV, local,
  content, and progressive sources.
- Add bounded buffer policies, HTTP headers, live-edge seek, audio selection,
  adaptive quality limits, state/events, capabilities, and structured errors.
- Add finite jittered retries, strict redirect limits, source-generation event
  isolation, one-active-decoder arbitration, and background/memory cleanup.
- Add automatic constrained/standard/capable device tiers. Android 7/API 24–27,
  32-bit, or at-most-2-GB devices select the constrained tier.
- Require hardware video decoding on Android, cap constrained selection at
  1080p30, and report stable capability/decoder errors when no compatible
  hardware path is available.
- Add source-specific constrained buffer ceilings for local, VOD, HLS live, and
  HTTP-FLV live playback, including a 25% running-low-memory shrink.
- Add downgrade-only runtime health adaptation, bounded HLS catch-up/live-edge
  recovery, and HTTP-FLV backlog reconnect handling.
- Add generation-safe Surface rebuild, three-second transient audio-focus grace,
  network wake mode, and intent-preserving foreground reconstruction.
- Expose Android tier, target bytes, downgrade count, Surface rebuild count, and
  selected video bitrate as nullable playback diagnostics.
- Keep subtitles, background audio, software video decoding, and persistent
  media cache unsupported. Physical Android 7/1.5-GB/32-bit endurance validation
  remains deferred.
