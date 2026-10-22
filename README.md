# yl_player

`yl_player` is a federated Flutter playback kernel for Android, iOS, and
macOS. The v0.2 development API separates a long-lived player from replaceable
playback sessions, keeps rendering texture-only, and makes network, buffer,
decoder, and audio ownership requirements explicit.

The workspace requires Dart 3.12 and Flutter 3.44. Applications depend on
[`yl_player`](packages/yl_player/README.md); Flutter selects the endorsed
[`yl_player_android`](packages/yl_player_android/README.md) or
[`yl_player_apple`](packages/yl_player_apple/README.md) implementation. Platform
authors use the
[`yl_player_platform_interface`](packages/yl_player_platform_interface/README.md).

The optional [`yl_player_source_resolver`](packages/yl_player_source_resolver/README.md)
module resolves JavaScript sources before playback. It is a separate development
package; the player does not depend on it. See its
[implementation and validation record](docs/superpowers/reports/2026-09-22-script-resolver.md)
for current evidence and limits.

可选 [`yl_player_cast`](packages/yl_player_cast/README.md) 提供 DLNA 设备发现、
远端控制和 AirPlay 统一入口。
纯 DLNA 使用不依赖完整播放器；本地播放交接与 AirPlay 通过可选
[`yl_player_cast_player_adapter`](packages/yl_player_cast_player_adapter/README.md)
接入。播放器不反向依赖投屏包；接入限制和宿主权限见其中文文档。

可选 [`yl_player_media_delivery`](packages/yl_player_media_delivery/README.md)
独立提供 Apple 自定义直播转 HLS/fMP4、局域网 HTTP 服务和交付租约，无需创建播放器。
自定义源 AirPlay 转换也需显式添加该插件；原调用形式保留。
播放器和交付插件共享底层 [`yl_player_media_core`](packages/yl_player_media_core/README.md)，
其独占 FFmpeg 与输入协议代码；普通播放器不依赖 HLS 交付插件。

Start with the [application API and lifecycle](packages/yl_player/README.md).
Before adopting v0.2, read the [migration guide](docs/migration-to-0.2.md),
[platform support matrix](docs/platform-support.md), [policy semantics](docs/policies.md),
and [diagnostics contract](docs/diagnostics.md).

This is `0.3.0-dev.4`. Final physical-device, endurance, profiling, consumer,
and release acceptance remains pending; the support matrix distinguishes
implemented automated evidence from physical evidence.

## License

Except where otherwise noted, original code and documentation in this repository
are licensed under the [BSD 3-Clause License](LICENSE), consistent with the workspace
library packages. Existing copyright notices are retained.

The optional resolver embeds MIT-licensed QuickJS and CryptoJS with pinned
source provenance and license files in its `src` directory.

Third-party components retain their own licenses; the repository license does
not relicense them. The Android and Apple media core packages redistribute minimized
LGPL-2.1-or-later FFmpeg components. See the
[Apple media core third-party notices](packages/yl_player_media_core/THIRD_PARTY_NOTICES.md),
[Android FFmpeg notice](packages/yl_player_android/LICENSES/FFmpeg-NOTICE.txt),
and the LGPL license texts in each platform package's `LICENSES` directory.
Keep each package's license text, notices, replacement scripts, and artifact
lock with binary distributions. Distribution also requires satisfying the
applicable LGPL source and replacement/relinking requirements; these files alone
are not a complete compliance assessment. See
[FFmpeg's license and legal guidance](https://ffmpeg.org/legal.html).
