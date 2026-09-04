# yl_player

`yl_player` is the app-facing package for a hardware-first Flutter playback
kernel aimed at TVBox-style Android and iOS applications.

> Development status: `0.1.0-dev.1` contains functional Android Media3 and iOS
> AVPlayer main paths. The tree also contains an experimental iOS fallback for
> local and HTTP/HTTPS MKV VOD, but its physical-device and endurance acceptance
> matrix is incomplete. Treat it as a development release, not an iOS MKV
> smoothness or stable-support guarantee.

## Scope

- Android 7.0 (API 24) or later.
- iOS 15.0 or later.
- Local files, live streams, and video on demand in the public source model.
- HLS and HTTP-FLV hints, plus common local-container hints.
- Hardware-first decoder policy and bounded buffering configuration.
- Texture-only video rendering; encoded packets and decoded frames never cross
  the Dart boundary.
- Playback state, audio/video track metadata, capability reports, structured
  errors, and local performance metrics.

Android currently handles HLS, HTTP-FLV, and Media3 progressive containers.
iOS handles HLS and AVFoundation-compatible progressive/local media. A bundled
FFmpeg-demux/VideoToolbox fallback experimentally handles local and HTTP/HTTPS
MKV VOD with H.264/H.265 video and zero or more AAC-LC tracks. MKV video decode
is hardware-required; unsupported devices return
`decoder.video_hardware_unavailable`. Its current verification status is
recorded in
the [iOS MKV verification matrix](https://github.com/yuluoos/yl_player/blob/main/docs/verification/ios-mkv-device-matrix.md).

Network MKV live, HTTP-FLV fallback on iOS, non-AAC MKV audio, WebM/AVI/MPEG
fallback, non-HTTP transports, subtitles, DRM, downloads, persistent cache,
source-site parsing, playlists, UI controls, and telemetry upload are outside
this milestone.

The reviewed architecture is recorded in
[`docs/superpowers/specs/2026-09-02-yl-player-design.md`](../../docs/superpowers/specs/2026-09-02-yl-player-design.md).

## Usage

```dart
import 'package:flutter/widgets.dart';
import 'package:yl_player/yl_player.dart';

final controller = YlPlayerController(
  configuration: const YlPlayerConfiguration(
    decoderPolicy: YlDecoderPolicy.preferHardware,
    bufferMode: YlBufferMode.balanced,
  ),
);

await controller.open(
  YlMediaSource.network(
    Uri.parse('https://media.example/live.m3u8'),
    isLive: true,
    formatHint: YlFormatHint.hls,
  ),
);
await controller.play();

final view = YlPlayerView(
  controller: controller,
  placeholder: const SizedBox.shrink(),
);

await controller.dispose();
```

Create one controller per native player instance and always dispose it. The
complete compile-time example is in [`example/lib/main.dart`](example/lib/main.dart).

On Android, all `YlNetworkPolicy` fields and request headers are applied. The
iOS AVPlayer main path delegates timeout/retry policy to AVFoundation and cannot
enforce `minBufferDuration`, `maxBufferDuration`, or `maxBufferBytes`; it uses a
bounded forward-buffer duration selected by `bufferMode`. Custom headers remain
unsupported on that AVPlayer path, but are supported for the experimental
HTTP/HTTPS MKV fallback.

## Experimental iOS network MKV boundary

- VOD only; `isLive: true` is rejected.
- `lowLatency`, `automatic`/`balanced`, and `stable` use 4, 8, and 16 MiB
  network byte-cache ceilings. `custom` treats `maxBufferBytes` as the total
  managed-media budget and requires at least 3 MiB.
- HTTP Range servers support random seek. A server returning only HTTP 200 can
  play sequentially from byte zero and reports `isSeekable: false`.
- Same-origin redirects retain application headers. Cross-origin redirects
  strip `Authorization`, `Cookie`, and `Proxy-Authorization`.
- Networking is owned by `URLSession`; FFmpeg networking stays disabled. Bytes
  are streamed through bounded package-managed buffers and are not persisted to
  disk; URLSession/TLS, FFmpeg metadata, and VideoToolbox allocations are outside
  those byte ceilings.
- HTTPS needs no plugin-specific transport exception. Remote cleartext HTTP works
  only when the host application permits the destination with a minimal,
  preferably domain-scoped ATS policy; the plugin does not relax application ATS.
- Simulator gates cover routing, Range behavior, cancellation, lifecycle, and
  exact hardware-unavailable errors over loopback HTTP. Production HTTPS/TLS,
  physical-device playback, memory profiling, and long-run smoothness remain
  deferred.

## Publication

The four packages are intended to be published together in dependency order:
`yl_player_platform_interface`, `yl_player_android`, `yl_player_ios`, then
`yl_player`. Consumers in China can configure the Flutter China package mirror;
publication itself remains a pub.dev release workflow.

This project uses the BSD 3-Clause license.
