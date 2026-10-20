# 媒体交付拆包实施计划

> 执行：使用 executing-plans 与 test-driven-development；互不修改同一文件的 Dart/原生模块可按 dispatching-parallel-agents 分工。用户已要求直接执行，沿用当前工作目录，不自动提交。

**目标：** 将 HLS 转封装和交付实现拆到独立可选包，同时保持播放器接口兼容。
**架构：** 公共 Apple 输入层 core 向上服务播放器和 delivery；cast 注入交付 provider。无反向依赖和重复 FFmpeg。
**技术：** Dart/Flutter、Swift、SPM/CocoaPods、现有 FFmpeg bridge。
**设计：** [拆分设计](../specs/2026-10-20-media-delivery-split-design.md)。

## 全局约束

- iOS 15/macOS 12；不新增 Android 转封装，不改 RTMPS TLS、存储上限和播放器解码行为。
- 保留旧 Dart API；自定义 AirPlay 显式要求可选 delivery 插件。
- 不复制共享协议代码，不通过隐藏播放器获得交付能力。
- 仅在原生输入层共享必要的公共类型；播放器协议与 UI 不进入 core。
- 本次不 commit、push、发布包或改签名配置。

## 复审重点

- 缺少交付插件时失败清晰，直接播放不依赖交付模块。
- 共享原生类型跨模块后取消、错误类型与缓冲所有权不变。
- 旧兼容入口与独立入口都保留准入不干扰旧资源的语义。
- 多 owner、多个 Flutter engine 的释放不相互影响。
- SPM、Pods、测试脚本和分发路径引用同一份 FFmpeg，发布不依赖仓库外路径。

## 任务 1：共享原生输入层

- [x] 新建 `packages/yl_player_media_core` 原生插件与构建声明；将 Dependencies/FFmpeg 输入、Network、RTMP 和 HLS 读取原语移动到其 Swift module。
- [x] FFmpeg 二进制及构建源码唯一迁移；原 Apple 验证相关扩展留在 Apple 模块。
- [x] 新增跨模块编译验证，验证独立 core/Apple 构建与二进制唯一归属。
- [x] 保持已有原生 RTMP/网络/取消回归，迁移验证脚本路径。

## 任务 2：交付原生模块与兼容桥

- [x] 新建 `packages/yl_player_media_delivery` 的原生 HLS remux/store/server/manager。
- [x] core 定义纯输入 recipe、交付媒体与可选服务契约；Apple 留 source→recipe 适配，delivery 实现注册。
- [x] 新插件使用独立 owner 通道，接收严格校验的通用消息，不依赖 Pigeon 播放器协议。
- [x] 写无播放器交付、缺插件拒绝、多 owner、取消与替换回归，编译并实际拉取 HLS。

## 任务 3：Dart API 与投屏接入

- [x] platform_interface 新增 `YlMediaDeliveryProvider` 接口；保留既有播放器 SPI。
- [x] 新包实现 `YlMediaDelivery`、有界准入、租约和显式 dispose，独立于播放器。
- [x] cast 支持注入 provider，优先使用注入实例；旧播放器 SPI 作为兼容入口。调用方拥有注入 provider。
- [x] 更新独立示例和测试，证明无需创建播放器即可交付，拒绝和取消行为不退化。

## 任务 4：集成与验收

- [x] 更新 workspace、平台声明、中文使用/迁移文档和构建工具。
- [x] 串行运行受影响 Dart 测试和静态检查；原生模块/实际 HLS 拉取、示例构建。
- [x] 独立复审，修复实质问题并记录已完成验证与设备验收边界。

完成记录见[拆分验收报告](../reports/2026-10-20-media-delivery-split.md)。代码未提交。
