# iOS local MKV verification matrix

Last updated: 2026-09-03

This document separates implemented behavior from physical-device acceptance.
The local Matroska fallback is present in the development tree, but it is not a
release support claim until the physical-device and memory rows below pass.

## Automated evidence

| Gate | Result | Notes |
| --- | --- | --- |
| Foundation checks | Pass | Dart formatting, analysis, unit tests, and the pinned FFmpeg build contract pass. |
| Native iOS checks | Pass | Full XCTest plus AVPlayer HLS and local-MKV Flutter integration pass on Simulator. |
| Android debug build | Pass | The example debug APK builds. |
| iOS Simulator debug build | Pass | The example links the packaged FFmpeg bridge and builds. |
| Package dry runs | Pass | All four packages complete `dart pub publish --dry-run` with zero warnings. |

The Simulator does not prove VideoToolbox hardware decode. The MKV integration
test therefore accepts only the stable
`decoder.video_hardware_unavailable`/`decoderUnsupported` result when a required
hardware session cannot be created; a physical device must instead render the
first frame and report `VideoToolbox` hardware decoding.

## Physical-device matrix

| Device | OS | Test | Result | Evidence still required |
| --- | --- | --- | --- | --- |
| iPhone (`00008140-000C49CC3493001C`, wireless) | iOS 26.6 (23G71) | Generated 320x180 H.264/AAC MKV and two-AAC-track MKV | Blocked before installation | Xcode on this Mac has no signed-in Apple Developer account and no development profile for `dev.ylplayer.ylPlayerExample`. No playback result was recorded. |
| iOS 15 physical device | iOS 15.x | H.264/AAC and HEVC/AAC MKV | Not run | Device/runtime, decoder, first-frame latency, seek, audio sync, background/resume, and 30-minute playback. |

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

## Release decision

Status: **not yet accepted for a supported iOS MKV release**. Automated and
Simulator gates are green; code signing, physical playback, iOS 15 coverage,
and measured endurance/memory evidence remain outstanding.
