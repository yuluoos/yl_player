## 0.3.0-dev.3

- Synchronize package versions and internal dependencies at 0.3.0-dev.3.
- macOS 提供显式 `shutdown()`，供宿主在关闭 FlutterEngine 前释放独立交付资源。
- 原生请求头与播放器使用同一校验规则，修复合法水平 Tab 被拒绝的问题。

## 0.3.0-dev.1

- 独立媒体交付 provider 与 HLS 租约，无需播放器。
- 保留有界准入、拒绝保留旧资源、可取消准备及所有者隔离。
- 提供标准 Flutter 通道、稳定脱敏错误以及投屏 provider 注入接口。
