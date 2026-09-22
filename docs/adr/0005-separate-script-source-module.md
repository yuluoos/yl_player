---
status: accepted
---

# JavaScript 直播源解析以独立配套模块交付

用户选择将 JavaScript 脚本执行与直播地址解析作为独立配套模块，随本项目在 Android、iOS、macOS 一起交付，解析结果交给 `yl_player` 播放。无需脚本源的应用可以不引入该模块；RTMP 的传输与播放能力属于播放器内核。

相较于将脚本运行环境直接内置 `yl_player`，该方案接受业务端显式接入解析模块的成本，使脚本兼容更新和播放内核可以独立迭代，并避免所有消费者都承担脚本运行环境依赖。作出本决策时，具体包名、运行时、公开 API 及刷新与取消的协作契约尚待设计。

2026-09-22 实施补充：模块命名 `yl_player_source_resolver`，固定 QuickJS 2026-06-04 和 CryptoJS 4.2.0 开源源码，通过 Dart build hooks 构建原生运行层；核心播放器不依赖该包。独立示例显式组合解析模块与播放器。公开解析结果通过既有 `YlNetworkSource` 交接，私有传输 schema3 与公开 SPI2 不变。设计、限额及安全错误契约见[实施计划](../superpowers/plans/2026-09-22-script-resolver.md)，验证结果见[实施记录](../superpowers/reports/2026-09-22-script-resolver.md)。
