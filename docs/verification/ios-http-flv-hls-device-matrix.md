# iOS HTTP-FLV and authenticated-HLS verification matrix

Last updated: 2026-09-04

This matrix separates implemented behavior from physical-device acceptance.
Authenticated HLS has deterministic Simulator coverage. HTTP-FLV remains
experimental and must not be described as stable until the target-device rows
below pass.

Current automated runs used an iPhone 17e Simulator on iOS 26.5. The reproducible
gate is:

```bash
simulator_id=$(sh tool/boot_ci_ios_simulator.sh)
YL_IOS_SIMULATOR_ID="$simulator_id" sh tool/check_native_ios.sh
```

This command runs full XCTest plus HLS, local MKV, network MKV, HTTP-FLV, and
authenticated-HLS Flutter integration suites. A Simulator hardware-unavailable
branch or explicit XCTest skip does not count as physical VideoToolbox evidence.

## Automated evidence

| Gate | Result | Notes |
| --- | --- | --- |
| FFmpeg contract | Pass | FLV + Matroska demux and AAC/H.264/HEVC/MPEG-audio parsers are allowlisted; networking and software decoders remain disabled. |
| Native iOS XCTest | Pass | iPhone 17e Simulator, iOS 26.5. Routing, demux metadata, AAC/MP3 setup, reconnect controller/lifecycle, HLS rewriting, origin policy, proxy handoff, cancellation, and rollback are covered. |
| Authenticated HLS integration | Pass | iPhone 17e Simulator, iOS 26.5: master/child manifests, AES-128 key, encrypted TS first frame, same-origin credentials, server-cookie isolation, and cross-origin `X-Client`. |
| HTTP-FLV integration | Pass with Simulator hardware caveat | Chunked loopback source, header forwarding, capabilities, and exact hardware-unavailable fallback; successful decode/reconnect branch is required on a physical device. |

## Physical-device acceptance

| Device | iOS | H.264/AAC | H.264/MP3 | H.265/AAC | Forced reconnect | Memory warning | 30-minute live | Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Target iPhone | 15.x | Not run | Not run | Not run | Not run | Not run | Not run | Required |
| Target iPhone/iPad | Latest supported | Not run | Not run | Not run | Not run | Not run | Not run | Required |

For every codec row, record device model/identifier, exact iOS build, first-frame
latency, reported `VideoToolbox` hardware decode, audio presence/sync, retry
events, connection count, peak memory, and final disposition. Unsupported HEVC
hardware may pass only with the exact
`decoder.video_hardware_unavailable`/`decoderUnsupported` result.

## HLS production acceptance

- Verify production HTTPS certificate chains and CDN redirects.
- Verify headers on master/media playlists, AES keys, fMP4 initialization
  sections where used, and TS/fMP4 media resources.
- Verify same-origin credentials never reach a different scheme, host, or
  effective port while non-sensitive headers do.
- Verify the host's minimal ATS policy permits `127.0.0.1` local networking and
  does not add a global remote cleartext exception.
- Exercise background/foreground, source replacement, cancellation, and 100
  open/play/dispose cycles without listener, task, or memory growth.

## Release decision

Status: **authenticated HLS is automated on Simulator; HTTP-FLV is implemented
but experimental**. A stable HTTP-FLV support claim is blocked on both physical
device rows, memory-warning recovery, and the 30-minute live run.
