# 媒体交付复审四项修复计划

> 执行采用 test-driven-development 与 dispatching-parallel-agents；用户已批准四项修复及验证，沿用当前工作区，不自动提交。

**目标：** 修复 engine 关闭和请求头兼容问题，收窄 core API，并解除 Cast 对完整播放器的依赖。
**架构：** 提供显式的 macOS 原生交付关闭入口；将两个原生入口的请求头准入集中到 core；将播放器适配放入可选包。
**技术：** Swift 5、Flutter/Dart、SPM/CocoaPods。
**依据：** 已批准的四项 review 建议和[媒体交付拆分设计](../specs/2026-10-20-media-delivery-split-design.md)。

## 约束与复审重点

- iOS 15/macOS 12；不使用 Flutter 私有 API 或运行时替换 SDK 方法。
- macOS 宿主关闭 engine 前必须有明确可调用的清理入口，真实 engine 测试覆盖保留对象、活动租约和重复关闭。
- 请求头保持 HTAB 兼容，继续拒绝 CR/LF、其他控制字符、保留头、重复名称以及未分类的敏感普通头。
- 必要跨模块契约继续公开，内部 RTMP 实现只允许 `@testable` 测试访问。
- Cast 核心的独立消费依赖图不得包含 `yl_player`、Apple 或 FFmpeg；可选适配保留播放交接/AirPlay 行为。

## 任务

- [x] macOS shutdown：为 `YlPlayerMediaDeliveryPlugin` 增加幂等关闭入口；先验证旧实现缺失，再用真实 engine + HTTP-FLV 活动交付验证服务释放、第二个 engine 隔离及 registry 清除。
- [x] 请求头一致性：新增两原生入口同表验证，先复现 HTAB 差异；core 新增 `YlHttpHeaderAdmission`，Apple 与独立 wire 共用；验证凭据跨 origin 剥离。
- [x] core API：审计并隐藏非跨模块类型；验证外部模块不可访问内部 RTMP 类型，真实 Apple/delivery 可编译，协议测试继续可用。
- [x] 可选播放器适配：Cast 提供最小播放器契约，新建 `yl_player_cast_player_adapter`；验证控制器/AirPlay/交接行为和独立包依赖图，更新示例与迁移文档。
- [x] 集中验证：受影响 Dart 测试与静态检查、原生生命周期/请求头/模块边界、真实 HLS 拉取及示例构建；修复复审问题并记录证据与设备验收边界。

完成记录见[四项修复验收](../reports/2026-10-20-media-delivery-review-fixes.md)。代码未提交。
