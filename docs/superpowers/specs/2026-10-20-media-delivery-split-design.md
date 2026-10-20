# 媒体交付独立拆包设计

用户已要求执行前文提出的独立媒体交付分层。保留现有 Dart 调用形式；原生实现、构建依赖和资源归属同时拆分，不复制播放器，也不创建隐藏播放器。

## 依赖方向

- `yl_player_media_core`：Apple 原生公共输入层，唯一持有 FFmpeg bridge、网络/RTMP 输入、解复用、取消与缓冲原语。没有播放器、HLS 生产器或 Flutter 播放协议。提供可选交付服务注册契约。
- `yl_player_apple`：依赖 core，保留解码、播放、系统 AirPlay 路由与旧交付 API 的兼容适配；不依赖 delivery。
- `yl_player_media_delivery`：依赖 platform_interface 和 core，独立创建交付会话。持有原生转封装、滚动 HLS、HTTP 服务和租约；不依赖 Apple 播放器或 cast。
- `yl_player_cast`：通过通用交付 provider 注入使用该能力，继续兼容旧播放器交付 SPI。

共享输入层是实施选择：输入/解复用同时服务本地播放和交付，不能随 HLS 搬走后让播放器反向依赖投屏，也不应复制两套协议实现。

## 兼容与可选性

普通本地播放及 HTTP/HLS 直连 AirPlay 不要求添加 delivery 包。自定义源 AirPlay 和独立交付需要宿主显式添加 `yl_player_media_delivery`；缺少服务时返回明确、不含凭据的失败。原 `prepareMediaDelivery`、`load(airPlay: true)` 的签名保留。

保留 iOS 15/macOS 12 最低版本、现有 RTMPS TLS 与网络策略、存储和恢复上限。Android 不新增转封装。VOD AirPlay 转封装与直播共享的 writer/server 一起归属 delivery，避免两份 HLS 实现。

## 生命周期

独立交付不创建播放器。每个交付 provider 至多一个准入请求、一个最新等待候选、一个生产准备和一个已接受租约。拒绝新准入保留旧资源，合法替换才取消；取消/销毁隔离迟到事件。租约失败、停止或销毁释放生产器和 HTTP 服务。

原生服务按 Flutter engine 安装与清理；共享注册契约不持有播放器，不因一个调用方销毁而影响其他交付所有者。

## 验证

证明新包在没有 `yl_player_apple` 时可构建并生成可实际拉取的 HLS；证明 Apple 不链接交付模块时本地/直接 AirPlay 仍可构建并明确拒绝自定义转换；证明两者同时使用时 FFmpeg 只有一份。

执行跨包 Dart 回归、原生模块编译与实际媒体拉取、取消/拒绝/替换测试、SPM/CocoaPods 依赖边界检查、示例构建和独立复审。使用中文文档；未经用户要求不 commit/push。
