## 0.3.0-dev.5

- Synchronize package and internal dependency versions at `0.3.0-dev.5`.

## 0.3.0-dev.4

- Synchronize package versions and internal dependencies at 0.3.0-dev.4.
- Preserve bounded, sanitized upstream HTTP status and playback failure causes
  in shared diagnostic messages.

## 0.3.0-dev.3

- Synchronize package versions and internal dependencies at 0.3.0-dev.3.
- 新增独立 `YlMediaDeliveryProvider` 契约，复用准备任务、租约与状态模型。
- 添加缺少可选 AirPlay 交付插件的脱敏接入提示。

## 0.3.0-dev.1

- Add typed AirPlay availability and route-picker contracts, RTMPS source
  semantics, and safe external-playback diagnostics.

## 0.2.0-dev.2

- Add an optional subtitle SPI, bounded source/catalog validation, and default-off
  subtitle state. Existing track and operation ordinals are preserved; native
  subtitle support is not advertised by this contract change.
- Add an optional media-clock position metric for observing playback progress
  independently from live-window timeline coordinates.

## 0.2.0-dev.1

- Replace the v0.1 backend contract with SPI major 2, explicit implementation
  identity, source assessment, commit/state Load barriers, and session IDs.
- Add immutable Player/Load policy types, typed source families, authoritative
  state/timeline/geometry models, correlated events, and safe structured failures.
- Add validation at Dart/native publication boundaries and reusable observable
  platform conformance utilities.
- Verify the synchronized v0.2 package contract in the publication dry-run gate.

## 0.1.0-dev.1

- Add immutable player configuration, media-source, track, state, capability,
  metric, event, and error models.
- Add federated platform and per-player backend contracts.
- Add nullable Android device-tier, target-buffer, adaptive-downgrade,
  Surface-rebuild, and selected-video-bitrate playback diagnostics.
