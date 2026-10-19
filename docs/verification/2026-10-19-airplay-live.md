# RTMP / HTTP-FLV AirPlay implementation verification

Date: 2026-10-19. This extends the [initial AirPlay implementation](2026-10-19-airplay.md).
The public opt-in, route picker and state APIs are unchanged. The new route
continuously remuxes compatible RTMP/HTTP-FLV into a bounded sliding fMP4 HLS
playlist. It uses existing production HTTP/RTMP input and the shipped FFmpeg
bridge; no FFmpeg binary rebuild or runtime transcoder is required.

## Automated evidence

- Pure Swift AirPlay source-policy tests pass, including live FLV admission,
  strict policy/DRM rejection and preservation of the finite VOD route. The
  initial test failed because `liveRemux` did not yet exist.
- Focused Dart AirPlay controller/widget/channel and diagnostic tests:
  **62 passed**, `/tmp/yl-airplay-live-dart.log`. Diagnostic expectation changes
  were run before production mapping changes and failed as expected.
- Canonical Apple fixture checks: **iOS 806 / macOS 852** methods verified;
  public surface checker and whitespace checks pass.
- Final integrated macOS run: **15 AirPlay tests passed**, zero skipped,
  `/tmp/yl-airplay-native/Logs/Test/Test-Runner-2026.10.19_02-44-09--0700.xcresult`.
- Final integrated iOS Simulator run: **17 tests passed** (15 AirPlay plus
  two memory-warning tests), zero skipped,
  `/tmp/yl-airplay-ios/Logs/Test/Test-Runner-2026.10.19_02-41-48--0700.xcresult`.

Native cases exercise production sequential HTTP-FLV while the connection
stays open; live readiness and playlist sliding; forced upstream reconnection
with a new map/discontinuity while retaining the AVPlayer item; real RTMP
handshake/data with a held socket; cancellation during RTMP startup; source
policy rejection; old/current producer failure fencing and failure replay after
resume; exactly-once prepared-media cleanup. Existing direct and finite-remux
AirPlay cases run in the same suite.

- Live store/HTTP standalone suite: **45 checks passed**, including rolling
  playlists, retention, byte ranges, request validation, descriptor leases,
  byte/file caps and atomic-playlist reader accounting.
- Existing finite VOD harness passes all four H.264/AAC fixtures with AVPlayer
  decoded frames, AAC decode, seek, HTTP/ranges and cancellation/cleanup:
  `/tmp/yl-airplay-live-vod-regression.log`.
- Focused Dart static analysis reports no issues:
  `/tmp/yl-airplay-live-analyze.log`.

- Full-production live HTTP-FLV harness passes AVPlayer readiness and actual
  decoded video for the canonical B-frame fixture and an additional generated
  B-frame fixture. It also verifies that cancelling the completed load token
  does not stop the retained producer, and bridge packet count returns to zero
  after teardown.
- Forced upstream disconnect preserves the same AVPlayerItem and publishes
  `init-1.mp4`. The fixture atomically records the original connection's highest
  emitted video PTS plus a conservative margin; the returned decoded pixel
  buffer's actual display PTS **34.7466666667 s** exceeds that source-proven
  bound **34.646 s**. This proves decoding after the discontinuity, independently
  of playlist rolling or buffered old packets: `/tmp/yl-live-verified.log`.
- Production HTTP input rejects both AAC and H.264 configuration changes with
  `airplay.unsupported_codec` before readiness. Reproducible commands are in
  [the live harness instructions](../../tool/airplay/README-remux.md).

## Review and fixes

An independent review reproduced an output-accounting defect: unlinking an
expired segment removed it from the budget even though an HTTP reader still
held its descriptor and disk blocks. The fix defers unlink and accounting removal until the last reader closes.
The regression holds an expired 10 MiB segment while appending enough new
output to reach the resource limit; it failed before the fix and passes after.
Atomic playlist snapshots held across replacement are also counted, and HTTP
completion/error/HEAD/cancellation paths release idempotent resource leases.

Producer validation also checks bounded writer backpressure and audio/video
skew. A live AAC configuration-change fixture exposed that the existing FFmpeg
bridge's stream configuration API does not surface packet-side configuration
changes; input-level FLV validation covers this without changing the bridge
binary. Focused parser checks exercise reads fragmented into 1, 7, 1024 and
32768 bytes, valid FLV, changed AAC/H.264 sequence headers and oversized tags.
The storage lease fix passed independent read-only re-review. The FLV validator
and RTMP preparation hook also passed focused review; offset-changing seeks
are explicitly rejected so parser state cannot desynchronize.
`python3 tool/airplay/live_remux_validator_check.py` passes against the actual
production validator class (`/tmp/yl-airplay-live-validator-final.log`).

## Acceptance boundary

Automated AVPlayer output and real protocol fixtures do not prove physical
AirPlay receiver or CarPlay operation. Physical acceptance remains required for
LAN reachability, local-network permission, real receiver decoding, interruption
and background behavior, route changes, and vehicle/parked-state integration.
The bridge supports H.264 with optional mono/stereo AAC-LC, non-TLS RTMP and
HTTP(S)-FLV. RTMPS and arbitrary transcoding remain unsupported. See
[usage and limits](../airplay.md).
