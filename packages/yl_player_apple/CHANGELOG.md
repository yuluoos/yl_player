## Unreleased

- 将 FFmpeg 和共享输入迁入 `yl_player_media_core`，HLS 转封装/交付迁入可选 `yl_player_media_delivery`。
- 保留旧 AirPlay 与交付 API；自定义源转换需显式添加交付插件，缺失时返回 `airplay.delivery_unavailable`。

## 0.3.0-dev.2

- Add an opt-in `useFlutterTexture` registration option for dedicated external
  display engines, avoiding phone/CarPlay scale mismatches in UIKit composition.
  Default native output and protected FairPlay output remain unchanged.

## 0.3.0-dev.1

- Add AirPlay route selection for supported video and live sources, including
  bounded local remux/relay paths for managed media.
- Add RTMPS live playback and preserve external playback while the application
  moves into the background.

## 0.2.0-dev.2

- Advance managed-fallback video smoothly between audio completion callbacks
  while bounding the clock by scheduled PCM.
- Recover direct live playback from silent stalls without clearing the last
  frame, and respect AVPlayer's stable-buffering decisions.
- Keep rejected HLS fallback-probe cleanup separate from the parent Load so
  non-HEVC HLS can still commit through AVPlayer.

## 0.2.0-dev.1

- Dispatch every native Pigeon callback on the platform thread, including after
  asynchronous acknowledgements.

- Consolidate the typed registry, session lifecycle, Pigeon transport, AVPlayer
  and fallback engines into one endorsed iOS/macOS implementation.
- Share one FFmpeg XCFramework across iOS device, iOS Simulator and macOS.
- Support iOS 15.0 and macOS 12.0 through CocoaPods and Swift Package Manager.
- Preserve HLS credential stripping across same-session reconstruction and
  bound Dart session authority and event deduplication bookkeeping.
- Separate immutable artifact verification from exact-toolchain reproduction.
- Enforce managed Matroska/FLV networking, Player-wide bounded fallback budgets,
  positive VideoToolbox hardware requirements, and process-wide audio ownership.
- Add transactional replacement/recovery, controlled HLS credential routing,
  safe diagnostics, and authoritative geometry/first-frame publication.
- Add generated-callback transport size/schema invariants and publication gates.
- Remain a development checkpoint: physical-device, minimum-OS, Intel-native,
  profiling, consumer, and final release validation are still outstanding.
