# yl_player_media_core

共享 Apple 原生媒体输入层。由播放器和可选媒体交付插件依赖，不提供 Dart 播放器接口。

支持 iOS 15+、macOS 12+。本包唯一持有 YlFFmpegBridge，包含网络、RTMP、HLS 输入、取消与有界缓冲原语；不包含播放器、渲染界面或 Pigeon 协议。

原生公开 API 保留调用方使用的输入配方、字节源、取消、缓冲预算和交付契约。RTMP 消息、分块、AMF、流控、FLV 拼装，以及 HTTP 响应解析器和字节环形缓冲均为模块内部实现；协议回归测试通过 `@testable import yl_player_media_core` 访问。

在仓库根目录运行 `python3 packages/yl_player_media_core/test/run_native_api_boundary.py`，可按 Swift 5 / macOS 12 构建 core、delivery 和 Apple 三个真实模块，验证普通 import 的访问边界、公开输入契约和现有 RTMP 协议回归。仅检查 core 公开契约时，可运行 `bash packages/yl_player_media_core/test/run_native_module_boundary.sh`。
