---
status: accepted
---

# 受保护内容使用平台对应的交付方案

用户于 2026-09-20 确认：未加密 DASH 点播纳入 Android、iOS、macOS 三端支持范围；受 DRM 保护的同一内容允许使用不同播放地址和 DRM 方案，Android 使用 DASH + Widevine，iOS/macOS 使用 HLS + FairPlay。内容服务提供对应媒体地址及许可证服务，不要求同一个加密 MPD 在三端直接播放。

选择平台官方 DRM 链路，接受内容服务维护平台对应交付方式的成本，避免将跨平台播放能力等同于相同加密清单的兼容性。此决定不表示播放器能够将 Widevine 内容自动转换为 FairPlay 内容；服务接入条件、加密模式、设备和输出限制仍需进一步确定。

依据：[Android Media3 DRM](https://developer.android.com/media/media3/exoplayer/drm)；[Apple FairPlay Streaming](https://developer.apple.com/streaming/fps/)。
