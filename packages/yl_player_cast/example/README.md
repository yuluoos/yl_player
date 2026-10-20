# 投屏示例

演示 DLNA 搜索与控制、本地播放交接、取消连接、返回本地，以及 AirPlay 系统选择器。

从 workspace 根目录运行 `flutter pub get`，再在此目录执行 `flutter run`。
Apple 原生依赖准备沿用播放器包说明。Android 最低 24，iOS 最低 15，macOS 最低 12。

真机验收前阅读 [包接入文档](../README.md)：

- iOS SSDP 需要 Apple 批准的 multicast entitlement 和匹配签名；示例不提供授权。
- 示例的 Android 允许 cleartext 以访问 DLNA HTTP；产品应使用符合自身要求的网络配置。
- 自定义直播默认拒绝。只有在目标电视验收 HLS/fMP4 后，才把设备 UUID 填入 `main.dart` 的 `verifiedHlsFmp4DeviceIds`。
- 先本地播放，再点击设备行执行交接；右侧“投屏”按钮直接使用输入框地址。
- 命令确认不代表电视已显示第一帧。
