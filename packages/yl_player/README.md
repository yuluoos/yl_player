# yl_player

`yl_player` is the app-facing package for a hardware-first Flutter playback
kernel aimed at TVBox-style Android and iOS applications.

> Development status: `0.1.0-dev.1` contains functional Android Media3 and iOS
> AVPlayer main paths. The tree also contains experimental iOS native fallbacks
> for local/HTTP(S) MKV VOD and HTTP(S)-FLV live playback. Their physical-device
> and endurance acceptance matrices are incomplete. Treat this as a development
> release, not an iOS fallback smoothness or stable-support guarantee.

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
iOS handles HLS (including caller-supplied request headers), HTTP-FLV, and
AVFoundation-compatible progressive/local media. On
Android, devices are automatically classified as `constrained`, `standard`, or
`capable`; video decoding is hardware-only, only one decoder is active, and
source-specific byte/time ceilings protect low-memory TV boxes. The constrained
selection envelope is at most 1080p30, subject to the display and hardware codec
capability—it is not a universal smoothness guarantee. HEVC requires a compatible
hardware decoder.

Android retains Flutter's `SurfaceTextureEntry` contract on the current Flutter
3.44 / Android API 24 compatibility floor. Video output restoration is handled
by the tested `YlVideoOutput` source/surface-generation lifecycle; this release
does not claim equivalent `SurfaceProducer` restoration behavior.

The Android examples retain Flutter 3.44's generated AGP 9 compatibility
switches for the legacy Android DSL and external Kotlin plugin. Flutter 3.44's
Gradle plugin and bundled `integration_test` package still require those paths;
removing them makes project configuration fail before compilation.

A bundled FFmpeg-demux/VideoToolbox fallback experimentally handles local and HTTP/HTTPS
MKV VOD with H.264/H.265 video and zero or more AAC-LC tracks. MKV video decode
is hardware-required; unsupported devices return
`decoder.video_hardware_unavailable`. Its current verification status is
recorded in
the [iOS MKV verification matrix](https://github.com/yuluoos/yl_player/blob/main/docs/verification/ios-mkv-device-matrix.md).

Network MKV live, non-AAC MKV audio, WebM/AVI/MPEG
fallback, non-HTTP transports, subtitles, DRM, downloads, persistent cache,
source-site parsing, playlists, UI controls, and telemetry upload are outside
this milestone.

Android automatic constrained-mode limits are 2–10 seconds / 16 MiB for local
media, 4–15 seconds / 24 MiB for network VOD, 6–12 seconds / 20 MiB for HLS
live, and 2–5 seconds / 12 MiB for HTTP-FLV live. Runtime adaptation only
downgrades. Subtitles, background audio, software video decode, and persistent
media cache are not provided. Android 7.0 / 1.5 GB / 32-bit ARM physical-device
endurance testing remains deferred.

The nullable Android diagnostics on `YlPlaybackMetrics` are
`androidDeviceTier`, `targetBufferBytes`, `adaptiveDowngradeCount`,
`surfaceRebuildCount`, and `selectedVideoBitrate`; other backends may leave them
`null`.

`hardwareOnly` is the default decoder policy. The deprecated
`preferHardware` value is accepted for source compatibility but resolves to the
same hardware-only behavior. AVPlayer's decoder choice remains system-managed;
the package does not claim which decoder AVPlayer selected. Reported
`hardwareVideoCodecs` use canonical MIME identifiers such as `video/avc` and
`video/hevc`.

The reviewed architecture is recorded in
[`docs/superpowers/specs/2026-09-02-yl-player-design.md`](../../docs/superpowers/specs/2026-09-02-yl-player-design.md).

## Usage

```dart
import 'package:flutter/widgets.dart';
import 'package:yl_player/yl_player.dart';

final controller = YlPlayerController(
  configuration: const YlPlayerConfiguration(
    decoderPolicy: YlDecoderPolicy.hardwareOnly,
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

## Validation and state guarantees

Public configuration and command inputs are validated before native player
creation or command dispatch in both debug and release builds. Seek positions
must be nonnegative. Playback speed must be finite and within `0.25`–`4.0`, and
volume must be finite and within `0.0`–`1.0`. Present quality constraint fields
must be positive native integers. Retry and redirect counts must be within
`0`–`20`; timeout, retry-delay, position-interval, and buffer-budget values must
also satisfy their documented positive and ordering constraints.

A rejected command completes with `YlPlayerError`, but it does not mutate the
current player `state` and does not emit `YlErrorEvent`. A terminal playback
failure reported by the native backend both moves state to `error` and emits the
error event. This keeps native playback state authoritative.

The public position-update interval remains 250 ms by default. Internally, each
source generation starts with a complete versioned state snapshot; subsequent
periodic position updates use a compact state delta containing only continuous
position, buffer, live-edge, and metric fields. This transport optimization does
not change the public state or event API.

On Android, all `YlNetworkPolicy` fields and request headers are applied. The
iOS unheadered AVPlayer path delegates timeout/retry policy to AVFoundation.
Header-bearing HLS applies connect/read timeouts and `maxRedirects` in its
loader/proxy, while AVPlayer still owns adaptive retries. Neither path can
enforce `minBufferDuration`, `maxBufferDuration`, or `maxBufferBytes`; a bounded
forward-buffer duration is selected by `bufferMode`. iOS custom headers are
supported for HLS and the package-owned MKV/FLV network paths. Header-bearing
non-HLS AVPlayer progressive sources remain unsupported.

For authenticated HLS, `Authorization`, `Cookie`, and `Proxy-Authorization`
are sent only to resources with the same scheme, normalized host, and effective
port as the top-level manifest. Automatic URLSession cookie storage is disabled,
so only the caller's explicitly supplied `Cookie` follows this policy. Other
caller headers are sent to same- and cross-origin HLS resources. Manifests and
AES-128 keys use a package-owned
resource loader; media segments and initialization sections pass through a
short-lived HTTP proxy bound only to `127.0.0.1`, because AVFoundation does not
accept HLS media bytes directly from a custom resource scheme. The proxy is
cancelled with the asset and does not persist media. The host iOS application
must permit local networking in ATS (for example `NSAllowsLocalNetworking`) even
when the upstream stream uses HTTPS. Remote cleartext HTTP still requires a
minimal host-scoped ATS exception.

## Experimental iOS HTTP-FLV boundary

- Network HTTP/HTTPS live sources only, using `httpFlv`/`flv` or automatic
  routing for a `.flv` path; playback reports `nativeFallback`, `isLive: true`,
  and `isSeekable: false`.
- Video is H.264/AVC or H.265/HEVC and requires VideoToolbox hardware decode.
  Audio may be AAC-LC, MP3, or absent; AudioToolbox performs audio decode.
- Transport failure rebuilds the complete live pipeline from byte zero, waits
  for a usable keyframe, and emits retry events. Attempts and exponential delay
  are bounded by `YlNetworkPolicy`; exhaustion reports
  `network.retry_exhausted`.
- Sorenson H.263, VP6, AV1, VP9, Nellymoser, Speex, audio-only FLV, seeking/DVR,
  FFmpeg networking/software decode, and persistent cache are unsupported.
- Simulator tests accept the exact `decoder.video_hardware_unavailable` result.
  H.264/AAC, H.264/MP3, H.265/AAC, reconnect, memory-warning, and 30-minute runs
  must pass on target devices before HTTP-FLV is described as stable. See the
  [iOS HTTP-FLV/HLS verification matrix](https://github.com/yuluoos/yl_player/blob/main/docs/verification/ios-http-flv-hls-device-matrix.md).

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
