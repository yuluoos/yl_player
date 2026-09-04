# iOS local and network MKV verification matrix

Last updated: 2026-09-04

This document separates implemented behavior from physical-device acceptance.
The local and HTTP/HTTPS VOD Matroska fallback is present in the development
tree, but it is not a release support claim until the physical-device and memory
rows below pass.

Current automated runs used an iPhone 17e Simulator on iOS 26.5:

```bash
simulator_id=$(sh tool/boot_ci_ios_simulator.sh)
YL_IOS_SIMULATOR_ID="$simulator_id" sh tool/check_native_ios.sh
```

The gate includes full XCTest and all five iOS Flutter integration suites. It
does not convert a Simulator hardware-unavailable branch or explicit skip into
physical VideoToolbox evidence.

## Automated evidence

| Gate | Result | Notes |
| --- | --- | --- |
| Foundation checks | Pass | Dart formatting, analysis, unit tests, and the pinned FFmpeg build contract pass. |
| Native iOS checks | Pass | Full XCTest plus AVPlayer HLS, local-MKV, loopback HTTP Range/sequential-MKV, HTTP-FLV, and authenticated-HLS Flutter integration pass on the iPhone 17e Simulator with iOS 26.5. |
| Android debug build | Pass | The example debug APK builds. |
| iOS Simulator debug build | Pass | The example links the packaged FFmpeg bridge and builds. |
| Package dry runs | Pass | All four packages complete `dart pub publish --dry-run` with zero warnings. |

The Simulator does not prove VideoToolbox hardware decode. Local and network MKV
integration tests therefore accept only the stable
`decoder.video_hardware_unavailable`/`decoderUnsupported` result when a required
hardware session cannot be created; a physical device must instead render the
first frame and report `VideoToolbox` hardware decoding. The network suite also
verifies initial 206/header handling, sequential HTTP 200 behavior, and failed
candidate preservation on Simulator. Its successful hardware branch uses a
10 MiB, 20-second fixture with a 4 MiB cache and requires a new nonzero Range
request after a paused 16-second seek.

## Physical-device matrix

| Device | OS | Test | Result | Evidence still required |
| --- | --- | --- | --- | --- |
| iPhone (`00008140-000C49CC3493001C`, wireless) | iOS 26.6 (23G71) | Generated 320x180 H.264/AAC MKV and two-AAC-track MKV | Blocked before installation | Xcode on this Mac has no signed-in Apple Developer account and no development profile for `dev.ylplayer.ylPlayerExample`. No playback result was recorded. |
| iOS 15 physical device | iOS 15.x | H.264/AAC and HEVC/AAC MKV | Not run | Device/runtime, decoder, first-frame latency, seek, audio sync, background/resume, and 30-minute playback. |
| Target iPhone/iPad | iOS 15+ | HTTP/HTTPS H.264/AAC and HEVC/AAC MKV VOD | Deferred | Range and sequential servers, request headers, redirects, retry, seek, track switching, background/resume, memory warning, and long-run playback. |

The current-device attempt used:

```bash
cd packages/yl_player/example
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/ios_mkv_playback_test.dart \
  -d 00008140-000C49CC3493001C \
  --publish-port
```

Flutter found the phone, selected development team `JAKM34U2X8`, and reached
the Xcode build. Xcode then reported `No Accounts` and no provisioning profile
for the example bundle identifier. After signing is configured, the same
command is the short physical-device acceptance gate.

## Memory and endurance evidence

These release gates remain open:

- 100 open/play/seek/dispose cycles on a physical device, with the bridge
  outstanding-packet counter returning to zero after every cycle.
- Instruments or memgraph evidence showing that VideoToolbox sessions,
  textures, display links, packet bytes, decoded frames, and scheduled PCM do
  not grow monotonically.
- 30-minute H.264 1080p30 playback with first-frame latency, average/maximum
  memory, seek behavior, audio sync, and background/resume recorded.
- HEVC playback with hardware reported, or the exact
  `decoder.video_hardware_unavailable` error on unsupported hardware.
- HTTP Range VOD seeking beyond the 4 MiB cache and HTTP 200 sequential playback
  against representative production servers, including redirect/header policy.

## Release decision

Status: **experimental automated support; not yet accepted as stable iOS MKV
support**. Automated and Simulator integration gates are green for local files
and loopback HTTP Range/sequential VOD. HTTPS uses the same URLSession byte-source
path, but production TLS/server interoperability, code signing, physical
playback, iOS 15 device coverage, and measured endurance/memory evidence remain
outstanding.
