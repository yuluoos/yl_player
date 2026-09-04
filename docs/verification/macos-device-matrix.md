# macOS verification matrix

Last updated: 2026-09-04

This matrix separates Apple Silicon runtime evidence, Intel build evidence, and
testing that still requires a physical Intel Mac. The reproducible gate is:

```sh
sh tool/check_native_macos.sh
```

## Current environment

- MacBook Pro (`MacBookPro17,1`), Apple M1, 16 GB memory.
- macOS 26.6.2 (25G83), `arm64`.
- Xcode 26.6 (17F113).
- Flutter 3.44.0 stable and Dart 3.12.0.

## Automated evidence

| Gate | Result | Evidence |
| --- | --- | --- |
| Dart adapter | Pass | Endorsed registration, shared channel protocol, state/delta handling, errors, and idempotent disposal. |
| Native tests | Pass | 34 focused tests cover routing, lifecycle, AVPlayer state/error policy, HLS origin policy, bounded networking/video admission, decoder leasing and rollback, AAC fixture conversion, clock/scheduling, and quality constraints. |
| Universal release build | Pass | The application executable, FlutterMacOS, Dart App, and YlFFmpegBridge each contain `arm64` and `x86_64`; the plugin compiles and links for both. |
| Deployment target | Pass | The built application and FFmpeg bridge declare macOS 12.0. |
| Intel smoke | Pass with caveat | The final `x86_64` executable launches through Rosetta on Apple Silicon; this is not Intel physical-device evidence. |
| HLS | Pass | AVPlayer reaches first frame, advances, pauses, and disposes. |
| Local MKV | Pass | H.264/AAC renders through the native fallback; multiple AAC tracks are exposed and switchable. |
| Network MKV | Pass | Loopback HTTP Range seek and sequential HTTP 200 behavior pass with bounded package-owned networking. |
| HTTP-FLV | Pass | H.264/AAC live playback survives a deliberately truncated first connection and resumes after native reconnect. |
| Authenticated HLS | Pass | Header-bearing playback succeeds through the package loopback path; origin filtering is covered separately by focused policy tests. |

## Architecture status

Apple Silicon runtime: verified.

Intel build and link: verified.

Intel physical-device runtime: not verified; no Intel Mac was available.

| Architecture | Compile/link | Runtime | Status |
| --- | --- | --- | --- |
| Apple Silicon (`arm64`) | Pass | Native unit and all five integration suites pass | Verified on the listed M1 machine |
| Intel (`x86_64`) | Pass | Rosetta smoke launch only | Physical Intel runtime required before making an Intel-device runtime claim |

## Remaining release evidence

- Run the complete native and integration gate on a physical Intel Mac running
  macOS 12 and on the newest supported Intel macOS release.
- Record long-duration HLS, MKV, and HTTP-FLV playback plus repeated
  open/play/seek/dispose cycles on representative Apple Silicon and Intel Macs.
- Capture Instruments or equivalent memory evidence for textures,
  VideoToolbox sessions, packet queues, scheduled PCM, reconnects, and source
  replacement.
- Exercise production HTTPS certificate chains, CDNs, redirects, authenticated
  HLS, and Range/sequential MKV servers.

## Release decision

Status: **the macOS 12+ implementation and universal build contract are
automated and verified on Apple Silicon**. Intel artifacts compile, link, and
smoke-launch through Rosetta, but physical Intel runtime acceptance remains
open.
