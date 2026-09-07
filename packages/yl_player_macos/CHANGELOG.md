## Unreleased

- Charge queued compressed video before submission, bound outstanding work, and
  release cancelled samples before decoder teardown.
- Serialize audio scheduling and controls so an automatic restart cannot
  override pause or disposal.
- Follow the owning Flutter window's display cadence and screen changes while
  preserving playback pause state.

## 0.1.0-dev.1

- Add endorsed macOS federated registration.
- Set the minimum macOS version to 12.0.
- Add AVPlayer and native FFmpeg/VideoToolbox playback paths for HLS,
  progressive media, MKV, and HTTP-FLV.
- Bound in-flight compressed video, enforce the advertised single hardware
  decoder lease, and make terminal fallback teardown one-shot.
- Keep redirect credentials bound to the original origin and sanitize AVPlayer
  terminal diagnostics.
- Verify universal artifacts, bridge provenance, Release loopback entitlement,
  Rosetta launch, and five native integration suites.
