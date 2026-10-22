## 0.3.0-dev.4

- Synchronize package versions and internal dependencies at 0.3.0-dev.4.

## 0.3.0-dev.3

- Synchronize package versions and internal dependencies at 0.3.0-dev.3.
- 移除播放器直接依赖；纯 DLNA 不再传递引入 Apple 播放器或 FFmpeg。
- 本地交接和 AirPlay 改用最小播放器／会话接口，`yl_player` 应用通过可选 `yl_player_cast_player_adapter` 迁移。

- 支持注入独立 `YlMediaDeliveryProvider`，无需创建播放器实例即可交付自定义直播。
- 保留旧播放器 SPI 兼容入口；外部注入 provider 的释放由调用方负责。

## 0.3.0-dev.1

- 新增可选 DLNA 发现、协议能力评估及远端播放控制。
- 新增 AirPlay 统一入口和显式本地播放交接。
- Apple 自定义直播通过独立 HLS/fMP4 交付租约投屏。
- Android 扫描与会话使用引用计数组播锁。
