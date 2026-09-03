# yl_player

`yl_player` is the app-facing package for a hardware-first Flutter playback
kernel aimed at TVBox-style Android and iOS applications.

> Development status: `0.1.0-dev.1` is the public API foundation. The Android
> Media3 and iOS AVPlayer backends are registration shells and do not play media
> yet. Do not ship this development release as a working player.

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

Subtitles, DRM, downloads, source-site parsing, playlists, UI controls, and
telemetry upload are intentionally outside this package.

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
    headers: const {'Referer': 'https://media.example/'},
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

## Publication

The four packages are intended to be published together in dependency order:
`yl_player_platform_interface`, `yl_player_android`, `yl_player_ios`, then
`yl_player`. Consumers in China can configure the Flutter China package mirror;
publication itself remains a pub.dev release workflow.

This project uses the BSD 3-Clause license.
